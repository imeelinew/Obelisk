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

    public static func environmentRootOverride() -> URL? {
        guard let value = ProcessInfo.processInfo.environment["OBELISK_HOME"], !value.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
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
        try updatePayload { payload in
            let currentById = Dictionary(uniqueKeysWithValues: payload.bookmarks.map { ($0.id, $0) })
            payload.bookmarks = database.bookmarks.map { bookmark in
                let current = currentById[bookmark.id]
                return ObeliskVaultBookmark(
                    bookmark: bookmark,
                    groupId: current?.groupId,
                    usage: current?.usage
                )
            }
        }
    }

    @discardableResult
    public func add(title: String, url: String, isHidden: Bool = false) throws -> Bookmark {
        let trimmedURL = try validatedWebURL(url)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw BookmarkStoreError.invalidTitle
        }

        let bookmark = Bookmark(
            title: trimmedTitle,
            url: trimmedURL,
            isHidden: isHidden,
            originalTitle: trimmedTitle
        )
        try updatePayload { payload in
            let target = BookmarkStore.normalizedURL(trimmedURL)
            if payload.bookmarks.contains(where: { BookmarkStore.normalizedURL($0.url) == target }) {
                throw BookmarkStoreError.duplicateURL(trimmedURL)
            }
            payload.bookmarks.append(ObeliskVaultBookmark(bookmark: bookmark, groupId: nil, usage: nil))
        }
        return bookmark
    }

    private func updatePayload(_ body: (inout ObeliskVaultPayload) throws -> Void) throws {
        do {
            try vaultStore.updatePayload(body)
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
        try updatePayload { payload in
            payload.bookmarks.removeAll { ids.contains($0.id) }
        }
    }

    public func setArchived(_ isArchived: Bool, ids: Set<UUID>, at date: Date = Date()) throws {
        guard !ids.isEmpty else {
            return
        }

        try updatePayload { payload in
            payload.bookmarks = payload.bookmarks.map { bookmark in
                guard ids.contains(bookmark.id) else { return bookmark }
                var updated = bookmark
                updated.archivedAt = isArchived ? date : nil
                if isArchived {
                    updated.isPinned = false
                }
                return updated
            }
        }
    }

    public func setPinned(_ isPinned: Bool, ids: Set<UUID>) throws {
        guard !ids.isEmpty else {
            return
        }

        try updatePayload { payload in
            let validIds = Set(payload.bookmarks.map(\.id))
            let targetIds = ids.intersection(validIds)
            guard !targetIds.isEmpty else { return }

            payload.bookmarks = payload.bookmarks.map { bookmark in
                guard targetIds.contains(bookmark.id) else { return bookmark }
                var updated = bookmark
                updated.isPinned = isPinned && !bookmark.isHidden && bookmark.archivedAt == nil
                return updated
            }
        }
    }

    @discardableResult
    public func applyTitleOptimizations(_ optimizedTitles: [UUID: String]) throws -> Int {
        guard !optimizedTitles.isEmpty else {
            return 0
        }
        var changedCount = 0
        try updatePayload { payload in
            for idx in payload.bookmarks.indices {
                let bookmark = payload.bookmarks[idx]
                guard !bookmark.titleOptimized,
                      let title = optimizedTitles[bookmark.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty
                else {
                    continue
                }
                if payload.bookmarks[idx].originalTitle == nil {
                    payload.bookmarks[idx].originalTitle = bookmark.title
                }
                if title != bookmark.title {
                    payload.bookmarks[idx].title = title
                }
                payload.bookmarks[idx].titleOptimized = true
                changedCount += 1
            }
        }
        return changedCount
    }

    @discardableResult
    public func revertTitleOptimizations(ids: Set<UUID>) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var changedCount = 0
        try updatePayload { payload in
            for idx in payload.bookmarks.indices {
                let bookmark = payload.bookmarks[idx]
                guard ids.contains(bookmark.id), bookmark.titleOptimized else { continue }
                guard let original = bookmark.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !original.isEmpty
                else {
                    continue
                }
                payload.bookmarks[idx].title = original
                payload.bookmarks[idx].titleOptimized = false
                changedCount += 1
            }
        }
        return changedCount
    }

    @discardableResult
    public func restoreAllOriginalTitles() throws -> Int {
        var changedCount = 0
        try updatePayload { payload in
            for idx in payload.bookmarks.indices {
                let bookmark = payload.bookmarks[idx]
                guard let original = bookmark.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !original.isEmpty
                else {
                    continue
                }
                guard bookmark.title != original || bookmark.titleOptimized else { continue }
                payload.bookmarks[idx].title = original
                payload.bookmarks[idx].titleOptimized = false
                changedCount += 1
            }
        }
        return changedCount
    }

    @discardableResult
    public func applyOriginalTitles(_ titles: [UUID: String], forceApplyDisplay: Bool = false) throws -> Int {
        guard !titles.isEmpty else { return 0 }
        var changedCount = 0
        try updatePayload { payload in
            for idx in payload.bookmarks.indices {
                let bookmark = payload.bookmarks[idx]
                guard let title = titles[bookmark.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty
                else {
                    continue
                }
                payload.bookmarks[idx].originalTitle = title
                if forceApplyDisplay || !bookmark.titleOptimized {
                    payload.bookmarks[idx].title = title
                    payload.bookmarks[idx].titleOptimized = false
                }
                changedCount += 1
            }
        }
        return changedCount
    }

    @discardableResult
    public func update(_ bookmark: Bookmark) throws -> Bookmark {
        let trimmedURL = try validatedWebURL(bookmark.url)
        let trimmedTitle = bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw BookmarkStoreError.invalidTitle
        }

        var result = bookmark
        try updatePayload { payload in
            guard let idx = payload.bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
            let target = BookmarkStore.normalizedURL(trimmedURL)
            if payload.bookmarks.contains(where: { $0.id != bookmark.id && BookmarkStore.normalizedURL($0.url) == target }) {
                throw BookmarkStoreError.duplicateURL(trimmedURL)
            }
            var updated = bookmark
            updated.title = trimmedTitle
            updated.url = trimmedURL
            let groupId = payload.bookmarks[idx].groupId
            let usage = payload.bookmarks[idx].usage
            payload.bookmarks[idx] = ObeliskVaultBookmark(bookmark: updated, groupId: groupId, usage: usage)
            if !updated.titleOptimized {
                payload.bookmarks[idx].originalTitle = trimmedTitle
            }
            if updated.isHidden || updated.archivedAt != nil {
                payload.bookmarks[idx].isPinned = false
            }
            result = payload.bookmarks[idx].bookmark
        }
        return result
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
