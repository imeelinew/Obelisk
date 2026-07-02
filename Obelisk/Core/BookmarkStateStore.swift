import Foundation

public struct BookmarkStateDatabase: Codable, Equatable {
    public var version: Int
    public var hiddenIds: Set<UUID>
    public var manualArchivedIds: Set<UUID>
    public var pinnedIds: Set<UUID>
    public var createdAtById: [UUID: Date]
    public var titleOptimizedIds: Set<UUID>
    public var originalTitleById: [UUID: String]

    public init(
        version: Int = 2,
        hiddenIds: Set<UUID> = [],
        manualArchivedIds: Set<UUID> = [],
        pinnedIds: Set<UUID> = [],
        createdAtById: [UUID: Date] = [:],
        titleOptimizedIds: Set<UUID> = [],
        originalTitleById: [UUID: String] = [:]
    ) {
        self.version = version
        self.hiddenIds = hiddenIds
        self.manualArchivedIds = manualArchivedIds
        self.pinnedIds = pinnedIds
        self.createdAtById = createdAtById
        self.titleOptimizedIds = titleOptimizedIds
        self.originalTitleById = originalTitleById
    }

    private enum CodingKeys: String, CodingKey {
        case version, hiddenIds, manualArchivedIds, pinnedIds, createdAtById, titleOptimizedIds, originalTitleById
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        hiddenIds = Set((try? c.decode([UUID].self, forKey: .hiddenIds)) ?? [])
        manualArchivedIds = Set((try? c.decode([UUID].self, forKey: .manualArchivedIds)) ?? [])
        pinnedIds = Set((try? c.decode([UUID].self, forKey: .pinnedIds)) ?? [])
        titleOptimizedIds = Set((try? c.decode([UUID].self, forKey: .titleOptimizedIds)) ?? [])

        let rawCreatedAt = (try? c.decode([String: Date].self, forKey: .createdAtById)) ?? [:]
        createdAtById = Dictionary(
            uniqueKeysWithValues: rawCreatedAt.compactMap { key, value in
                guard let id = UUID(uuidString: key) else { return nil }
                return (id, value)
            }
        )

        let rawOriginalTitles = (try? c.decode([String: String].self, forKey: .originalTitleById)) ?? [:]
        originalTitleById = Dictionary(
            uniqueKeysWithValues: rawOriginalTitles.compactMap { key, value in
                guard let id = UUID(uuidString: key) else { return nil }
                return (id, value)
            }
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(hiddenIds.sortedByUUIDString(), forKey: .hiddenIds)
        try c.encode(manualArchivedIds.sortedByUUIDString(), forKey: .manualArchivedIds)
        try c.encode(pinnedIds.sortedByUUIDString(), forKey: .pinnedIds)
        try c.encode(titleOptimizedIds.sortedByUUIDString(), forKey: .titleOptimizedIds)
        try c.encode(
            Dictionary(uniqueKeysWithValues: createdAtById.map { ($0.key.uuidString, $0.value) }),
            forKey: .createdAtById
        )
        try c.encode(
            Dictionary(uniqueKeysWithValues: originalTitleById.map { ($0.key.uuidString, $0.value) }),
            forKey: .originalTitleById
        )
    }
}

public final class BookmarkStateStore {
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

    public func load() -> BookmarkStateDatabase {
        guard let payload = try? vaultStore.loadPayload() else {
            return BookmarkStateDatabase()
        }
        return Self.state(from: payload)
    }

    public func save(_ state: BookmarkStateDatabase) throws {
        try vaultStore.updatePayload { payload in
            Self.apply(state, to: &payload)
        }
    }

    public func update(_ body: (inout BookmarkStateDatabase) -> Void) throws {
        try vaultStore.updatePayload { payload in
            var state = Self.state(from: payload)
            let prior = state
            body(&state)
            guard state != prior else { return }
            Self.apply(state, to: &payload)
        }
    }

    private static func apply(_ state: BookmarkStateDatabase, to payload: inout ObeliskVaultPayload) {
        let validIds = Set(payload.bookmarks.map(\.id))
        let hiddenIds = state.hiddenIds.intersection(validIds)
        let manualArchivedIds = state.manualArchivedIds.intersection(validIds)
        let pinnedIds = state.pinnedIds.intersection(validIds)
        let titleOptimizedIds = state.titleOptimizedIds.intersection(validIds)

        payload.bookmarks = payload.bookmarks.map { bookmark in
            var bookmark = bookmark
            bookmark.createdAt = state.createdAtById[bookmark.id] ?? bookmark.createdAt
            bookmark.isHidden = hiddenIds.contains(bookmark.id)
            bookmark.titleOptimized = titleOptimizedIds.contains(bookmark.id)
            bookmark.archivedAt = manualArchivedIds.contains(bookmark.id)
                ? (bookmark.archivedAt ?? Date.distantPast)
                : nil
            bookmark.isPinned = pinnedIds.contains(bookmark.id)
                && !bookmark.isHidden
                && bookmark.archivedAt == nil
            bookmark.originalTitle = state.originalTitleById[bookmark.id] ?? bookmark.originalTitle
            return bookmark
        }
    }

    private static func state(from payload: ObeliskVaultPayload) -> BookmarkStateDatabase {
        BookmarkStateDatabase(
            version: 2,
            hiddenIds: Set(payload.bookmarks.filter(\.isHidden).map(\.id)),
            manualArchivedIds: Set(payload.bookmarks.filter { $0.archivedAt != nil }.map(\.id)),
            pinnedIds: Set(payload.bookmarks.filter { $0.isPinned && !$0.isHidden && $0.archivedAt == nil }.map(\.id)),
            createdAtById: Dictionary(
                uniqueKeysWithValues: payload.bookmarks.compactMap { bookmark in
                    guard bookmark.createdAt > .distantPast else { return nil }
                    return (bookmark.id, bookmark.createdAt)
                }
            ),
            titleOptimizedIds: Set(payload.bookmarks.filter(\.titleOptimized).map(\.id)),
            originalTitleById: Dictionary(
                uniqueKeysWithValues: payload.bookmarks.compactMap { bookmark in
                    guard let title = bookmark.originalTitle, !title.isEmpty else { return nil }
                    return (bookmark.id, title)
                }
            )
        )
    }
}

private extension Set where Element == UUID {
    func sortedByUUIDString() -> [UUID] {
        sorted { $0.uuidString < $1.uuidString }
    }
}
