import CryptoKit
import Foundation
import SQLite3

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
    static let currentFormatVersion = 3
    static let currentPayloadSchemaVersion = 1
    static let databaseFileName = "store.sqlite"

    let rootDirectory: URL
    private let coordinator: ObeliskDatabaseCoordinator

    init(rootDirectory: URL, keyStore: VaultKeyMaterialStore? = nil) {
        self.rootDirectory = rootDirectory
        if let keyStore {
            self.coordinator = ObeliskDatabaseCoordinator(rootDirectory: rootDirectory, keyStore: keyStore)
        } else {
            self.coordinator = ObeliskDatabaseCoordinator.shared(for: rootDirectory)
        }
    }

    var databaseURL: URL {
        rootDirectory.appendingPathComponent(Self.databaseFileName)
    }

    var databaseExists: Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    func invalidateCache() {
        coordinator.invalidateCache()
    }

    func loadPayload() throws -> ObeliskVaultPayload {
        guard databaseExists else { return ObeliskVaultPayload() }
        return try coordinator.loadPayload()
    }

    func createEmptyIfNeeded(recoveryKeyOutputURL: URL? = nil) throws {
        guard !databaseExists else {
            _ = try coordinator.loadPayload()
            return
        }
        try coordinator.initializeNewVault(
            payload: ObeliskVaultPayload(),
            recoveryKeyOutputURL: recoveryKeyOutputURL ?? RecoveryKeyDocument.defaultURL()
        )
    }

    func bootstrap(_ payload: ObeliskVaultPayload, recoveryKeyOutputURL: URL) throws {
        guard !databaseExists else {
            throw ObeliskStorageError.databaseOperationFailed("目标数据库已存在，拒绝覆盖")
        }
        try coordinator.initializeNewVault(
            payload: payload.normalized(),
            recoveryKeyOutputURL: recoveryKeyOutputURL
        )
    }

    func savePayload(_ payload: ObeliskVaultPayload) throws {
        if !databaseExists {
            try coordinator.initializeNewVault(
                payload: payload.normalized(),
                recoveryKeyOutputURL: RecoveryKeyDocument.defaultURL()
            )
            return
        }
        let prior = try coordinator.loadPayload()
        try coordinator.savePayload(payload.normalized(), prior: prior)
    }

    func updatePayload(_ body: (inout ObeliskVaultPayload) throws -> Void) throws {
        if !databaseExists {
            try createEmptyIfNeeded()
        }
        try coordinator.updatePayload(body)
    }

    func validate() throws -> ObeliskVaultPayload {
        try coordinator.validate()
    }

    func createEncryptedBackup(at destination: URL) throws {
        try coordinator.createBackup(at: destination)
    }

    func restoreKey(using encodedRecoveryKey: String) throws {
        try coordinator.restoreKey(using: ObeliskRecoveryKey(encoded: encodedRecoveryKey))
    }
}

private final class ObeliskDatabaseCoordinator: @unchecked Sendable {
    private struct RecordKey: Hashable {
        let kind: String
        let id: String
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: ObeliskDatabaseCoordinator] = [:]
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func shared(for rootDirectory: URL) -> ObeliskDatabaseCoordinator {
        let path = rootDirectory.standardizedFileURL.path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[path] { return existing }
        let keyStore: VaultKeyMaterialStore = ProcessInfo.processInfo.environment["OBELISK_USE_IN_MEMORY_KEYSTORE"] == "1"
            ? InMemoryVaultKeyStore()
            : KeychainVaultKeyStore()
        let coordinator = ObeliskDatabaseCoordinator(rootDirectory: rootDirectory, keyStore: keyStore)
        registry[path] = coordinator
        return coordinator
    }

    private let rootDirectory: URL
    private let databaseURL: URL
    private let keyStore: VaultKeyMaterialStore
    private let lock = NSRecursiveLock()
    private let codec = VaultRecordCodec()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var database: OpaquePointer?
    private var cachedPayload: ObeliskVaultPayload?
    private var cachedVaultID: UUID?
    private var cachedKeyData: Data?

    init(rootDirectory: URL, keyStore: VaultKeyMaterialStore) {
        self.rootDirectory = rootDirectory
        self.databaseURL = rootDirectory.appendingPathComponent(ObeliskVaultStore.databaseFileName)
        self.keyStore = keyStore
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func invalidateCache() {
        lock.lock()
        cachedPayload = nil
        lock.unlock()
    }

    func initializeNewVault(payload: ObeliskVaultPayload, recoveryKeyOutputURL: URL) throws {
        try withLock {
            guard !FileManager.default.fileExists(atPath: databaseURL.path) else {
                throw ObeliskStorageError.databaseOperationFailed("目标数据库已存在")
            }
            try prepareRootDirectory()
            try openDatabase()
            try createSchema()

            let vaultID = UUID()
            let key = SymmetricKey(size: .bits256)
            let keyData = key.withUnsafeBytes { Data($0) }
            let recoveryKey = ObeliskRecoveryKey()
            let wrappedKey = try codec.wrapKey(keyData, recoveryKey: recoveryKey, vaultID: vaultID)
            var recoveryDocumentCreated = false
            do {
                try RecoveryKeyDocument.persist(recoveryKey, vaultID: vaultID, to: recoveryKeyOutputURL)
                recoveryDocumentCreated = true
                try beginTransaction()
                try writeMetadata(key: "formatVersion", value: Data(String(ObeliskVaultStore.currentFormatVersion).utf8))
                try writeMetadata(key: "payloadSchemaVersion", value: Data(String(ObeliskVaultStore.currentPayloadSchemaVersion).utf8))
                try writeMetadata(key: "vaultID", value: Data(vaultID.uuidString.lowercased().utf8))
                try writeMetadata(key: "recoveryWrappedKey", value: wrappedKey)
                try writePayload(payload.normalized(), prior: nil, keyData: keyData, vaultID: vaultID)
                try commitTransaction()
                try applyPrivatePermissions()
                try keyStore.persistNewKeyData(keyData)
            } catch {
                rollbackTransaction()
                closeDatabase()
                for suffix in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
                }
                if recoveryDocumentCreated {
                    try? FileManager.default.removeItem(at: recoveryKeyOutputURL)
                }
                cachedVaultID = nil
                cachedKeyData = nil
                cachedPayload = nil
                throw error
            }

            cachedVaultID = vaultID
            cachedKeyData = keyData
            cachedPayload = payload.normalized()
        }
    }

    func loadPayload() throws -> ObeliskVaultPayload {
        try withLock {
            if let cachedPayload { return cachedPayload }
            try openExistingVault()
            guard let keyData = cachedKeyData, let vaultID = cachedVaultID else {
                throw ObeliskStorageError.encryptionKeyMissing
            }
            let payload = try readPayload(keyData: keyData, vaultID: vaultID).normalized()
            cachedPayload = payload
            return payload
        }
    }

    func savePayload(_ payload: ObeliskVaultPayload, prior: ObeliskVaultPayload) throws {
        try withLock {
            try openExistingVault()
            guard let keyData = cachedKeyData, let vaultID = cachedVaultID else {
                throw ObeliskStorageError.encryptionKeyMissing
            }
            do {
                try beginTransaction()
                try writePayload(payload.normalized(), prior: prior.normalized(), keyData: keyData, vaultID: vaultID)
                try commitTransaction()
            } catch {
                rollbackTransaction()
                throw error
            }
            cachedPayload = payload.normalized()
        }
    }

    func updatePayload(_ body: (inout ObeliskVaultPayload) throws -> Void) throws {
        try withLock {
            let prior = try loadPayload()
            var next = prior
            try body(&next)
            next = next.normalized()
            guard next != prior else { return }
            try savePayload(next, prior: prior)
        }
    }

    func validate() throws -> ObeliskVaultPayload {
        try withLock {
            try openExistingVault()
            var statement: OpaquePointer?
            try prepare("PRAGMA quick_check;", statement: &statement)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let result = sqlite3_column_text(statement, 0),
                  String(cString: result) == "ok" else {
                throw ObeliskStorageError.databaseCorrupt
            }
            cachedPayload = nil
            return try loadPayload()
        }
    }

    func restoreKey(using recoveryKey: ObeliskRecoveryKey) throws {
        try withLock {
            try openDatabase()
            try validateSchemaMetadata()
            let vaultID = try readVaultID()
            guard let wrapped = try readMetadata(key: "recoveryWrappedKey") else {
                throw ObeliskStorageError.databaseCorrupt
            }
            let candidate = try codec.unwrapKey(wrapped, recoveryKey: recoveryKey, vaultID: vaultID)
            _ = try readPayload(keyData: candidate, vaultID: vaultID)
            try keyStore.restoreKeyData(candidate)
            cachedVaultID = vaultID
            cachedKeyData = candidate
            cachedPayload = nil
        }
    }

    func createBackup(at destination: URL) throws {
        try withLock {
            try openExistingVault()
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw ObeliskStorageError.databaseOperationFailed("备份目标已存在")
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var backupDatabase: OpaquePointer?
            guard sqlite3_open_v2(destination.path, &backupDatabase, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
                  let backupConnection = backupDatabase else {
                throw ObeliskStorageError.databaseOpenFailed("无法创建备份数据库")
            }
            defer {
                if let backupDatabase { sqlite3_close(backupDatabase) }
            }
            guard let backup = sqlite3_backup_init(backupConnection, "main", database, "main") else {
                throw ObeliskStorageError.databaseOperationFailed("无法初始化 SQLite 备份")
            }
            let step = sqlite3_backup_step(backup, -1)
            let finish = sqlite3_backup_finish(backup)
            guard step == SQLITE_DONE, finish == SQLITE_OK else {
                throw ObeliskStorageError.databaseOperationFailed("SQLite 备份失败")
            }
            guard sqlite3_exec(backupConnection, "PRAGMA journal_mode=DELETE;", nil, nil, nil) == SQLITE_OK else {
                throw ObeliskStorageError.databaseOperationFailed("无法完成便携式 SQLite 备份")
            }
            sqlite3_close(backupConnection)
            backupDatabase = nil
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: destination.path + suffix)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }

    private func openExistingVault() throws {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw ObeliskStorageError.databaseOpenFailed("数据库不存在")
        }
        try openDatabase()
        try validateSchemaMetadata()
        if cachedVaultID == nil { cachedVaultID = try readVaultID() }
        if cachedKeyData == nil {
            guard let keyData = try keyStore.existingKeyData() else {
                throw ObeliskStorageError.encryptionKeyMissing
            }
            cachedKeyData = keyData
        }
    }

    private func openDatabase() throws {
        if database != nil { return }
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &connection, flags, nil) == SQLITE_OK, let connection else {
            let message = connection.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "unknown error"
            if let connection { sqlite3_close(connection) }
            throw ObeliskStorageError.databaseOpenFailed(message)
        }
        database = connection
        sqlite3_busy_timeout(connection, 5_000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=FULL;")
        try execute("PRAGMA foreign_keys=ON;")
        try applyPrivatePermissions()
    }

    private func closeDatabase() {
        guard let database else { return }
        sqlite3_close(database)
        self.database = nil
    }

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value BLOB NOT NULL
            );
            """
        )
        try execute(
            """
            CREATE TABLE records (
                kind TEXT NOT NULL,
                id TEXT NOT NULL,
                updated_at REAL NOT NULL,
                payload BLOB NOT NULL,
                PRIMARY KEY (kind, id)
            ) WITHOUT ROWID;
            """
        )
        try execute("CREATE INDEX records_kind_index ON records(kind);")
    }

    private func validateSchemaMetadata() throws {
        guard let formatData = try readMetadata(key: "formatVersion"),
              String(data: formatData, encoding: .utf8) == String(ObeliskVaultStore.currentFormatVersion),
              let schemaData = try readMetadata(key: "payloadSchemaVersion"),
              String(data: schemaData, encoding: .utf8) == String(ObeliskVaultStore.currentPayloadSchemaVersion) else {
            throw ObeliskStorageError.databaseCorrupt
        }
    }

    private func readVaultID() throws -> UUID {
        guard let data = try readMetadata(key: "vaultID"),
              let string = String(data: data, encoding: .utf8),
              let id = UUID(uuidString: string) else {
            throw ObeliskStorageError.databaseCorrupt
        }
        return id
    }

    private func readPayload(keyData: Data, vaultID: UUID) throws -> ObeliskVaultPayload {
        var payload = ObeliskVaultPayload()
        var statement: OpaquePointer?
        try prepare("SELECT kind, id, payload FROM records ORDER BY kind, id;", statement: &statement)
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let kindText = sqlite3_column_text(statement, 0),
                  let idText = sqlite3_column_text(statement, 1),
                  let bytes = sqlite3_column_blob(statement, 2) else {
                throw ObeliskStorageError.databaseCorrupt
            }
            let kind = String(cString: kindText)
            let id = String(cString: idText)
            let encrypted = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
            let plaintext = try codec.open(
                encrypted,
                keyData: keyData,
                authenticatedData: authenticatedData(vaultID: vaultID, kind: kind, id: id)
            )
            switch kind {
            case "bookmark":
                let bookmark = try decoder.decode(ObeliskVaultBookmark.self, from: plaintext)
                guard bookmark.id.uuidString.lowercased() == id else {
                    throw ObeliskStorageError.databaseCorrupt
                }
                payload.bookmarks.append(bookmark)
            case "groups":
                guard id == "primary" else { throw ObeliskStorageError.databaseCorrupt }
                payload.groups = try decoder.decode([BookmarkCollection].self, from: plaintext)
            case "llmProfiles":
                guard id == "primary" else { throw ObeliskStorageError.databaseCorrupt }
                payload.llmProfiles = try decoder.decode(LLMProfilesSettings.self, from: plaintext)
            default:
                throw ObeliskStorageError.databaseCorrupt
            }
        }
        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
            throw databaseError()
        }
        return payload
    }

    private func writePayload(
        _ payload: ObeliskVaultPayload,
        prior: ObeliskVaultPayload?,
        keyData: Data,
        vaultID: UUID
    ) throws {
        let nextRecords = try encodedRecords(for: payload)
        let priorRecords = try prior.map(encodedRecords(for:)) ?? [:]

        for key in priorRecords.keys where nextRecords[key] == nil {
            try deleteRecord(key)
        }
        for (key, plaintext) in nextRecords where priorRecords[key] != plaintext {
            let encrypted = try codec.seal(
                plaintext,
                keyData: keyData,
                authenticatedData: authenticatedData(vaultID: vaultID, kind: key.kind, id: key.id)
            )
            try upsertRecord(key, encrypted: encrypted)
        }
    }

    private func encodedRecords(for payload: ObeliskVaultPayload) throws -> [RecordKey: Data] {
        var records: [RecordKey: Data] = [:]
        for bookmark in payload.bookmarks {
            records[RecordKey(kind: "bookmark", id: bookmark.id.uuidString.lowercased())] = try encoder.encode(bookmark)
        }
        records[RecordKey(kind: "groups", id: "primary")] = try encoder.encode(payload.groups)
        if let profiles = payload.llmProfiles {
            records[RecordKey(kind: "llmProfiles", id: "primary")] = try encoder.encode(profiles)
        }
        return records
    }

    private func authenticatedData(vaultID: UUID, kind: String, id: String) -> Data {
        Data("obelisk.record.v3|\(vaultID.uuidString.lowercased())|\(kind)|\(id)|1".utf8)
    }

    private func upsertRecord(_ key: RecordKey, encrypted: Data) throws {
        var statement: OpaquePointer?
        try prepare(
            "INSERT INTO records(kind, id, updated_at, payload) VALUES(?, ?, ?, ?) ON CONFLICT(kind, id) DO UPDATE SET updated_at=excluded.updated_at, payload=excluded.payload;",
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key.kind, -1, Self.sqliteTransient)
        sqlite3_bind_text(statement, 2, key.id, -1, Self.sqliteTransient)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        _ = encrypted.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(encrypted.count), Self.sqliteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func deleteRecord(_ key: RecordKey) throws {
        var statement: OpaquePointer?
        try prepare("DELETE FROM records WHERE kind = ? AND id = ?;", statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key.kind, -1, Self.sqliteTransient)
        sqlite3_bind_text(statement, 2, key.id, -1, Self.sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func writeMetadata(key: String, value: Data) throws {
        var statement: OpaquePointer?
        try prepare("INSERT OR REPLACE INTO metadata(key, value) VALUES(?, ?);", statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, Self.sqliteTransient)
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(value.count), Self.sqliteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func readMetadata(key: String) throws -> Data? {
        var statement: OpaquePointer?
        try prepare("SELECT value FROM metadata WHERE key = ?;", statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, Self.sqliteTransient)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
            throw databaseError()
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    private func prepare(_ sql: String, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            throw ObeliskStorageError.databaseOperationFailed(message)
        }
    }

    private func beginTransaction() throws { try execute("BEGIN IMMEDIATE;") }
    private func commitTransaction() throws { try execute("COMMIT;") }
    private func rollbackTransaction() { try? execute("ROLLBACK;") }

    private func databaseError() -> ObeliskStorageError {
        let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "unknown SQLite error"
        return .databaseOperationFailed(message)
    }

    private func prepareRootDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirectory.path)
    }

    private func applyPrivatePermissions() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirectory.path)
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private extension ObeliskVaultPayload {
    func normalized() -> ObeliskVaultPayload {
        let groupIds = Set(groups.map(\.id))
        var seenBookmarkIds: Set<UUID> = []
        let normalizedBookmarks = bookmarks.compactMap { bookmark -> ObeliskVaultBookmark? in
            guard seenBookmarkIds.insert(bookmark.id).inserted else { return nil }
            var bookmark = bookmark
            if let groupId = bookmark.groupId, !groupIds.contains(groupId) {
                bookmark.groupId = nil
            }
            if bookmark.isHidden || bookmark.archivedAt != nil {
                bookmark.isPinned = false
            }
            return bookmark
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        let normalizedGroups = groups.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        return ObeliskVaultPayload(
            schemaVersion: ObeliskVaultStore.currentPayloadSchemaVersion,
            bookmarks: normalizedBookmarks,
            groups: normalizedGroups,
            llmProfiles: llmProfiles
        )
    }
}
