import Foundation

public struct Bookmark: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var url: String
    public var createdAt: Date
    public var titleOptimized: Bool
    public var isHidden: Bool
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        url: String,
        createdAt: Date = Date(),
        titleOptimized: Bool = false,
        isHidden: Bool = false,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.titleOptimized = titleOptimized
        self.isHidden = isHidden
        self.archivedAt = archivedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, url, createdAt, titleOptimized, isHidden, archivedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        // Older files predate this field; fall back so legacy bookmarks just
        // never show up in "recently added" rather than failing to load.
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? .distantPast
        titleOptimized = (try? c.decode(Bool.self, forKey: .titleOptimized)) ?? false
        isHidden = (try? c.decode(Bool.self, forKey: .isHidden)) ?? false
        archivedAt = try? c.decodeIfPresent(Date.self, forKey: .archivedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(url, forKey: .url)
    }
}

public struct BookmarkDatabase: Codable, Equatable {
    public var version: Int
    public var bookmarks: [Bookmark]

    public init(version: Int = 1, bookmarks: [Bookmark] = []) {
        self.version = version
        self.bookmarks = bookmarks
    }
}

public enum BookmarkStoreError: LocalizedError {
    case invalidURL(String)
    case duplicateURL(String)
    case invalidTitle
    case lockFailed

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "网址格式不正确,需要包含 http:// 或 https://(\(url))"
        case .duplicateURL:
            return "这个网址已经在书签里了"
        case .invalidTitle:
            return "标题不能为空"
        case .lockFailed:
            return "暂时无法保存,书签文件被占用"
        }
    }
}

public final class BookmarkStore {
    public private(set) var rootDirectory: URL
    public var fileURL: URL {
        ObeliskPrivateStorage.activeFileURL(rootDirectory: rootDirectory, logicalName: "bookmarks.json")
    }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let secureCodec: SecureJSONFileCodec
    private let stateStore: BookmarkStateStore
    private var cachedDatabase: BookmarkDatabase?

    public init(rootDirectory: URL = BookmarkStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
        self.secureCodec = SecureJSONFileCodec()
        self.stateStore = BookmarkStateStore(rootDirectory: rootDirectory)

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultRootDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["UNIBOOKMARK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }

        if ICloudDocumentSync.isEnabled, let cachedRoot = ICloudDocumentSync.cachedRootDirectory() {
            return cachedRoot
        }

        return defaultLocalRootDirectory()
    }

    public static func defaultLocalRootDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["UNIBOOKMARK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }

        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("Obelisk")
    }

    public func updateRootDirectory(_ rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        stateStore.updateRootDirectory(rootDirectory)
        invalidateCache()
    }

    public func invalidateCache() {
        cachedDatabase = nil
        stateStore.invalidateCache()
    }

    public func load() throws -> BookmarkDatabase {
        if let cachedDatabase {
            return cachedDatabase
        }

        try ensureStoreExists()
        let url = ObeliskPrivateStorage.existingReadableFileURL(
            rootDirectory: rootDirectory,
            logicalName: "bookmarks.json"
        )
        let data = try secureCodec.readData(
            from: url,
            coordinated: ICloudDocumentSync.shouldCoordinateAccess(for: rootDirectory)
        )
        var database = try decoder.decode(BookmarkDatabase.self, from: data)
        database.bookmarks = try applyStoredState(to: database.bookmarks)
        cachedDatabase = database
        return database
    }

    public func save(_ database: BookmarkDatabase) throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        try persistState(from: database.bookmarks)
        let data = try encoder.encode(database)
        try secureCodec.writeData(
            data,
            to: fileURL,
            encrypted: LocalJSONEncryption.isEnabled,
            coordinated: ICloudDocumentSync.shouldCoordinateAccess(for: rootDirectory)
        )
        for staleURL in ObeliskPrivateStorage.inactiveFileURLs(rootDirectory: rootDirectory, logicalName: "bookmarks.json") {
            try? CoordinatedFileAccess.removeItem(
                at: staleURL,
                coordinated: ICloudDocumentSync.shouldCoordinateAccess(for: rootDirectory)
            )
        }
        cachedDatabase = database
    }

    @discardableResult
    public func add(title: String, url: String, isHidden: Bool = false) throws -> Bookmark {
        let trimmedURL = try validatedWebURL(url)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw BookmarkStoreError.invalidTitle
        }

        return try withFileLock {
            var database = try load()
            let target = BookmarkStore.normalizedURL(trimmedURL)
            if database.bookmarks.contains(where: { BookmarkStore.normalizedURL($0.url) == target }) {
                throw BookmarkStoreError.duplicateURL(trimmedURL)
            }

            let bookmark = Bookmark(title: trimmedTitle, url: trimmedURL, isHidden: isHidden)
            database.bookmarks.append(bookmark)
            database.bookmarks.sort {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            try stateStore.update { state in
                state.createdAtById[bookmark.id] = bookmark.createdAt
                if isHidden {
                    state.hiddenIds.insert(bookmark.id)
                }
            }
            try save(database)
            return bookmark
        }
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        if ICloudDocumentSync.shouldCoordinateAccess(for: rootDirectory) {
            let lockURL = rootDirectory.appendingPathComponent(".lock")
            var result: Result<T, Error>?
            var coordinatorError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: lockURL, options: [], error: &coordinatorError) { coordinatedURL in
                try? "".write(to: coordinatedURL, atomically: true, encoding: .utf8)
                result = Result { try body() }
            }
            if let coordinatorError {
                throw coordinatorError
            }
            return try result?.get() ?? body()
        }

        let lockURL = rootDirectory.appendingPathComponent(".lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw BookmarkStoreError.lockFailed
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw BookmarkStoreError.lockFailed
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    public func bookmarks() throws -> [Bookmark] {
        try load().bookmarks
    }

    public func delete(id: UUID) throws {
        try delete(ids: [id])
    }

    public func delete(ids: Set<UUID>) throws {
        guard !ids.isEmpty else {
            return
        }
        try withFileLock {
            var database = try load()
            database.bookmarks.removeAll { ids.contains($0.id) }
            try stateStore.update { state in
                state.hiddenIds.subtract(ids)
                state.manualArchivedIds.subtract(ids)
                state.titleOptimizedIds.subtract(ids)
                for id in ids {
                    state.createdAtById.removeValue(forKey: id)
                }
            }
            try save(database)
        }
    }

    public func setArchived(_ isArchived: Bool, ids: Set<UUID>, at date: Date = Date()) throws {
        guard !ids.isEmpty else {
            return
        }

        try withFileLock {
            try stateStore.update { state in
                if isArchived {
                    state.manualArchivedIds.formUnion(ids)
                } else {
                    state.manualArchivedIds.subtract(ids)
                }
            }
            if var cachedDatabase {
                cachedDatabase.bookmarks = cachedDatabase.bookmarks.map { bookmark in
                    guard ids.contains(bookmark.id) else { return bookmark }
                    var updated = bookmark
                    updated.archivedAt = isArchived ? Date.distantPast : nil
                    return updated
                }
                self.cachedDatabase = cachedDatabase
            }
        }
    }

    @discardableResult
    public func applyTitleOptimizations(_ optimizedTitles: [UUID: String]) throws -> Int {
        guard !optimizedTitles.isEmpty else {
            return 0
        }
        return try withFileLock {
            var database = try load()
            var changedCount = 0
            var changedIds: Set<UUID> = []
            for idx in database.bookmarks.indices {
                let bookmark = database.bookmarks[idx]
                guard !bookmark.titleOptimized,
                      let title = optimizedTitles[bookmark.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty
                else {
                    continue
                }
                if title != bookmark.title {
                    database.bookmarks[idx].title = title
                }
                database.bookmarks[idx].titleOptimized = true
                changedIds.insert(bookmark.id)
                changedCount += 1
            }
            if changedCount > 0 {
                database.bookmarks.sort {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                try stateStore.update { state in
                    state.titleOptimizedIds.formUnion(changedIds)
                }
                try save(database)
            }
            return changedCount
        }
    }

    @discardableResult
    public func update(_ bookmark: Bookmark) throws -> Bookmark {
        let trimmedURL = try validatedWebURL(bookmark.url)
        let trimmedTitle = bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw BookmarkStoreError.invalidTitle
        }

        return try withFileLock {
            var database = try load()
            guard let idx = database.bookmarks.firstIndex(where: { $0.id == bookmark.id }) else {
                return bookmark
            }
            let target = BookmarkStore.normalizedURL(trimmedURL)
            if database.bookmarks.contains(where: { $0.id != bookmark.id && BookmarkStore.normalizedURL($0.url) == target }) {
                throw BookmarkStoreError.duplicateURL(trimmedURL)
            }
            var updated = bookmark
            updated.title = trimmedTitle
            updated.url = trimmedURL
            database.bookmarks[idx] = updated
            try stateStore.update { state in
                state.createdAtById[updated.id] = updated.createdAt
                if updated.titleOptimized {
                    state.titleOptimizedIds.insert(updated.id)
                } else {
                    state.titleOptimizedIds.remove(updated.id)
                }
                if updated.isHidden {
                    state.hiddenIds.insert(updated.id)
                } else {
                    state.hiddenIds.remove(updated.id)
                }
                if updated.archivedAt != nil {
                    state.manualArchivedIds.insert(updated.id)
                } else {
                    state.manualArchivedIds.remove(updated.id)
                }
            }
            database.bookmarks.sort {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            try save(database)
            return updated
        }
    }

    private func ensureStoreExists() throws {
        let readableURL = ObeliskPrivateStorage.existingReadableFileURL(
            rootDirectory: rootDirectory,
            logicalName: "bookmarks.json"
        )
        guard !FileManager.default.fileExists(atPath: readableURL.path) else {
            return
        }
        try save(BookmarkDatabase())
    }

    private func applyStoredState(to bookmarks: [Bookmark]) throws -> [Bookmark] {
        var state = stateStore.load()
        let originalState = state
        var migrated = false
        let validIds = Set(bookmarks.map(\.id))

        state.hiddenIds.formIntersection(validIds)
        state.manualArchivedIds.formIntersection(validIds)
        state.titleOptimizedIds.formIntersection(validIds)
        state.createdAtById = state.createdAtById.filter { validIds.contains($0.key) }

        let hydrated = bookmarks.map { bookmark in
            var bookmark = bookmark
            if bookmark.createdAt > .distantPast, state.createdAtById[bookmark.id] == nil {
                state.createdAtById[bookmark.id] = bookmark.createdAt
                migrated = true
            }
            if bookmark.isHidden {
                state.hiddenIds.insert(bookmark.id)
                migrated = true
            }
            if bookmark.titleOptimized {
                state.titleOptimizedIds.insert(bookmark.id)
                migrated = true
            }

            bookmark.createdAt = state.createdAtById[bookmark.id] ?? .distantPast
            bookmark.isHidden = state.hiddenIds.contains(bookmark.id)
            bookmark.titleOptimized = state.titleOptimizedIds.contains(bookmark.id)
            bookmark.archivedAt = state.manualArchivedIds.contains(bookmark.id) ? Date.distantPast : nil
            return bookmark
        }

        if migrated || state != originalState {
            try stateStore.save(state)
        }
        return hydrated
    }

    private func persistState(from bookmarks: [Bookmark]) throws {
        let validIds = Set(bookmarks.map(\.id))
        try stateStore.update { state in
            state.hiddenIds = Set(bookmarks.filter(\.isHidden).map(\.id))
            state.manualArchivedIds = Set(bookmarks.filter { $0.archivedAt != nil }.map(\.id))
            state.titleOptimizedIds = Set(bookmarks.filter(\.titleOptimized).map(\.id))
            state.createdAtById = Dictionary(
                uniqueKeysWithValues: bookmarks.compactMap { bookmark in
                    guard bookmark.createdAt > .distantPast else {
                        return nil
                    }
                    return (bookmark.id, bookmark.createdAt)
                }
            )

            state.hiddenIds.formIntersection(validIds)
            state.manualArchivedIds.formIntersection(validIds)
            state.titleOptimizedIds.formIntersection(validIds)
            state.createdAtById = state.createdAtById.filter { validIds.contains($0.key) }
        }
    }

    private func validatedWebURL(_ rawURL: String) throws -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              parsed.host?.isEmpty == false
        else {
            throw BookmarkStoreError.invalidURL(rawURL)
        }
        return trimmed
    }

    public static func normalizedURL(_ rawURL: String) -> String {
        guard var components = URLComponents(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return rawURL
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil

        if let port = components.port,
           (components.scheme == "https" && port == 443) || (components.scheme == "http" && port == 80) {
            components.port = nil
        }

        if components.path == "/" {
            components.path = ""
        } else if components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        if let items = components.queryItems {
            components.queryItems = items.sorted { $0.name < $1.name }
        }

        return components.string ?? rawURL
    }
}
