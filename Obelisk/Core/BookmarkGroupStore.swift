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
        ObeliskVaultStore(rootDirectory: rootDirectory).payloadURL
    }

    private var vaultStore: ObeliskVaultStore

    public init(rootDirectory: URL = BookmarkStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
        self.vaultStore = ObeliskVaultStore(rootDirectory: rootDirectory)
    }

    public func updateRootDirectory(_ rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        vaultStore = ObeliskVaultStore(rootDirectory: rootDirectory)
    }

    public func invalidateCache() {
        vaultStore.invalidateCache()
    }

    public func load() -> BookmarkGroupDatabase {
        guard let payload = try? vaultStore.loadPayload() else {
            return BookmarkGroupDatabase()
        }
        return Self.database(from: payload)
    }

    public func save(_ database: BookmarkGroupDatabase) throws {
        try vaultStore.updatePayload { payload in
            Self.apply(database, to: &payload)
        }
    }

    public func update(_ body: (inout BookmarkGroupDatabase) -> Void) throws {
        try vaultStore.updatePayload { payload in
            var database = Self.database(from: payload)
            let prior = database
            body(&database)
            database.version = BookmarkGroupDatabase.currentVersion
            guard database != prior else { return }
            Self.apply(database, to: &payload)
        }
    }

    private static func apply(_ database: BookmarkGroupDatabase, to payload: inout ObeliskVaultPayload) {
        let collections = database.collections.sorted {
            if $0.sortOrder != $1.sortOrder {
                return $0.sortOrder < $1.sortOrder
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let validGroupIds = Set(collections.map(\.id))
        let membership = database.membershipByBookmarkId.filter { validGroupIds.contains($0.value) }

        payload.groups = collections
        payload.bookmarks = payload.bookmarks.map { bookmark in
            var bookmark = bookmark
            bookmark.groupId = membership[bookmark.id]
            return bookmark
        }
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

    private static func database(from payload: ObeliskVaultPayload) -> BookmarkGroupDatabase {
        let groupIds = Set(payload.groups.map(\.id))
        let membership = Dictionary(
            uniqueKeysWithValues: payload.bookmarks.compactMap { bookmark -> (UUID, UUID)? in
                guard let groupId = bookmark.groupId, groupIds.contains(groupId) else { return nil }
                return (bookmark.id, groupId)
            }
        )
        return BookmarkGroupDatabase(
            version: BookmarkGroupDatabase.currentVersion,
            collections: payload.groups,
            membershipByBookmarkId: membership
        )
    }
}
