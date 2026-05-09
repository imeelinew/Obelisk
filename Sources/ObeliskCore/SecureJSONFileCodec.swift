import CryptoKit
import Foundation
import Security

public enum LocalJSONEncryption {
    public static let enabledKey = "encryptLocalJSONData"

    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

public enum ICloudDocumentSyncError: LocalizedError {
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "iCloud Drive 不可用。请确认已登录 Apple 账户并开启 iCloud Drive。"
        }
    }
}

public enum ICloudDocumentSync {
    public static let enabledKey = "syncWithICloudDrive"
    public static let cachedRootPathKey = "iCloudDocumentSyncRootPath"
    public static let containerIdentifier = "iCloud.local.elidev.Obelisk"

    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    public static func cachedRootDirectory() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: cachedRootPathKey), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func setCachedRootDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: cachedRootPathKey)
    }

    public static func resolveRootDirectory() async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let rootURL: URL
            if let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
                rootURL = containerURL
                    .appendingPathComponent("Documents", isDirectory: true)
                    .appendingPathComponent("Obelisk", isDirectory: true)
            } else if let cloudDocumentsURL = cloudDocumentsFallbackURL() {
                rootURL = cloudDocumentsURL.appendingPathComponent("Obelisk", isDirectory: true)
            } else {
                throw ICloudDocumentSyncError.unavailable
            }

            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            return rootURL
        }.value
    }

    private static func cloudDocumentsFallbackURL() -> URL? {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }
}

public enum ObeliskPrivateStorage {
    public static let directoryName = "PrivateData"

    public static func dataDirectory(in rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func faviconDirectory(in rootDirectory: URL) -> URL {
        dataDirectory(in: rootDirectory).appendingPathComponent("Favicons", isDirectory: true)
    }

    public static func legacyFileURL(rootDirectory: URL, logicalName: String) -> URL {
        rootDirectory.appendingPathComponent(logicalName)
    }

    public static func privateFileURL(rootDirectory: URL, logicalName: String) -> URL {
        dataDirectory(in: rootDirectory).appendingPathComponent("\(obscuredName(for: logicalName)).bin")
    }

    public static func activeFileURL(rootDirectory: URL, logicalName: String) -> URL {
        LocalJSONEncryption.isEnabled
            ? privateFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
            : legacyFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
    }

    public static func existingReadableFileURL(rootDirectory: URL, logicalName: String) -> URL {
        let activeURL = activeFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
        if FileManager.default.fileExists(atPath: activeURL.path) {
            return activeURL
        }

        let fallbackURL = LocalJSONEncryption.isEnabled
            ? legacyFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
            : privateFileURL(rootDirectory: rootDirectory, logicalName: logicalName)

        return FileManager.default.fileExists(atPath: fallbackURL.path) ? fallbackURL : activeURL
    }

    public static func obscuredName(for logicalName: String) -> String {
        let material = "local.elidev.Obelisk.private-storage.v1:\(logicalName)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum CoordinatedFileAccess {
    public static func readData(from url: URL) throws -> Data {
        guard ICloudDocumentSync.isEnabled else {
            return try Data(contentsOf: url)
        }

        var result: Result<Data, Error>?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordinatedURL in
            result = Result {
                try Data(contentsOf: coordinatedURL)
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        return try result?.get() ?? Data(contentsOf: url)
    }

    public static func writeData(_ data: Data, to url: URL, options: Data.WritingOptions = [.atomic]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard ICloudDocumentSync.isEnabled else {
            try data.write(to: url, options: options)
            return
        }

        var writeError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinatorError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: options)
            } catch {
                writeError = error
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        if let writeError {
            throw writeError
        }
    }
}

public enum SecureJSONFileCodecError: LocalizedError {
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case invalidEnvelope
    case decryptFailed

    public var errorDescription: String? {
        switch self {
        case .keychainReadFailed:
            return "无法从钥匙串读取本地加密密钥"
        case .keychainWriteFailed:
            return "无法将本地加密密钥保存到钥匙串"
        case .invalidEnvelope:
            return "本地加密文件格式无效"
        case .decryptFailed:
            return "无法解密本地数据"
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
        let data = try CoordinatedFileAccess.readData(from: url)
        return try decryptIfNeeded(data)
    }

    public func writeData(_ data: Data, to url: URL, options: Data.WritingOptions = [.atomic]) throws {
        let output = try LocalJSONEncryption.isEnabled ? encrypt(data) : data
        try CoordinatedFileAccess.writeData(output, to: url, options: options)
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
        let key = try keyStore.getOrCreateKey()
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
}

public final class KeychainEncryptionKeyStore {
    private let service = "local.elidev.Obelisk.encryption"
    private let account = "default-v1"

    public init() {}

    public func getOrCreateKey() throws -> SymmetricKey {
        if let data = try readKeyData() {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try saveKeyData(data)
        return key
    }

    private func readKeyData() throws -> Data? {
        var query = baseQuery()
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

    private func saveKeyData(_ data: Data) throws {
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureJSONFileCodecError.keychainWriteFailed(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
