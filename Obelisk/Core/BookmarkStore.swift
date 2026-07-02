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
    /// Website / source title captured before local display-title optimization.
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
        ObeliskVaultStore(rootDirectory: rootDirectory).payloadURL
    }

    private var vaultStore: ObeliskVaultStore

    public init(rootDirectory: URL = BookmarkStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
        self.vaultStore = ObeliskVaultStore(rootDirectory: rootDirectory)
    }

    /// `OBELISK_HOME` is the supported storage override; `UNIBOOKMARK_HOME`
    /// remains honored as a legacy fallback from the app's previous name.
    public static func environmentRootOverride() -> URL? {
        let env = ProcessInfo.processInfo.environment
        for key in ["OBELISK_HOME", "UNIBOOKMARK_HOME"] {
            if let value = env[key], !value.isEmpty {
                return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
            }
        }
        return nil
    }

    public static func defaultRootDirectory() -> URL {
        environmentRootOverride() ?? defaultLocalRootDirectory()
    }

    public static func defaultLocalRootDirectory() -> URL {
        environmentRootOverride() ?? applicationSupportRootDirectory()
    }

    public static func applicationSupportRootDirectory() -> URL {
        applicationSupportBaseDirectory()
            .appendingPathComponent("com.eli.Obelisk", isDirectory: true)
            .appendingPathComponent(ObeliskPrivateStorage.vaultDirectoryName, isDirectory: true)
    }

    private static func applicationSupportBaseDirectory() -> URL {
        let fileManager = FileManager.default
        if let url = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return url
        }

        if let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return url
        }

        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    public func updateRootDirectory(_ rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        vaultStore = ObeliskVaultStore(rootDirectory: rootDirectory)
        invalidateCache()
    }

    public func invalidateCache() {
        vaultStore.invalidateCache()
    }

    public func load() throws -> BookmarkDatabase {
        try ensureStoreExists()
        let payload = try vaultStore.loadPayload()
        return BookmarkDatabase(
            version: payload.schemaVersion,
            bookmarks: payload.bookmarks.map(\.bookmark)
        )
    }

    public func save(_ database: BookmarkDatabase) throws {
        try withFileLock {
            try FileManager.default.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true
            )
            ObeliskPrivateStorage.markVaultDirectoryAsPackageIfNeeded(rootDirectory)

            let payload = try payloadByMerging(bookmarks: database.bookmarks)
            try vaultStore.savePayload(payload)
        }
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

            let bookmark = Bookmark(
                title: trimmedTitle,
                url: trimmedURL,
                isHidden: isHidden,
                originalTitle: trimmedTitle
            )
            database.bookmarks.append(bookmark)
            database.bookmarks.sort {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
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
            try save(database)
        }
    }

    public func setArchived(_ isArchived: Bool, ids: Set<UUID>, at date: Date = Date()) throws {
        guard !ids.isEmpty else {
            return
        }

        try withFileLock {
            var database = try load()
            database.bookmarks = database.bookmarks.map { bookmark in
                guard ids.contains(bookmark.id) else { return bookmark }
                var updated = bookmark
                updated.archivedAt = isArchived ? date : nil
                if isArchived {
                    updated.isPinned = false
                }
                return updated
            }
            try save(database)
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

            database.bookmarks = database.bookmarks.map { bookmark in
                guard targetIds.contains(bookmark.id) else { return bookmark }
                var updated = bookmark
                updated.isPinned = isPinned && !bookmark.isHidden && bookmark.archivedAt == nil
                return updated
            }
            try save(database)
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
            for idx in database.bookmarks.indices {
                let bookmark = database.bookmarks[idx]
                guard !bookmark.titleOptimized,
                      let title = optimizedTitles[bookmark.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty
                else {
                    continue
                }
                if database.bookmarks[idx].originalTitle == nil {
                    database.bookmarks[idx].originalTitle = bookmark.title
                }
                if title != bookmark.title {
                    database.bookmarks[idx].title = title
                }
                database.bookmarks[idx].titleOptimized = true
                changedCount += 1
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
            for idx in database.bookmarks.indices {
                let bookmark = database.bookmarks[idx]
                guard ids.contains(bookmark.id), bookmark.titleOptimized else { continue }
                guard let original = bookmark.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !original.isEmpty
                else {
                    continue
                }
                database.bookmarks[idx].title = original
                database.bookmarks[idx].titleOptimized = false
                changedCount += 1
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
            for idx in database.bookmarks.indices {
                let bookmark = database.bookmarks[idx]
                guard let original = bookmark.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !original.isEmpty
                else {
                    continue
                }
                guard bookmark.title != original || bookmark.titleOptimized else { continue }
                database.bookmarks[idx].title = original
                database.bookmarks[idx].titleOptimized = false
                changedCount += 1
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
            for idx in database.bookmarks.indices {
                let bookmark = database.bookmarks[idx]
                guard let title = titles[bookmark.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty
                else {
                    continue
                }
                database.bookmarks[idx].originalTitle = title
                if forceApplyDisplay || !bookmark.titleOptimized {
                    database.bookmarks[idx].title = title
                    database.bookmarks[idx].titleOptimized = false
                }
                changedCount += 1
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
            if !updated.titleOptimized {
                database.bookmarks[idx].originalTitle = trimmedTitle
            }
            if updated.isHidden || updated.archivedAt != nil {
                database.bookmarks[idx].isPinned = false
            }
            database.bookmarks.sort {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            try save(database)
            return updated
        }
    }

    private func ensureStoreExists() throws {
        ObeliskPrivateStorage.markVaultDirectoryAsPackageIfNeeded(rootDirectory)
        if vaultStore.hasV2Payload {
            return
        }
        let payload = try vaultStore.loadPayload()
        if payload.bookmarks.isEmpty && payload.groups.isEmpty {
            try vaultStore.savePayload(ObeliskVaultPayload())
        }
    }

    private func payloadByMerging(bookmarks: [Bookmark]) throws -> ObeliskVaultPayload {
        let current = try vaultStore.loadPayload()
        let currentById = Dictionary(uniqueKeysWithValues: current.bookmarks.map { ($0.id, $0) })

        let merged = bookmarks.map { bookmark -> ObeliskVaultBookmark in
            let existing = currentById[bookmark.id]
            return ObeliskVaultBookmark(
                bookmark: bookmark,
                groupId: existing?.groupId,
                usage: existing?.usage
            )
        }

        return ObeliskVaultPayload(
            schemaVersion: ObeliskVaultStore.currentPayloadSchemaVersion,
            bookmarks: merged,
            groups: current.groups,
            llmProfiles: current.llmProfiles
        )
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
