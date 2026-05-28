import Foundation

/// A user-defined bookmark collection (group). Each visible bookmark belongs
/// to at most one collection, or none (`ungrouped`).
public struct BookmarkCollection: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var sortOrder: Int
    public var showInMenu: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int = 0,
        showInMenu: Bool = false
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.showInMenu = showInMenu
    }
}

public struct BookmarkGroupDatabase: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var collections: [BookmarkCollection]
    /// Bookmark ID → collection ID. Absence means ungrouped.
    public var membershipByBookmarkId: [UUID: UUID]

    public init(
        version: Int = currentVersion,
        collections: [BookmarkCollection] = [],
        membershipByBookmarkId: [UUID: UUID] = [:]
    ) {
        self.version = version
        self.collections = collections
        self.membershipByBookmarkId = membershipByBookmarkId
    }

    private enum CodingKeys: String, CodingKey {
        case version, collections, membershipByBookmarkId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decode(Int.self, forKey: .version)) ?? Self.currentVersion
        collections = (try? container.decode([BookmarkCollection].self, forKey: .collections)) ?? []

        let rawMembership = (try? container.decode([String: UUID].self, forKey: .membershipByBookmarkId)) ?? [:]
        membershipByBookmarkId = Dictionary(
            uniqueKeysWithValues: rawMembership.compactMap { key, value in
                guard let bookmarkId = UUID(uuidString: key) else { return nil }
                return (bookmarkId, value)
            }
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(collections.sorted { $0.sortOrder < $1.sortOrder || ($0.sortOrder == $1.sortOrder && $0.name.localizedStandardCompare($1.name) == .orderedAscending) }, forKey: .collections)
        try container.encode(
            Dictionary(uniqueKeysWithValues: membershipByBookmarkId.map { ($0.key.uuidString, $0.value) }),
            forKey: .membershipByBookmarkId
        )
    }
}

public final class BookmarkGroupStore {
    public private(set) var rootDirectory: URL

    public var fileURL: URL {
        ObeliskDataStorage.representativeURL(
            logicalName: "bookmark_groups.json",
            rootDirectory: rootDirectory
        )
    }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedDatabase: BookmarkGroupDatabase?

    public init(rootDirectory: URL = BookmarkStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        self.decoder = JSONDecoder()
    }

    public func updateRootDirectory(_ rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        invalidateCache()
    }

    public func invalidateCache() {
        cachedDatabase = nil
    }

    public func load() -> BookmarkGroupDatabase {
        if let cachedDatabase {
            return cachedDatabase
        }

        guard
            let data = try? ObeliskDataStorage.readLogical("bookmark_groups.json", rootDirectory: rootDirectory),
            let database = try? decoder.decode(BookmarkGroupDatabase.self, from: data)
        else {
            let empty = BookmarkGroupDatabase()
            cachedDatabase = empty
            return empty
        }
        cachedDatabase = database
        return database
    }

    public func save(_ database: BookmarkGroupDatabase) throws {
        try ObeliskRootDirectoryLock.withExclusiveAccess(rootDirectory: rootDirectory) {
            try saveUnlocked(database)
        }
    }

    public func update(_ body: (inout BookmarkGroupDatabase) -> Void) throws {
        try ObeliskRootDirectoryLock.withExclusiveAccess(rootDirectory: rootDirectory) {
            var database = load()
            let prior = database
            body(&database)
            database.version = BookmarkGroupDatabase.currentVersion
            guard database != prior else { return }
            try saveUnlocked(database)
        }
    }

    private func saveUnlocked(_ database: BookmarkGroupDatabase) throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(database)
        try ObeliskDataStorage.writeLogical(
            data,
            logicalName: "bookmark_groups.json",
            rootDirectory: rootDirectory,
            encrypted: LocalJSONEncryption.isEnabled
        )
        cachedDatabase = database
    }

    public func collectionId(for bookmarkId: UUID) -> UUID? {
        load().membershipByBookmarkId[bookmarkId]
    }

    public func removeMembership(for bookmarkIds: Set<UUID>) throws {
        guard !bookmarkIds.isEmpty else { return }
        try update { database in
            for id in bookmarkIds {
                database.membershipByBookmarkId.removeValue(forKey: id)
            }
        }
    }
}
