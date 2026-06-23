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

    init(rootDirectory: URL) {
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
        self.payloadEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
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

    func loadPayload() throws -> ObeliskVaultPayload {
        if hasV2Payload {
            return try readV2Payload()
        }

        if legacyPayloadExists() {
            let migrated = try loadLegacyPayload()
            try savePayload(migrated)
            try removeLegacyPayloadFiles()
            return migrated
        }

        return ObeliskVaultPayload()
    }

    func savePayload(_ payload: ObeliskVaultPayload) throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        ObeliskPrivateStorage.markVaultDirectoryAsPackageIfNeeded(rootDirectory)

        let payloadData = try payloadEncoder.encode(payload.normalized())
        let payloadTempURL = rootDirectory.appendingPathComponent(".\(Self.payloadFileName).\(UUID().uuidString).tmp")
        try secureCodec.writeData(payloadData, to: payloadTempURL, encrypted: true)

        let verifiedData = try secureCodec.readData(from: payloadTempURL)
        _ = try payloadDecoder.decode(ObeliskVaultPayload.self, from: verifiedData)

        try replaceItem(at: payloadURL, with: payloadTempURL)

        var manifest = (try? loadManifest()) ?? ObeliskVaultManifest()
        manifest.formatVersion = Self.currentFormatVersion
        manifest.updatedAt = Date()
        manifest.payloadFile = Self.payloadFileName
        manifest.encryption = Self.payloadEncryptionName
        try saveManifest(manifest)
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

    private func legacyPayloadExists() -> Bool {
        legacyLogicalNames.contains { logicalName in
            let url = ObeliskPrivateStorage.existingReadableFileURL(
                rootDirectory: rootDirectory,
                logicalName: logicalName
            )
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    private func loadLegacyPayload() throws -> ObeliskVaultPayload {
        let bookmarkDatabase: BookmarkDatabase = try loadLegacyJSON(
            logicalName: "bookmarks.json",
            fallback: BookmarkDatabase()
        )
        var state: BookmarkStateDatabase = try loadLegacyJSON(
            logicalName: "bookmark_state.json",
            fallback: BookmarkStateDatabase()
        )
        let groups: BookmarkGroupDatabase = try loadLegacyJSON(
            logicalName: "bookmark_groups.json",
            fallback: BookmarkGroupDatabase()
        )
        let usage = try loadLegacyUsage()
        let llmProfiles = try loadLegacyLLMProfiles()

        let validIds = Set(bookmarkDatabase.bookmarks.map(\.id))
        state.hiddenIds.formIntersection(validIds)
        state.manualArchivedIds.formIntersection(validIds)
        state.pinnedIds.formIntersection(validIds)
        state.titleOptimizedIds.formIntersection(validIds)
        state.createdAtById = state.createdAtById.filter { validIds.contains($0.key) }
        state.originalTitleById = state.originalTitleById.filter { validIds.contains($0.key) }

        let validGroupIds = Set(groups.collections.map(\.id))
        let membership = groups.membershipByBookmarkId.filter {
            validIds.contains($0.key) && validGroupIds.contains($0.value)
        }

        let bookmarks = bookmarkDatabase.bookmarks.map { bookmark -> ObeliskVaultBookmark in
            var bookmark = bookmark
            bookmark.createdAt = state.createdAtById[bookmark.id] ?? bookmark.createdAt
            bookmark.isHidden = state.hiddenIds.contains(bookmark.id) || bookmark.isHidden
            bookmark.titleOptimized = state.titleOptimizedIds.contains(bookmark.id) || bookmark.titleOptimized
            bookmark.archivedAt = state.manualArchivedIds.contains(bookmark.id)
                ? (bookmark.archivedAt ?? Date.distantPast)
                : bookmark.archivedAt
            bookmark.isPinned = state.pinnedIds.contains(bookmark.id)
                && !bookmark.isHidden
                && bookmark.archivedAt == nil
            bookmark.originalTitle = state.originalTitleById[bookmark.id] ?? bookmark.originalTitle
            return ObeliskVaultBookmark(
                bookmark: bookmark,
                groupId: membership[bookmark.id],
                usage: usage[bookmark.id]
            )
        }

        return ObeliskVaultPayload(
            schemaVersion: Self.currentPayloadSchemaVersion,
            bookmarks: bookmarks,
            groups: groups.collections,
            llmProfiles: llmProfiles
        ).normalized()
    }

    private func loadLegacyJSON<T: Decodable>(logicalName: String, fallback: T) throws -> T {
        let url = ObeliskPrivateStorage.existingReadableFileURL(
            rootDirectory: rootDirectory,
            logicalName: logicalName
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            return fallback
        }
        let data = try secureCodec.readData(from: url)
        return try payloadDecoder.decode(T.self, from: data)
    }

    private func loadLegacyUsage() throws -> [UUID: UsageRecord] {
        let url = ObeliskPrivateStorage.existingReadableFileURL(
            rootDirectory: rootDirectory,
            logicalName: "usage.json"
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try secureCodec.readData(from: url)
        let raw = try payloadDecoder.decode([String: UsageRecord].self, from: data)
        return Dictionary(
            uniqueKeysWithValues: raw.compactMap { key, value in
                guard let id = UUID(uuidString: key) else { return nil }
                return (id, value)
            }
        )
    }

    private func loadLegacyLLMProfiles() throws -> LLMProfilesSettings? {
        let url = ObeliskPrivateStorage.existingReadableFileURL(
            rootDirectory: rootDirectory,
            logicalName: "llm.json"
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try secureCodec.readData(from: url)
        var settings: LLMProfilesSettings
        if let decoded = try? payloadDecoder.decode(LLMProfilesSettings.self, from: data) {
            settings = decoded
        } else if let legacy = try? payloadDecoder.decode(LLMConfig.self, from: data) {
            settings = LLMProfilesSettings(activeSource: .remote, remote: legacy, local: .lmStudioPreset)
        } else {
            return nil
        }
        settings.remote.apiKey = ""
        return settings
    }

    func removeLegacyPayloadFiles() throws {
        for logicalName in legacyLogicalNames {
            let urls = [
                ObeliskPrivateStorage.privateFileURL(rootDirectory: rootDirectory, logicalName: logicalName),
                ObeliskPrivateStorage.plaintextFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
            ]
            for url in urls {
                try? LocalFileAccess.removeItem(at: url)
            }
        }
    }

    private var legacyLogicalNames: [String] {
        [
            "bookmarks.json",
            "bookmark_state.json",
            "bookmark_groups.json",
            "usage.json",
            "llm.json"
        ]
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
