import Foundation

public struct Bookmark: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var url: String
    public var createdAt: Date
    public var titleOptimized: Bool
    public var isHidden: Bool
    public var archivedAt: Date?
    public var isPinned: Bool
    /// Website / source title from `bookmark_state.json`; not stored in `bookmarks.json`.
    public var originalTitle: String?

    public init(
        id: UUID = UUID(),
        title: String,
        url: String,
        createdAt: Date = Date(),
        titleOptimized: Bool = false,
        isHidden: Bool = false,
        archivedAt: Date? = nil,
        isPinned: Bool = false,
        originalTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.titleOptimized = titleOptimized
        self.isHidden = isHidden
        self.archivedAt = archivedAt
        self.isPinned = isPinned
        self.originalTitle = originalTitle
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
        isPinned = false
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
        ObeliskDataStorage.representativeURL(
            logicalName: "bookmarks.json",
            rootDirectory: rootDirectory
        )
    }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let stateStore: BookmarkStateStore
    private var cachedDatabase: BookmarkDatabase?

    public init(rootDirectory: URL = BookmarkStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
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
        let database: BookmarkDatabase
        if let cachedDatabase {
            database = cachedDatabase
        } else {
            try ensureStoreExists()
            let data = try ObeliskDataStorage.readLogical("bookmarks.json", rootDirectory: rootDirectory)
            database = try decoder.decode(BookmarkDatabase.self, from: data)
            cachedDatabase = database
        }

        var hydrated = database
        hydrated.bookmarks = try applyStoredState(to: hydrated.bookmarks)
        cachedDatabase = hydrated
        return hydrated
    }

    public func save(_ database: BookmarkDatabase) throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        try persistState(from: database.bookmarks)
        let data = try encoder.encode(database)
        try ObeliskDataStorage.writeLogical(
            data,
            logicalName: "bookmarks.json",
            rootDirectory: rootDirectory,
            encrypted: LocalJSONEncryption.isEnabled
        )
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
                state.originalTitleById[bookmark.id] = trimmedTitle
                if isHidden {
                    state.hiddenIds.insert(bookmark.id)
                }
            }
            try save(database)
            return bookmark
        }
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        do {
            return try ObeliskRootDirectoryLock.withExclusiveAccess(rootDirectory: rootDirectory, body)
        } catch ObeliskStorageLockError.lockFailed {
            throw BookmarkStoreError.lockFailed
        }
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
                state.pinnedIds.subtract(ids)
                state.titleOptimizedIds.subtract(ids)
                for id in ids {
                    state.createdAtById.removeValue(forKey: id)
                    state.originalTitleById.removeValue(forKey: id)
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
                    state.pinnedIds.subtract(ids)
                } else {
                    state.manualArchivedIds.subtract(ids)
                }
            }
            if var cachedDatabase {
                cachedDatabase.bookmarks = cachedDatabase.bookmarks.map { bookmark in
                    guard ids.contains(bookmark.id) else { return bookmark }
                    var updated = bookmark
                    updated.archivedAt = isArchived ? Date.distantPast : nil
                    if isArchived {
                        updated.isPinned = false
                    }
                    return updated
                }
                self.cachedDatabase = cachedDatabase
            }
        }
    }

    public func setPinned(_ isPinned: Bool, ids: Set<UUID>) throws {
        guard !ids.isEmpty else {
            return
        }

        try withFileLock {
            var database = try load()
            let validIds = Set(database.bookmarks.map(\.id))
            let targetIds = ids.intersection(validIds)
            guard !targetIds.isEmpty else { return }

            try stateStore.update { state in
                if isPinned {
                    let eligibleIds = Set(database.bookmarks.filter { bookmark in
                        targetIds.contains(bookmark.id) && !bookmark.isHidden && bookmark.archivedAt == nil
                    }.map(\.id))
                    state.pinnedIds.subtract(targetIds)
                    state.pinnedIds.formUnion(eligibleIds)
                } else {
                    state.pinnedIds.subtract(targetIds)
                }
            }

            database.bookmarks = database.bookmarks.map { bookmark in
                guard targetIds.contains(bookmark.id) else { return bookmark }
                var updated = bookmark
                updated.isPinned = isPinned && !bookmark.isHidden && bookmark.archivedAt == nil
                return updated
            }
            cachedDatabase = database
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
            try stateStore.update { state in
                for idx in database.bookmarks.indices {
                    let bookmark = database.bookmarks[idx]
                    guard !bookmark.titleOptimized,
                          let title = optimizedTitles[bookmark.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !title.isEmpty
                    else {
                        continue
                    }
                    if state.originalTitleById[bookmark.id] == nil {
                        state.originalTitleById[bookmark.id] = bookmark.title
                    }
                    if title != bookmark.title {
                        database.bookmarks[idx].title = title
                    }
                    database.bookmarks[idx].titleOptimized = true
                    state.titleOptimizedIds.insert(bookmark.id)
                    changedIds.insert(bookmark.id)
                    changedCount += 1
                }
            }
            if changedCount > 0 {
                database.bookmarks.sort {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                try save(database)
            }
            return changedCount
        }
    }

    @discardableResult
    public func revertTitleOptimizations(ids: Set<UUID>) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try withFileLock {
            var database = try load()
            var changedCount = 0
            try stateStore.update { state in
                for idx in database.bookmarks.indices {
                    let bookmark = database.bookmarks[idx]
                    guard ids.contains(bookmark.id), bookmark.titleOptimized else { continue }
                    guard let original = state.originalTitleById[bookmark.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !original.isEmpty
                    else {
                        continue
                    }
                    database.bookmarks[idx].title = original
                    database.bookmarks[idx].titleOptimized = false
                    state.titleOptimizedIds.remove(bookmark.id)
                    changedCount += 1
                }
            }
            if changedCount > 0 {
                database.bookmarks.sort {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                try save(database)
            }
            return changedCount
        }
    }

    @discardableResult
    public func restoreAllOriginalTitles() throws -> Int {
        try withFileLock {
            var database = try load()
            var changedCount = 0
            try stateStore.update { state in
                for idx in database.bookmarks.indices {
                    let bookmark = database.bookmarks[idx]
                    guard let original = state.originalTitleById[bookmark.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !original.isEmpty
                    else {
                        continue
                    }
                    guard bookmark.title != original || bookmark.titleOptimized else { continue }
                    database.bookmarks[idx].title = original
                    database.bookmarks[idx].titleOptimized = false
                    state.titleOptimizedIds.remove(bookmark.id)
                    changedCount += 1
                }
            }
            if changedCount > 0 {
                database.bookmarks.sort {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                try save(database)
            }
            return changedCount
        }
    }

    @discardableResult
    public func applyOriginalTitles(_ titles: [UUID: String], forceApplyDisplay: Bool = false) throws -> Int {
        guard !titles.isEmpty else { return 0 }
        return try withFileLock {
            var database = try load()
            var changedCount = 0
            try stateStore.update { state in
                for idx in database.bookmarks.indices {
                    let bookmark = database.bookmarks[idx]
                    guard let title = titles[bookmark.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !title.isEmpty
                    else {
                        continue
                    }
                    state.originalTitleById[bookmark.id] = title
                    if forceApplyDisplay || !bookmark.titleOptimized {
                        database.bookmarks[idx].title = title
                        database.bookmarks[idx].titleOptimized = false
                        state.titleOptimizedIds.remove(bookmark.id)
                    }
                    changedCount += 1
                }
            }
            if changedCount > 0 {
                database.bookmarks.sort {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
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
                    state.originalTitleById[updated.id] = trimmedTitle
                }
                if updated.isHidden {
                    state.hiddenIds.insert(updated.id)
                    state.pinnedIds.remove(updated.id)
                } else {
                    state.hiddenIds.remove(updated.id)
                }
                if updated.archivedAt != nil {
                    state.manualArchivedIds.insert(updated.id)
                    state.pinnedIds.remove(updated.id)
                } else {
                    state.manualArchivedIds.remove(updated.id)
                }
                if updated.isPinned && !updated.isHidden && updated.archivedAt == nil {
                    state.pinnedIds.insert(updated.id)
                } else {
                    state.pinnedIds.remove(updated.id)
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
        if LocalJSONEncryption.isEnabled, VaultStorage.usesVaultV2(in: rootDirectory) {
            guard (try? VaultDataKeyCache.current()) != nil else { return }
            if (try? ObeliskDataStorage.readLogical("bookmarks.json", rootDirectory: rootDirectory)) != nil {
                return
            }
            try save(BookmarkDatabase())
            return
        }

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

        let hasStoredState = !state.hiddenIds.isEmpty
            || !state.manualArchivedIds.isEmpty
            || !state.pinnedIds.isEmpty
            || !state.titleOptimizedIds.isEmpty
            || !state.createdAtById.isEmpty
            || !state.originalTitleById.isEmpty
        if bookmarks.isEmpty, hasStoredState {
            return bookmarks
        }

        state.hiddenIds.formIntersection(validIds)
        state.manualArchivedIds.formIntersection(validIds)
        state.pinnedIds.formIntersection(validIds)
        state.titleOptimizedIds.formIntersection(validIds)
        state.createdAtById = state.createdAtById.filter { validIds.contains($0.key) }
        state.originalTitleById = state.originalTitleById.filter { validIds.contains($0.key) }

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
            bookmark.isPinned = state.pinnedIds.contains(bookmark.id) && !bookmark.isHidden && bookmark.archivedAt == nil
            bookmark.originalTitle = state.originalTitleById[bookmark.id]
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
            state.pinnedIds = Set(bookmarks.filter { $0.isPinned && !$0.isHidden && $0.archivedAt == nil }.map(\.id))
            state.titleOptimizedIds = Set(bookmarks.filter(\.titleOptimized).map(\.id))
            for bookmark in bookmarks.filter({ !$0.titleOptimized }) where state.originalTitleById[bookmark.id] == nil {
                state.originalTitleById[bookmark.id] = bookmark.title
            }
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
            state.pinnedIds.formIntersection(validIds)
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
