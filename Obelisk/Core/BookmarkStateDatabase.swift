import Foundation

/// Codable snapshot of per-bookmark state. Production code only uses this for
/// migrating legacy split-file storage into the vault payload; the
/// `BookmarkStateStore` helper that reads/writes it lives in the test target.
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

private extension Set where Element == UUID {
    func sortedByUUIDString() -> [UUID] {
        sorted { $0.uuidString < $1.uuidString }
    }
}
