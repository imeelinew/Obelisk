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
        ObeliskDataStorage.representativeURL(
            logicalName: "bookmark_state.json",
            rootDirectory: rootDirectory
        )
    }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedState: BookmarkStateDatabase?

    public init(rootDirectory: URL = BookmarkStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func updateRootDirectory(_ rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        invalidateCache()
    }

    public func invalidateCache() {
        cachedState = nil
    }

    public func load() -> BookmarkStateDatabase {
        if let cachedState {
            return cachedState
        }

        guard
            let data = try? ObeliskDataStorage.readLogical("bookmark_state.json", rootDirectory: rootDirectory),
            let state = try? decoder.decode(BookmarkStateDatabase.self, from: data)
        else {
            let empty = BookmarkStateDatabase()
            cachedState = empty
            return empty
        }
        cachedState = state
        return state
    }

    public func save(_ state: BookmarkStateDatabase) throws {
        try ObeliskRootDirectoryLock.withExclusiveAccess(rootDirectory: rootDirectory) {
            try saveUnlocked(state)
        }
    }

    public func update(_ body: (inout BookmarkStateDatabase) -> Void) throws {
        try ObeliskRootDirectoryLock.withExclusiveAccess(rootDirectory: rootDirectory) {
            var state = load()
            let prior = state
            body(&state)
            guard state != prior else { return }
            try saveUnlocked(state)
        }
    }

    private func saveUnlocked(_ state: BookmarkStateDatabase) throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(state)
        try ObeliskDataStorage.writeLogical(
            data,
            logicalName: "bookmark_state.json",
            rootDirectory: rootDirectory,
            encrypted: LocalJSONEncryption.isEnabled
        )
        cachedState = state
    }
}

private extension Set where Element == UUID {
    func sortedByUUIDString() -> [UUID] {
        sorted { $0.uuidString < $1.uuidString }
    }
}
