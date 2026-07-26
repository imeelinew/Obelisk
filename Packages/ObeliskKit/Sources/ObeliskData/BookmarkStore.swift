import Foundation
import ObeliskCore

public enum BookmarkStoreError: LocalizedError, Equatable {
    case invalidURL(String)
    case duplicateURL(String)
    case invalidTitle
    case invalidCollectionName
    case duplicateCollectionName
    case missingCollection
    case missingBookmark

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            "网址格式不正确，需要包含 http:// 或 https://(\(url))"
        case .duplicateURL:
            "这个网址已经在书签里了"
        case .invalidTitle:
            "标题不能为空"
        case .invalidCollectionName:
            "分组名称不能为空"
        case .duplicateCollectionName:
            "已存在同名分组"
        case .missingCollection:
            "找不到这个分组"
        case .missingBookmark:
            "找不到这个书签"
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
        deviceID: UUID
    ) throws -> BookmarkStore {
        let database = try ObeliskDatabase.open(
            rootDirectory: rootDirectory,
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
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("com.eli.Obelisk", isDirectory: true)
            .appendingPathComponent("Sync", isDirectory: true)
    }

    public func snapshot() throws -> ObeliskLibrarySnapshot {
        try database.loadSnapshot()
    }

    @discardableResult
    public func add(
        title: String,
        url: String,
        isHidden: Bool = false,
        collectionID: UUID? = nil
    ) throws -> Bookmark {
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
        try database.saveBookmark(bookmark, collectionID: collectionID)
        return bookmark
    }

    @discardableResult
    public func update(_ bookmark: Bookmark) throws -> Bookmark {
        let current = try snapshot()
        return try update(
            bookmark,
            collectionID: current.collectionByBookmarkID[bookmark.id],
            current: current
        )
    }

    @discardableResult
    public func update(_ bookmark: Bookmark, collectionID: UUID?) throws -> Bookmark {
        let current = try snapshot()
        return try update(bookmark, collectionID: collectionID, current: current)
    }

    private func update(
        _ bookmark: Bookmark,
        collectionID: UUID?,
        current: ObeliskLibrarySnapshot
    ) throws -> Bookmark {
        let trimmedURL = try validatedWebURL(bookmark.url)
        let trimmedTitle = bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw BookmarkStoreError.invalidTitle
        }

        guard current.bookmarks.contains(where: { $0.id == bookmark.id }) else {
            throw BookmarkStoreError.missingBookmark
        }
        if let collectionID,
           !current.collections.contains(where: { $0.id == collectionID }) {
            throw BookmarkStoreError.missingCollection
        }
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
        try database.saveBookmark(updated, collectionID: collectionID)
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
    public func createCollection(name: String) throws -> BookmarkCollection {
        let current = try snapshot()
        let trimmedName = try validatedCollectionName(name, in: current.collections)
        let nextOrder = (current.collections.map(\.sortOrder).max() ?? -1) + 1
        let collection = BookmarkCollection(name: trimmedName, sortOrder: nextOrder)
        try database.saveCollection(collection)
        return collection
    }

    @discardableResult
    public func renameCollection(id: UUID, name: String) throws -> BookmarkCollection {
        let current = try snapshot()
        guard var collection = current.collections.first(where: { $0.id == id }) else {
            throw BookmarkStoreError.missingCollection
        }
        collection.name = try validatedCollectionName(
            name,
            in: current.collections.filter { $0.id != id }
        )
        try database.saveCollection(collection)
        return collection
    }

    public func deleteCollection(id: UUID) throws {
        let current = try snapshot()
        guard current.collections.contains(where: { $0.id == id }) else {
            throw BookmarkStoreError.missingCollection
        }
        try database.deleteCollection(id: id)
    }

    public func setCollection(_ collectionID: UUID?, for bookmarkIDs: Set<UUID>) throws {
        let current = try snapshot()
        if let collectionID,
           !current.collections.contains(where: { $0.id == collectionID }) {
            throw BookmarkStoreError.missingCollection
        }
        let existingBookmarkIDs = Set(current.bookmarks.map(\.id))
        guard bookmarkIDs.isSubset(of: existingBookmarkIDs) else {
            throw BookmarkStoreError.missingBookmark
        }
        try database.setCollection(collectionID, for: bookmarkIDs)
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

    private func validatedCollectionName(
        _ name: String,
        in collections: [BookmarkCollection]
    ) throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw BookmarkStoreError.invalidCollectionName
        }
        guard !collections.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }) else {
            throw BookmarkStoreError.duplicateCollectionName
        }
        return trimmedName
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
