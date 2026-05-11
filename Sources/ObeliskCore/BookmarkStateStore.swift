import Foundation

public struct BookmarkStateDatabase: Codable, Equatable {
    public var version: Int
    public var hiddenIds: Set<UUID>
    public var manualArchivedIds: Set<UUID>
    public var createdAtById: [UUID: Date]
    public var titleOptimizedIds: Set<UUID>

    public init(
        version: Int = 1,
        hiddenIds: Set<UUID> = [],
        manualArchivedIds: Set<UUID> = [],
        createdAtById: [UUID: Date] = [:],
        titleOptimizedIds: Set<UUID> = []
    ) {
        self.version = version
        self.hiddenIds = hiddenIds
        self.manualArchivedIds = manualArchivedIds
        self.createdAtById = createdAtById
        self.titleOptimizedIds = titleOptimizedIds
    }

    private enum CodingKeys: String, CodingKey {
        case version, hiddenIds, manualArchivedIds, createdAtById, titleOptimizedIds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        hiddenIds = Set((try? c.decode([UUID].self, forKey: .hiddenIds)) ?? [])
        manualArchivedIds = Set((try? c.decode([UUID].self, forKey: .manualArchivedIds)) ?? [])
        titleOptimizedIds = Set((try? c.decode([UUID].self, forKey: .titleOptimizedIds)) ?? [])

        let rawCreatedAt = (try? c.decode([String: Date].self, forKey: .createdAtById)) ?? [:]
        createdAtById = Dictionary(
            uniqueKeysWithValues: rawCreatedAt.compactMap { key, value in
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
        try c.encode(titleOptimizedIds.sortedByUUIDString(), forKey: .titleOptimizedIds)
        try c.encode(
            Dictionary(uniqueKeysWithValues: createdAtById.map { ($0.key.uuidString, $0.value) }),
            forKey: .createdAtById
        )
    }
}

public final class BookmarkStateStore {
    public private(set) var rootDirectory: URL
    public var fileURL: URL {
        ObeliskPrivateStorage.activeFileURL(rootDirectory: rootDirectory, logicalName: "bookmark_state.json")
    }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let secureCodec: SecureJSONFileCodec

    public init(rootDirectory: URL = BookmarkStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
        self.secureCodec = SecureJSONFileCodec()

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func updateRootDirectory(_ rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public func load() -> BookmarkStateDatabase {
        let url = ObeliskPrivateStorage.existingReadableFileURL(
            rootDirectory: rootDirectory,
            logicalName: "bookmark_state.json"
        )
        guard
            let data = try? secureCodec.readData(from: url),
            let state = try? decoder.decode(BookmarkStateDatabase.self, from: data)
        else {
            return BookmarkStateDatabase()
        }
        return state
    }

    public func save(_ state: BookmarkStateDatabase) throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(state)
        try secureCodec.writeData(data, to: fileURL)
    }

    public func update(_ body: (inout BookmarkStateDatabase) -> Void) throws {
        var state = load()
        let prior = state
        body(&state)
        guard state != prior else { return }
        try save(state)
    }
}

private extension Set where Element == UUID {
    func sortedByUUIDString() -> [UUID] {
        sorted { $0.uuidString < $1.uuidString }
    }
}
