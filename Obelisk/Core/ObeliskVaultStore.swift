import Foundation

struct ObeliskVaultManifest: Codable, Equatable {
    var formatVersion: Int
    var vaultId: UUID
    var createdAt: Date
    var updatedAt: Date
    var payloadFile: String
    var encryption: String

    init(
        formatVersion: Int = ObeliskVaultStore.currentFormatVersion,
        vaultId: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        payloadFile: String = ObeliskVaultStore.payloadFileName,
        encryption: String = ObeliskVaultStore.payloadEncryptionName
    ) {
        self.formatVersion = formatVersion
        self.vaultId = vaultId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.payloadFile = payloadFile
        self.encryption = encryption
    }
}

struct ObeliskVaultPayload: Codable, Equatable {
    var schemaVersion: Int
    var bookmarks: [ObeliskVaultBookmark]
    var groups: [BookmarkCollection]
    var llmProfiles: LLMProfilesSettings?

    init(
        schemaVersion: Int = ObeliskVaultStore.currentPayloadSchemaVersion,
        bookmarks: [ObeliskVaultBookmark] = [],
        groups: [BookmarkCollection] = [],
        llmProfiles: LLMProfilesSettings? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.bookmarks = bookmarks
        self.groups = groups
        self.llmProfiles = llmProfiles
    }
}

struct ObeliskVaultBookmark: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var url: String
    var createdAt: Date
    var titleOptimized: Bool
    var isHidden: Bool
    var archivedAt: Date?
    var isPinned: Bool
    var originalTitle: String?
    var groupId: UUID?
    var usage: UsageRecord?

    init(
        id: UUID,
        title: String,
        url: String,
        createdAt: Date,
        titleOptimized: Bool,
        isHidden: Bool,
        archivedAt: Date?,
        isPinned: Bool,
        originalTitle: String?,
        groupId: UUID?,
        usage: UsageRecord?
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
        self.groupId = groupId
        self.usage = usage
    }

    init(bookmark: Bookmark, groupId: UUID?, usage: UsageRecord?) {
        self.init(
            id: bookmark.id,
            title: bookmark.title,
            url: bookmark.url,
            createdAt: bookmark.createdAt,
            titleOptimized: bookmark.titleOptimized,
            isHidden: bookmark.isHidden,
            archivedAt: bookmark.archivedAt,
            isPinned: bookmark.isPinned,
            originalTitle: bookmark.originalTitle,
            groupId: groupId,
            usage: usage
        )
    }

    var bookmark: Bookmark {
        Bookmark(
            id: id,
            title: title,
            url: url,
            createdAt: createdAt,
            titleOptimized: titleOptimized,
            isHidden: isHidden,
            archivedAt: archivedAt,
            isPinned: isPinned && !isHidden && archivedAt == nil,
            originalTitle: originalTitle
        )
    }
}

/// In-memory payload cache shared by every `ObeliskVaultStore` pointing at
/// the same root directory. All stores (bookmarks, groups, usage, LLM
/// config) are views over the same `payload.bin`; sharing one cache keyed by
/// root path means a write through any store is immediately visible to all
/// others, and a full reload only decrypts the payload once.
private final class ObeliskVaultPayloadCache: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: ObeliskVaultPayloadCache] = [:]

    static func shared(for rootDirectory: URL) -> ObeliskVaultPayloadCache {
        let key = rootDirectory.standardizedFileURL.path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[key] {
            return existing
        }
        let cache = ObeliskVaultPayloadCache()
        registry[key] = cache
        return cache
    }

    private let lock = NSLock()
    private var payload: ObeliskVaultPayload?

    var current: ObeliskVaultPayload? {
        lock.lock()
        defer { lock.unlock() }
        return payload
    }

    func set(_ payload: ObeliskVaultPayload?) {
        lock.lock()
        self.payload = payload
        lock.unlock()
    }
}

/// Owner of `payload.bin` IO. Reads never take the file lock — the payload
/// file is replaced atomically, so a plain read always sees a consistent
/// snapshot. Every write path is serialized through
/// `ObeliskRootDirectoryLock` (reentrant, so callers already holding the
/// lock nest safely).
final class ObeliskVaultStore {
    static let currentFormatVersion = 2
    static let currentPayloadSchemaVersion = 1
    static let manifestFileName = "manifest.json"
    static let payloadFileName = "payload.bin"
    static let payloadEncryptionName = "aes-gcm-v1"

    let rootDirectory: URL

    private let secureCodec: SecureJSONFileCodec
    private let manifestEncoder: JSONEncoder
    private let manifestDecoder: JSONDecoder
    private let payloadEncoder: JSONEncoder
    private let payloadDecoder: JSONDecoder
    private let payloadCache: ObeliskVaultPayloadCache

    init(rootDirectory: URL) {
        self.payloadCache = ObeliskVaultPayloadCache.shared(for: rootDirectory)
        self.rootDirectory = rootDirectory
        self.secureCodec = SecureJSONFileCodec(
            keyStore: KeychainEncryptionKeyStore(encryptedPayloadsRoot: rootDirectory)
        )

        self.manifestEncoder = JSONEncoder()
        self.manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.manifestEncoder.dateEncodingStrategy = .iso8601

        self.manifestDecoder = JSONDecoder()
        self.manifestDecoder.dateDecodingStrategy = .iso8601

        self.payloadEncoder = JSONEncoder()
        self.payloadEncoder.outputFormatting = [.withoutEscapingSlashes]
        self.payloadEncoder.dateEncodingStrategy = .iso8601

        self.payloadDecoder = JSONDecoder()
        self.payloadDecoder.dateDecodingStrategy = .iso8601
    }

    var manifestURL: URL {
        rootDirectory.appendingPathComponent(Self.manifestFileName)
    }

    var payloadURL: URL {
        rootDirectory.appendingPathComponent(Self.payloadFileName)
    }

    var hasV2Payload: Bool {
        FileManager.default.fileExists(atPath: payloadURL.path)
    }

    /// Drops the in-memory payload cache; next `loadPayload` re-reads disk.
    /// Call when the payload file may have been changed externally.
    func invalidateCache() {
        payloadCache.set(nil)
    }

    func loadPayload() throws -> ObeliskVaultPayload {
        if let cached = payloadCache.current {
            return cached
        }

        if hasV2Payload {
            let payload = try readV2Payload()
            setCachedPayload(payload)
            return payload
        }

        return ObeliskVaultPayload()
    }

    func savePayload(_ payload: ObeliskVaultPayload) throws {
        try ObeliskRootDirectoryLock.withExclusiveAccess(rootDirectory: rootDirectory) {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            ObeliskPrivateStorage.markVaultDirectoryAsPackageIfNeeded(rootDirectory)

            let normalized = payload.normalized()
            let payloadData = try payloadEncoder.encode(normalized)
            let payloadTempURL = rootDirectory.appendingPathComponent(".\(Self.payloadFileName).\(UUID().uuidString).tmp")
            try secureCodec.writeData(payloadData, to: payloadTempURL, encrypted: true)

            try replaceItem(at: payloadURL, with: payloadTempURL)
            setCachedPayload(normalized)

            var manifest = (try? loadManifest()) ?? ObeliskVaultManifest()
            manifest.formatVersion = Self.currentFormatVersion
            manifest.updatedAt = Date()
            manifest.payloadFile = Self.payloadFileName
            manifest.encryption = Self.payloadEncryptionName
            try saveManifest(manifest)
        }
    }

    /// Read-modify-write on the whole payload under the root lock. All
    /// partial writers (groups, usage, LLM config) must go through this so
    /// concurrent writers cannot overwrite each other's fields.
    func updatePayload(_ body: (inout ObeliskVaultPayload) throws -> Void) throws {
        try ObeliskRootDirectoryLock.withExclusiveAccess(rootDirectory: rootDirectory) {
            // Re-read inside the lock so we mutate the freshest snapshot.
            invalidateCache()
            var payload = try loadPayload()
            let prior = payload
            try body(&payload)
            guard payload != prior else { return }
            try savePayload(payload)
        }
    }

    private func setCachedPayload(_ payload: ObeliskVaultPayload) {
        payloadCache.set(payload)
    }

    func loadManifest() throws -> ObeliskVaultManifest {
        let data = try LocalFileAccess.readData(from: manifestURL)
        return try manifestDecoder.decode(ObeliskVaultManifest.self, from: data)
    }

    private func saveManifest(_ manifest: ObeliskVaultManifest) throws {
        let data = try manifestEncoder.encode(manifest)
        let tempURL = rootDirectory.appendingPathComponent(".\(Self.manifestFileName).\(UUID().uuidString).tmp")
        try LocalFileAccess.writeData(data, to: tempURL)
        _ = try manifestDecoder.decode(ObeliskVaultManifest.self, from: data)
        try replaceItem(at: manifestURL, with: tempURL)
    }

    private func readV2Payload() throws -> ObeliskVaultPayload {
        let data = try secureCodec.readData(from: payloadURL)
        return try payloadDecoder.decode(ObeliskVaultPayload.self, from: data).normalized()
    }

    private func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(
                destinationURL,
                withItemAt: sourceURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        }
    }
}

private extension ObeliskVaultPayload {
    func normalized() -> ObeliskVaultPayload {
        let groupIds = Set(groups.map(\.id))
        var seenBookmarkIds: Set<UUID> = []
        let bookmarks = bookmarks.compactMap { bookmark -> ObeliskVaultBookmark? in
            guard !seenBookmarkIds.contains(bookmark.id) else { return nil }
            seenBookmarkIds.insert(bookmark.id)

            var bookmark = bookmark
            if let groupId = bookmark.groupId, !groupIds.contains(groupId) {
                bookmark.groupId = nil
            }
            if bookmark.isHidden || bookmark.archivedAt != nil {
                bookmark.isPinned = false
            }
            return bookmark
        }
        .sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }

        let groups = groups.sorted {
            if $0.sortOrder != $1.sortOrder {
                return $0.sortOrder < $1.sortOrder
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        return ObeliskVaultPayload(
            schemaVersion: ObeliskVaultStore.currentPayloadSchemaVersion,
            bookmarks: bookmarks,
            groups: groups,
            llmProfiles: llmProfiles
        )
    }
}
