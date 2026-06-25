import CryptoKit
import Foundation
import os
import Security

public enum LocalJSONEncryption {
    public static let enabledKey = "encryptLocalJSONData"
    public static let disabledByAuthenticatedUserKey = "encryptLocalJSONDataDisabledByAuthenticatedUser"

    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    public static var disabledByAuthenticatedUser: Bool {
        get { UserDefaults.standard.bool(forKey: disabledByAuthenticatedUserKey) }
        set { UserDefaults.standard.set(newValue, forKey: disabledByAuthenticatedUserKey) }
    }

    public static func normalizeDefault(
        in defaults: UserDefaults = .standard,
        hadStoredEnabledPreference: Bool,
        preservesUnauthenticatedDisabledState: Bool = false
    ) {
        if preservesUnauthenticatedDisabledState,
           hadStoredEnabledPreference,
           !defaults.bool(forKey: enabledKey) {
            defaults.set(false, forKey: enabledKey)
        } else {
            defaults.set(true, forKey: enabledKey)
        }
        defaults.set(false, forKey: disabledByAuthenticatedUserKey)
    }
}

public enum ObeliskPrivateStorage {
    public static let vaultDirectoryName = "Obelisk.obelisk"

    public static func faviconDirectory(in rootDirectory: URL) -> URL {
        faviconDirectory(in: rootDirectory, encrypted: LocalJSONEncryption.isEnabled)
    }

    public static func faviconDirectory(in rootDirectory: URL, encrypted: Bool) -> URL {
        rootDirectory.appendingPathComponent("Favicons", isDirectory: true)
    }

    public static func faviconIndexURL(rootDirectory: URL, encrypted: Bool) -> URL {
        faviconIndexURL(directory: faviconDirectory(in: rootDirectory, encrypted: encrypted), encrypted: encrypted)
    }

    public static func faviconIconURL(rootDirectory: URL, key: String, encrypted: Bool) -> URL {
        faviconIconURL(directory: faviconDirectory(in: rootDirectory, encrypted: encrypted), key: key, encrypted: encrypted)
    }

    public static func faviconIndexURL(directory: URL, encrypted: Bool) -> URL {
        encrypted
            ? directory.appendingPathComponent("\(obscuredName(for: "favicons/index.json")).bin")
            : directory.appendingPathComponent("index.json")
    }

    public static func faviconIconURL(directory: URL, key: String, encrypted: Bool) -> URL {
        encrypted
            ? directory.appendingPathComponent("\(obscuredName(for: "favicons/\(key).png")).bin")
            : directory.appendingPathComponent("\(key).png")
    }

    public static func plaintextFileURL(rootDirectory: URL, logicalName: String) -> URL {
        rootDirectory.appendingPathComponent(logicalName)
    }

    public static func privateFileURL(rootDirectory: URL, logicalName: String) -> URL {
        rootDirectory.appendingPathComponent("\(obscuredName(for: logicalName)).bin")
    }

    public static func fileURL(rootDirectory: URL, logicalName: String, encrypted: Bool) -> URL {
        encrypted
            ? privateFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
            : plaintextFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
    }

    public static func activeFileURL(rootDirectory: URL, logicalName: String) -> URL {
        LocalJSONEncryption.isEnabled
            ? privateFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
            : plaintextFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
    }

    public static func inactiveFileURL(rootDirectory: URL, logicalName: String) -> URL {
        fileURL(
            rootDirectory: rootDirectory,
            logicalName: logicalName,
            encrypted: !LocalJSONEncryption.isEnabled
        )
    }

    public static func inactiveFileURLs(rootDirectory: URL, logicalName: String) -> [URL] {
        let activeURL = activeFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
        return [
            privateFileURL(rootDirectory: rootDirectory, logicalName: logicalName),
            plaintextFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
        ]
            .filter { $0.standardizedFileURL != activeURL.standardizedFileURL }
    }

    public static func existingReadableFileURL(rootDirectory: URL, logicalName: String) -> URL {
        let activeURL = activeFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
        let candidates = [activeURL] + inactiveFileURLs(rootDirectory: rootDirectory, logicalName: logicalName)
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? activeURL
    }

    public static func markVaultDirectoryAsPackageIfNeeded(_ rootDirectory: URL) {
        guard rootDirectory.lastPathComponent == vaultDirectoryName,
              FileManager.default.fileExists(atPath: rootDirectory.path)
        else {
            return
        }
        var packageURL = rootDirectory
        var values = URLResourceValues()
        values.isPackage = true
        try? packageURL.setResourceValues(values)
    }

    public static func obscuredName(for logicalName: String) -> String {
        let material = "com.eli.Obelisk.private-storage.v1:\(logicalName)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func hasEncryptedPayloads(in rootDirectory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return enumerator.contains(where: { ($0 as? URL)?.pathExtension == "bin" })
    }

    public static func sampleEncryptedPayloadURL(in rootDirectory: URL) -> URL? {
        let bookmarksURL = privateFileURL(rootDirectory: rootDirectory, logicalName: "bookmarks.json")
        if FileManager.default.fileExists(atPath: bookmarksURL.path) {
            return bookmarksURL
        }
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let bins = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "bin" }
        return bins.max(by: { lhs, rhs in
            let lhsSize = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let rhsSize = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return lhsSize < rhsSize
        })
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

public enum ObeliskStorageMigrator {
    private struct FaviconRecord: Codable {
        var fetchedAt: Date
        var success: Bool
    }

    private struct FaviconLocation {
        var directory: URL
        var encrypted: Bool
    }

    public static let logicalJSONFiles = [
        "llm.json",
        "bookmarks.json",
        "bookmark_state.json",
        "usage.json",
        "bookmark_groups.json"
    ]

    public static func validateEncryptedPayloadsAreReadable(
        in rootDirectory: URL,
        keyStore: KeychainEncryptionKeyStore = KeychainEncryptionKeyStore()
    ) throws {
        guard ObeliskPrivateStorage.hasEncryptedPayloads(in: rootDirectory) else {
            return
        }
        guard let sampleURL = ObeliskPrivateStorage.sampleEncryptedPayloadURL(in: rootDirectory) else {
            throw SecureJSONFileCodecError.encryptionKeyMissing
        }
        _ = try SecureJSONFileCodec(keyStore: keyStore).readData(from: sampleURL)
    }

    public static func normalizeStorage(
        in rootDirectory: URL,
        encrypted: Bool,
        keyStore: KeychainEncryptionKeyStore = KeychainEncryptionKeyStore()
    ) throws {
        let vaultStore = ObeliskVaultStore(rootDirectory: rootDirectory)
        if vaultStore.hasV2Payload {
            _ = try vaultStore.loadPayload()
            try vaultStore.removeLegacyPayloadFiles()
            try normalizeFavicons(in: rootDirectory, encrypted: encrypted, keyStore: keyStore)
            removeEmptyStorageDirectories(in: rootDirectory)
            return
        }

        try validateEncryptedPayloadsAreReadable(in: rootDirectory, keyStore: keyStore)
        try normalizeJSONFiles(in: rootDirectory, encrypted: encrypted, keyStore: keyStore)
        try normalizeFavicons(in: rootDirectory, encrypted: encrypted, keyStore: keyStore)
        removeEmptyStorageDirectories(in: rootDirectory)
    }

    public static func normalizeJSONFiles(
        in rootDirectory: URL,
        encrypted: Bool,
        logicalNames: [String] = logicalJSONFiles,
        keyStore: KeychainEncryptionKeyStore = KeychainEncryptionKeyStore()
    ) throws {
        try validateEncryptedPayloadsAreReadable(in: rootDirectory, keyStore: keyStore)
        defer { removeEmptyStorageDirectories(in: rootDirectory) }

        let codec = SecureJSONFileCodec(keyStore: keyStore)
        let fileManager = FileManager.default

        for logicalName in logicalNames {
            let targetURL = ObeliskPrivateStorage.fileURL(
                rootDirectory: rootDirectory,
                logicalName: logicalName,
                encrypted: encrypted
            )
            let candidateURLs = [
                targetURL,
                ObeliskPrivateStorage.fileURL(
                    rootDirectory: rootDirectory,
                    logicalName: logicalName,
                    encrypted: !encrypted
                )
            ]

            let existingCandidates = candidateURLs
                .filter { fileManager.fileExists(atPath: $0.path) }
                .sorted { lhs, rhs in
                    modificationDate(for: lhs) > modificationDate(for: rhs)
                }
            guard !existingCandidates.isEmpty else {
                continue
            }

            let plaintext = try readBestAvailableData(
                logicalName: logicalName,
                from: existingCandidates,
                codec: codec
            )
            try fileManager.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try codec.writeData(
                plaintext,
                to: targetURL,
                encrypted: encrypted
            )
            let verifiedPlaintext = try codec.readData(from: targetURL)
            guard verifiedPlaintext == plaintext else {
                throw SecureJSONFileCodecError.invalidEnvelope
            }

            for staleURL in candidateURLs where staleURL.standardizedFileURL != targetURL.standardizedFileURL {
                try? LocalFileAccess.removeItem(at: staleURL)
            }
        }
    }

    public static func normalizeFavicons(
        in rootDirectory: URL,
        encrypted: Bool,
        keyStore: KeychainEncryptionKeyStore = KeychainEncryptionKeyStore()
    ) throws {
        try validateEncryptedPayloadsAreReadable(in: rootDirectory, keyStore: keyStore)
        defer { removeEmptyStorageDirectories(in: rootDirectory) }

        let targetLocation = FaviconLocation(
            directory: ObeliskPrivateStorage.faviconDirectory(in: rootDirectory, encrypted: encrypted),
            encrypted: encrypted
        )
        let sourceLocations = faviconLocations(in: rootDirectory)
            .filter { FileManager.default.fileExists(atPath: $0.directory.path) }

        var mergedIndex = loadFaviconIndex(in: targetLocation, rootDirectory: rootDirectory, keyStore: keyStore)
        for location in sourceLocations {
            let sourceIndex = loadFaviconIndex(in: location, rootDirectory: rootDirectory, keyStore: keyStore)
            for (key, record) in sourceIndex {
                if let existing = mergedIndex[key], existing.fetchedAt >= record.fetchedAt {
                    continue
                }
                mergedIndex[key] = record
            }
        }

        for (key, record) in mergedIndex where record.success {
            guard let data = newestReadableFaviconData(
                for: key,
                in: sourceLocations,
                rootDirectory: rootDirectory,
                keyStore: keyStore
            ) else {
                continue
            }
            let destinationURL = ObeliskPrivateStorage.faviconIconURL(
                directory: targetLocation.directory,
                key: key,
                encrypted: targetLocation.encrypted
            )
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writeFaviconData(
                data,
                to: destinationURL,
                encrypted: targetLocation.encrypted,
                rootDirectory: rootDirectory,
                keyStore: keyStore
            )
            let verifiedData = try readFaviconData(
                from: destinationURL,
                encrypted: targetLocation.encrypted,
                rootDirectory: rootDirectory,
                keyStore: keyStore
            )
            guard verifiedData == data else {
                throw SecureJSONFileCodecError.invalidEnvelope
            }
            let staleIconURL = ObeliskPrivateStorage.faviconIconURL(
                directory: targetLocation.directory,
                key: key,
                encrypted: !targetLocation.encrypted
            )
            try? LocalFileAccess.removeItem(at: staleIconURL)
        }

        if !mergedIndex.isEmpty || !sourceLocations.isEmpty {
            try saveFaviconIndex(mergedIndex, in: targetLocation, rootDirectory: rootDirectory, keyStore: keyStore)
            _ = try readFaviconData(
                from: ObeliskPrivateStorage.faviconIndexURL(
                    directory: targetLocation.directory,
                    encrypted: targetLocation.encrypted
                ),
                encrypted: targetLocation.encrypted,
                rootDirectory: rootDirectory,
                keyStore: keyStore
            )
            let staleIndexURL = ObeliskPrivateStorage.faviconIndexURL(
                directory: targetLocation.directory,
                encrypted: !targetLocation.encrypted
            )
            try? LocalFileAccess.removeItem(at: staleIndexURL)
        }

        for location in sourceLocations
            where location.directory.standardizedFileURL != targetLocation.directory.standardizedFileURL {
            try? LocalFileAccess.removeItem(at: location.directory)
        }
    }

    public static func removeEmptyStorageDirectories(in rootDirectory: URL) {
        removeIfEmpty(ObeliskPrivateStorage.faviconDirectory(in: rootDirectory, encrypted: false))
    }

    private static func removeIfEmpty(_ directory: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              ),
              contents.isEmpty
        else {
            return
        }
        try? LocalFileAccess.removeItem(at: directory)
    }

    private static func faviconLocations(in rootDirectory: URL) -> [FaviconLocation] {
        uniqueFaviconLocations([
            FaviconLocation(
                directory: ObeliskPrivateStorage.faviconDirectory(in: rootDirectory, encrypted: false),
                encrypted: false
            ),
            FaviconLocation(
                directory: ObeliskPrivateStorage.faviconDirectory(in: rootDirectory, encrypted: true),
                encrypted: true
            )
        ])
    }

    private static func uniqueFaviconLocations(_ locations: [FaviconLocation]) -> [FaviconLocation] {
        var seen = Set<String>()
        return locations.filter {
            seen.insert("\($0.directory.standardizedFileURL.path)|\($0.encrypted)").inserted
        }
    }

    private static func loadFaviconIndex(
        in location: FaviconLocation,
        rootDirectory: URL,
        keyStore: KeychainEncryptionKeyStore
    ) -> [String: FaviconRecord] {
        let indexURL = ObeliskPrivateStorage.faviconIndexURL(
            directory: location.directory,
            encrypted: location.encrypted
        )
        guard let data = try? readFaviconData(
            from: indexURL,
            encrypted: location.encrypted,
            rootDirectory: rootDirectory,
            keyStore: keyStore
        ) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: FaviconRecord].self, from: data)) ?? [:]
    }

    private static func saveFaviconIndex(
        _ index: [String: FaviconRecord],
        in location: FaviconLocation,
        rootDirectory: URL,
        keyStore: KeychainEncryptionKeyStore
    ) throws {
        try FileManager.default.createDirectory(
            at: location.directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(index)
        let indexURL = ObeliskPrivateStorage.faviconIndexURL(
            directory: location.directory,
            encrypted: location.encrypted
        )
        try writeFaviconData(
            data,
            to: indexURL,
            encrypted: location.encrypted,
            rootDirectory: rootDirectory,
            keyStore: keyStore
        )
    }

    private static func newestReadableFaviconData(
        for key: String,
        in locations: [FaviconLocation],
        rootDirectory: URL,
        keyStore: KeychainEncryptionKeyStore
    ) -> Data? {
        locations
            .map { location in
                (
                    location: location,
                    url: ObeliskPrivateStorage.faviconIconURL(
                        directory: location.directory,
                        key: key,
                        encrypted: location.encrypted
                    )
                )
            }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .sorted { lhs, rhs in
                modificationDate(for: lhs.url) > modificationDate(for: rhs.url)
            }
            .lazy
            .compactMap {
                try? readFaviconData(
                    from: $0.url,
                    encrypted: $0.location.encrypted,
                    rootDirectory: rootDirectory,
                    keyStore: keyStore
                )
            }
            .first
    }

    private static func readFaviconData(
        from url: URL,
        encrypted: Bool,
        rootDirectory: URL,
        keyStore: KeychainEncryptionKeyStore
    ) throws -> Data {
        if encrypted {
            return try SecureJSONFileCodec(keyStore: keyStore).readData(from: url)
        }
        return try LocalFileAccess.readData(from: url)
    }

    private static func writeFaviconData(
        _ data: Data,
        to url: URL,
        encrypted: Bool,
        rootDirectory: URL,
        keyStore: KeychainEncryptionKeyStore
    ) throws {
        if encrypted {
            try SecureJSONFileCodec(keyStore: keyStore).writeData(
                data,
                to: url,
                encrypted: true
            )
        } else {
            try LocalFileAccess.writeData(data, to: url)
        }
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func modificationDate(for url: URL) -> Date {
        (
            try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        ) ?? .distantPast
    }

    private static func readBestAvailableData(
        logicalName: String,
        from candidates: [URL],
        codec: SecureJSONFileCodec
    ) throws -> Data {
        if logicalName == "bookmarks.json",
           let nonEmptyBookmarks = try newestNonEmptyBookmarkData(
               from: candidates,
               codec: codec
           ) {
            return nonEmptyBookmarks
        }

        var lastError: Error?
        for candidate in candidates {
            do {
                return try codec.readData(from: candidate)
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func newestNonEmptyBookmarkData(
        from candidates: [URL],
        codec: SecureJSONFileCodec
    ) throws -> Data? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for candidate in candidates {
            do {
                let data = try codec.readData(from: candidate)
                let database = try decoder.decode(BookmarkDatabase.self, from: data)
                if !database.bookmarks.isEmpty {
                    return data
                }
            } catch {
                continue
            }
        }

        return nil
    }
}

public enum LocalFileAccess {
    public static func readData(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public static func writeData(_ data: Data, to url: URL, options: Data.WritingOptions = [.atomic]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try data.write(to: url, options: options)
    }

    public static func removeItem(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }
}

public enum SecureJSONFileCodecError: LocalizedError {
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case invalidEnvelope
    case decryptFailed
    case encryptionKeyMissing
    case encryptionKeyWouldOverwrite

    public var errorDescription: String? {
        switch self {
        case .keychainReadFailed:
            return "无法从钥匙串读取本地加密密钥"
        case .keychainWriteFailed:
            return "无法将本地加密密钥保存到钥匙串"
        case .invalidEnvelope:
            return "本地加密文件格式无效"
        case .decryptFailed:
            return "无法解密本地数据：钥匙串中的加密密钥与磁盘上的加密书签不匹配。若刚切换过签名/Team，旧密钥可能已丢失；请先保留 Obelisk.obelisk 和旧存储备份，再用明文备份恢复数据。"
        case .encryptionKeyMissing:
            return "找不到本地数据加密密钥，无法解密书签。若刚切换过签名/Team，请尝试用 Time Machine 恢复「登录」钥匙串后再打开 Obelisk。"
        case .encryptionKeyWouldOverwrite:
            return "拒绝写入新的加密主密钥：磁盘上已有加密数据，且新密钥无法解密现有文件。不会覆盖钥匙串中的现有密钥。"
        }
    }
}

public final class SecureJSONFileCodec {
    private struct Envelope: Codable {
        let format: String
        let algorithm: String
        let payload: String
    }

    private let format = "obelisk.encrypted-json.v1"
    private let algorithm = "AES.GCM"
    private let keyStore: KeychainEncryptionKeyStore
    private let envelopeEncoder = JSONEncoder()
    private let envelopeDecoder = JSONDecoder()

    public init(keyStore: KeychainEncryptionKeyStore = KeychainEncryptionKeyStore()) {
        self.keyStore = keyStore
        envelopeEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func readData(from url: URL) throws -> Data {
        let data = try LocalFileAccess.readData(from: url)
        return try decryptIfNeeded(data)
    }

    public func writeData(_ data: Data, to url: URL, options: Data.WritingOptions = [.atomic]) throws {
        let output = try LocalJSONEncryption.isEnabled ? encrypt(data) : data
        try LocalFileAccess.writeData(output, to: url, options: options)
    }

    public func writeData(
        _ data: Data,
        to url: URL,
        encrypted: Bool,
        options: Data.WritingOptions = [.atomic]
    ) throws {
        let output = try encrypted ? encrypt(data) : data
        try LocalFileAccess.writeData(output, to: url, options: options)
    }

    public func isEncryptedFile(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return isEncryptedData(data)
    }

    public func rewriteFile(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let plaintext = try readData(from: url)
        try writeData(plaintext, to: url)
    }

    private func encrypt(_ plaintext: Data) throws -> Data {
        let key = try keyStore.getOrCreateKey()
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            throw SecureJSONFileCodecError.invalidEnvelope
        }
        let envelope = Envelope(
            format: format,
            algorithm: algorithm,
            payload: combined.base64EncodedString()
        )
        return try envelopeEncoder.encode(envelope)
    }

    private func decryptIfNeeded(_ data: Data) throws -> Data {
        guard isEncryptedData(data) else { return data }
        let envelope = try envelopeDecoder.decode(Envelope.self, from: data)
        guard envelope.format == format, envelope.algorithm == algorithm else {
            throw SecureJSONFileCodecError.invalidEnvelope
        }
        guard let combined = Data(base64Encoded: envelope.payload) else {
            throw SecureJSONFileCodecError.invalidEnvelope
        }
        let key = try keyStore.resolveSymmetricKey(validatingAgainst: data)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw SecureJSONFileCodecError.decryptFailed
        }
    }

    private func isEncryptedData(_ data: Data) -> Bool {
        guard let envelope = try? envelopeDecoder.decode(Envelope.self, from: data) else {
            return false
        }
        return envelope.format == format && envelope.algorithm == algorithm
    }

    fileprivate func canDecrypt(_ encryptedData: Data, using keyData: Data) -> Bool {
        guard isEncryptedData(encryptedData), keyData.count == 32 else { return false }
        guard let envelope = try? envelopeDecoder.decode(Envelope.self, from: encryptedData),
              envelope.format == format,
              envelope.algorithm == algorithm,
              let combined = Data(base64Encoded: envelope.payload) else {
            return false
        }
        let key = SymmetricKey(data: keyData)
        guard let sealedBox = try? AES.GCM.SealedBox(combined: combined) else { return false }
        return (try? AES.GCM.open(sealedBox, using: key)) != nil
    }
}

public enum ObeliskKeychainMigration {
    private static let apiKeyService = "com.eli.Obelisk.llm-apikey"
    private static let legacyAPIKeyAccounts = ["default", "local", "profiles"]

    /// Moves LLM API keys into the signed app's access group. Never touches the encryption master key.
    public static func migrateIfNeeded() {
        guard ObeliskKeychain.accessGroup != nil else { return }

        if readItem(service: apiKeyService, account: "remote", includeAccessGroup: true) == nil,
           let legacyDefault = readItem(service: apiKeyService, account: "default", includeAccessGroup: false) {
            if writeItem(legacyDefault, service: apiKeyService, account: "remote") {
                deleteLegacyAPIKeyItem(account: "default")
            }
        }
        migrateItem(service: apiKeyService, account: "remote")

        for legacyAccount in legacyAPIKeyAccounts {
            deleteLegacyAPIKeyItem(account: legacyAccount)
        }
    }

    private static func migrateItem(service: String, account: String) {
        assertMigrationServiceAllowed(service)
        guard let legacyData = readItem(service: service, account: account, includeAccessGroup: false) else {
            return
        }
        guard writeItem(legacyData, service: service, account: account) else {
            return
        }
        guard let migrated = readItem(service: service, account: account, includeAccessGroup: true),
              migrated == legacyData else {
            return
        }
        deleteLegacyAPIKeyItem(account: account)
    }

    private static func assertMigrationServiceAllowed(_ service: String) {
        precondition(
            !service.localizedCaseInsensitiveContains("encryption"),
            "ObeliskKeychainMigration must never touch encryption keys"
        )
        precondition(
            service == apiKeyService,
            "ObeliskKeychainMigration only supports LLM API key service"
        )
    }

    private static func readItem(service: String, account: String, includeAccessGroup: Bool) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if includeAccessGroup {
            ObeliskKeychain.applyAccessGroup(to: &query)
        }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    @discardableResult
    private static func writeItem(_ data: Data, service: String, account: String) -> Bool {
        assertMigrationServiceAllowed(service)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        ObeliskKeychain.applyAccessGroup(to: &query)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
        }
        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteLegacyAPIKeyItem(account: String) {
        guard legacyAPIKeyAccounts.contains(account) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiKeyService,
            kSecAttrAccount as String: account
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}

private enum ObeliskKeychain {
    static var accessGroup: String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        guard let groups = SecTaskCopyValueForEntitlement(
            task,
            "keychain-access-groups" as CFString,
            nil
        ) as? [String] else {
            return nil
        }
        return groups.first { !$0.isEmpty }
    }

    static func applyAccessGroup(to query: inout [String: Any]) {
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
    }
}

public final class KeychainEncryptionKeyStore {
    private static let keyLog = Logger(subsystem: "com.eli.Obelisk", category: "EncryptionKeychain")
    private static let defaultService = "com.eli.Obelisk.encryption"

    private let service: String
    private let account = "default-v1"
    private let encryptedPayloadsRoot: URL?

    public init(encryptedPayloadsRoot: URL? = nil, keychainService: String? = nil) {
        self.encryptedPayloadsRoot = encryptedPayloadsRoot
        self.service = keychainService ?? Self.defaultService
    }

    /// Persists encryption key bytes. Refuses to overwrite a different existing key when encrypted payloads exist on disk.
    public func persistEncryptionKeyMaterial(_ data: Data) throws {
        try saveKeyData(data, preferLegacySlot: false)
    }

    public func getExistingKey() throws -> SymmetricKey {
        guard let data = try readKeyData() else {
            throw SecureJSONFileCodecError.encryptionKeyMissing
        }
        return SymmetricKey(data: data)
    }

    /// Picks a keychain key that decrypts the given ciphertext; scans all matching items before failing.
    public func resolveSymmetricKey(validatingAgainst encryptedData: Data) throws -> SymmetricKey {
        let codec = SecureJSONFileCodec(keyStore: self)
        if let current = try? readKeyData(), codec.canDecrypt(encryptedData, using: current) {
            return SymmetricKey(data: current)
        }
        for candidate in allKeychainKeyCandidates() where candidate.count == 32 {
            guard codec.canDecrypt(encryptedData, using: candidate) else { continue }
            if let current = try? readKeyData(), current != candidate {
                Self.keyLog.fault("Using alternate keychain encryption key that decrypts local data")
            }
            try? saveKeyData(candidate, preferLegacySlot: true)
            return SymmetricKey(data: candidate)
        }
        if (try? readKeyData()) != nil {
            throw SecureJSONFileCodecError.decryptFailed
        }
        throw SecureJSONFileCodecError.encryptionKeyMissing
    }

    public func getOrCreateKey() throws -> SymmetricKey {
        if let data = try readKeyData() {
            try? migrateKeyToAccessGroupIfNeeded(data)
            return SymmetricKey(data: data)
        }
        if let root = encryptedPayloadsRootDirectory(),
           ObeliskPrivateStorage.hasEncryptedPayloads(in: root) {
            throw SecureJSONFileCodecError.encryptionKeyMissing
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try saveKeyData(data, preferLegacySlot: false)
        return key
    }

    /// Tries every accessible encryption-key item in Keychain against on-disk ciphertext.
    public func recoverEncryptionKeyIfNeeded(rootDirectory: URL) -> Bool {
        guard ObeliskPrivateStorage.hasEncryptedPayloads(in: rootDirectory) else { return false }
        guard let sampleURL = ObeliskPrivateStorage.sampleEncryptedPayloadURL(in: rootDirectory),
              let sampleData = try? Data(contentsOf: sampleURL) else {
            return false
        }
        let codec = SecureJSONFileCodec()

        if let current = try? readKeyData(), codec.canDecrypt(sampleData, using: current) {
            return false
        }

        for candidate in allKeychainKeyCandidates() where candidate.count == 32 {
            guard codec.canDecrypt(sampleData, using: candidate) else { continue }
            do {
                if let current = try? readKeyData(), current != candidate {
                    Self.keyLog.fault(
                        "Replacing unreadable encryption key with recovered candidate from keychain scan"
                    )
                }
                try saveKeyData(candidate, preferLegacySlot: true)
                return true
            } catch {
                continue
            }
        }
        return false
    }

    private func encryptedPayloadsRootDirectory() -> URL? {
        encryptedPayloadsRoot ?? Self.defaultRecoveryRootDirectory()
    }

    private static func defaultRecoveryRootDirectory() -> URL? {
        if let override = ProcessInfo.processInfo.environment["UNIBOOKMARK_HOME"],
           !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return BookmarkStore.defaultRootDirectory()
    }

    private func allKeychainKeyCandidates() -> [Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess, let array = items as? [[String: Any]] else {
            return []
        }
        return array.compactMap { $0[kSecValueData as String] as? Data }
    }

    /// Prefer the ad-hoc era item first; a wrongly created access-group item must not shadow it.
    private func readKeyData() throws -> Data? {
        if let data = try readKeyData(includeAccessGroup: false) {
            return data
        }
        return try readKeyData(includeAccessGroup: true)
    }

    private func migrateKeyToAccessGroupIfNeeded(_ data: Data) throws {
        guard ObeliskKeychain.accessGroup != nil else { return }
        if let grouped = try readKeyData(includeAccessGroup: true), grouped == data {
            return
        }
        try saveKeyData(data, preferLegacySlot: false)
    }

    private func readKeyData(includeAccessGroup: Bool) throws -> Data? {
        var query = baseQuery(includeAccessGroup: includeAccessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SecureJSONFileCodecError.keychainReadFailed(status)
        }
        return data
    }

    private func saveKeyData(_ data: Data, preferLegacySlot: Bool) throws {
        guard data.count == 32 else {
            throw SecureJSONFileCodecError.invalidEnvelope
        }

        if let existing = try readKeyData() {
            if existing == data {
                return
            }
            try assertMayReplaceEncryptionKey(with: data)
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let useLegacySlot = preferLegacySlot || ObeliskKeychain.accessGroup == nil
        let query = baseQuery(includeAccessGroup: !useLegacySlot)
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else {
                throw SecureJSONFileCodecError.keychainWriteFailed(status)
            }
            return
        }

        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureJSONFileCodecError.keychainWriteFailed(status)
        }
    }

    private func assertMayReplaceEncryptionKey(with newData: Data) throws {
        guard let root = encryptedPayloadsRootDirectory(),
              ObeliskPrivateStorage.hasEncryptedPayloads(in: root),
              let sampleURL = ObeliskPrivateStorage.sampleEncryptedPayloadURL(in: root),
              let sampleData = try? Data(contentsOf: sampleURL) else {
            return
        }
        let codec = SecureJSONFileCodec(keyStore: self)
        guard codec.canDecrypt(sampleData, using: newData) else {
            throw SecureJSONFileCodecError.encryptionKeyWouldOverwrite
        }
    }

    private func baseQuery(includeAccessGroup: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if includeAccessGroup {
            ObeliskKeychain.applyAccessGroup(to: &query)
        }
        return query
    }
}

public final class KeychainAPIKeyStore {
    private let service = "com.eli.Obelisk.llm-apikey"
    private let account: String

    public init(account: String = "default") {
        self.account = account
    }

    public func readAPIKey() throws -> String? {
        if let value = try readAPIKey(includeAccessGroup: true) {
            return value
        }
        return try readAPIKey(includeAccessGroup: false)
    }

    private func readAPIKey(includeAccessGroup: Bool) throws -> String? {
        var query = baseQuery(includeAccessGroup: includeAccessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SecureJSONFileCodecError.keychainReadFailed(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try deleteAPIKey()
            return
        }

        var query = baseQuery()
        let update: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else {
                throw SecureJSONFileCodecError.keychainWriteFailed(status)
            }
        } else {
            query.merge(update) { _, new in new }
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw SecureJSONFileCodecError.keychainWriteFailed(status)
            }
        }
    }

    public func deleteAPIKey() throws {
        let query = baseQuery()
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureJSONFileCodecError.keychainWriteFailed(status)
        }
    }

    public func hasAPIKey() -> Bool {
        (try? readAPIKey())?.isEmpty == false
    }

    private func baseQuery(includeAccessGroup: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if includeAccessGroup {
            ObeliskKeychain.applyAccessGroup(to: &query)
        }
        return query
    }
}
