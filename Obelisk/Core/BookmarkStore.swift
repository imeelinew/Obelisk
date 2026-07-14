import Foundation
import ObeliskCore
import ObeliskData

public enum BookmarkStoreError: LocalizedError {
    case invalidURL(String)
    case duplicateURL(String)
    case invalidTitle

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            "网址格式不正确,需要包含 http:// 或 https://(\(url))"
        case .duplicateURL:
            "这个网址已经在书签里了"
        case .invalidTitle:
            "标题不能为空"
        }
    }
}

public final class BookmarkStore {
    public let database: ObeliskDatabase

    public var rootDirectory: URL { database.rootDirectory }
    public var fileURL: URL { database.fileURL }

    public init(database: ObeliskDatabase) {
        self.database = database
    }

    public static func open(
        rootDirectory: URL = defaultRootDirectory(),
        ownerID: UUID? = nil,
        deviceID: UUID
    ) async throws -> BookmarkStore {
        let database = try await ObeliskDatabase.open(
            rootDirectory: rootDirectory,
            ownerID: ownerID,
            deviceID: deviceID
        )
        return BookmarkStore(database: database)
    }

    public static func environmentRootOverride() -> URL? {
        guard let value = ProcessInfo.processInfo.environment["OBELISK_HOME"], !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
    }

    public static func defaultRootDirectory() -> URL {
        if let override = environmentRootOverride() {
            return override
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("com.eli.Obelisk", isDirectory: true)
            .appendingPathComponent("Sync", isDirectory: true)
    }

    public func snapshot() throws -> ObeliskLibrarySnapshot {
        try database.loadSnapshot()
    }

    @discardableResult
    public func add(title: String, url: String, isHidden: Bool = false) throws -> Bookmark {
        let trimmedURL = try validatedWebURL(url)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw BookmarkStoreError.invalidTitle
        }

        let current = try snapshot()
        let target = Self.normalizedURL(trimmedURL)
        if current.bookmarks.contains(where: { Self.normalizedURL($0.url) == target }) {
            throw BookmarkStoreError.duplicateURL(trimmedURL)
        }

        let bookmark = Bookmark(
            title: trimmedTitle,
            url: trimmedURL,
            isHidden: isHidden,
            originalTitle: trimmedTitle
        )
        try database.saveBookmark(bookmark, collectionID: nil)
        return bookmark
    }

    @discardableResult
    public func update(_ bookmark: Bookmark) throws -> Bookmark {
        let trimmedURL = try validatedWebURL(bookmark.url)
        let trimmedTitle = bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw BookmarkStoreError.invalidTitle
        }

        let current = try snapshot()
        let target = Self.normalizedURL(trimmedURL)
        if current.bookmarks.contains(where: { $0.id != bookmark.id && Self.normalizedURL($0.url) == target }) {
            throw BookmarkStoreError.duplicateURL(trimmedURL)
        }

        var updated = bookmark
        updated.title = trimmedTitle
        updated.url = trimmedURL
        if !updated.titleOptimized {
            updated.originalTitle = trimmedTitle
        }
        if updated.isHidden || updated.archivedAt != nil {
            updated.isPinned = false
        }
        try database.saveBookmark(updated, collectionID: current.collectionByBookmarkID[bookmark.id])
        return updated
    }

    public func delete(ids: Set<UUID>) throws {
        for id in ids {
            try database.deleteBookmark(id: id)
        }
    }

    public func setArchived(_ isArchived: Bool, ids: Set<UUID>, at date: Date = Date()) throws {
        let current = try snapshot()
        for var bookmark in current.bookmarks where ids.contains(bookmark.id) {
            bookmark.archivedAt = isArchived ? date : nil
            if isArchived {
                bookmark.isPinned = false
            }
            try database.saveBookmark(bookmark, collectionID: current.collectionByBookmarkID[bookmark.id])
        }
    }

    public func setPinned(_ isPinned: Bool, ids: Set<UUID>) throws {
        let current = try snapshot()
        for var bookmark in current.bookmarks where ids.contains(bookmark.id) {
            bookmark.isPinned = isPinned && !bookmark.isHidden && bookmark.archivedAt == nil
            try database.saveBookmark(bookmark, collectionID: current.collectionByBookmarkID[bookmark.id])
        }
    }

    @discardableResult
    public func applyTitleOptimizations(_ optimizedTitles: [UUID: String]) throws -> Int {
        let current = try snapshot()
        var count = 0
        for var bookmark in current.bookmarks {
            guard
                !bookmark.titleOptimized,
                let title = optimizedTitles[bookmark.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !title.isEmpty
            else {
                continue
            }
            if bookmark.originalTitle == nil {
                bookmark.originalTitle = bookmark.title
            }
            bookmark.title = title
            bookmark.titleOptimized = true
            try database.saveBookmark(bookmark, collectionID: current.collectionByBookmarkID[bookmark.id])
            count += 1
        }
        return count
    }

    @discardableResult
    public func revertTitleOptimizations(ids: Set<UUID>) throws -> Int {
        let current = try snapshot()
        var count = 0
        for var bookmark in current.bookmarks where ids.contains(bookmark.id) && bookmark.titleOptimized {
            guard let title = bookmark.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                continue
            }
            bookmark.title = title
            bookmark.titleOptimized = false
            try database.saveBookmark(bookmark, collectionID: current.collectionByBookmarkID[bookmark.id])
            count += 1
        }
        return count
    }

    @discardableResult
    public func applyOriginalTitles(_ titles: [UUID: String], forceApplyDisplay: Bool = false) throws -> Int {
        let current = try snapshot()
        var count = 0
        for var bookmark in current.bookmarks {
            guard let title = titles[bookmark.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                continue
            }
            bookmark.originalTitle = title
            if forceApplyDisplay || !bookmark.titleOptimized {
                bookmark.title = title
                bookmark.titleOptimized = false
            }
            try database.saveBookmark(bookmark, collectionID: current.collectionByBookmarkID[bookmark.id])
            count += 1
        }
        return count
    }

    private func validatedWebURL(_ rawURL: String) throws -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let parsed = URL(string: trimmed),
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
