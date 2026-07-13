import CryptoKit
import Foundation
import Security

enum ObeliskStorageError: LocalizedError {
    case databaseOpenFailed(String)
    case databaseOperationFailed(String)
    case databaseCorrupt
    case encryptionKeyMissing
    case encryptionKeyInvalid
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case invalidCiphertext
    case recoveryKeyInvalid
    case recoveryKeyDestinationExists(URL)

    var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let message):
            return "无法打开 Obelisk 数据库：\(message)"
        case .databaseOperationFailed(let message):
            return "Obelisk 数据库操作失败：\(message)"
        case .databaseCorrupt:
            return "Obelisk 数据库已损坏或包含无法识别的数据"
        case .encryptionKeyMissing:
            return "找不到 Obelisk 数据密钥。请使用恢复密钥恢复，应用不会创建新密钥覆盖现有数据。"
        case .encryptionKeyInvalid:
            return "Obelisk 数据密钥无效"
        case .keychainReadFailed(let status):
            return "无法从 macOS Data Protection Keychain 读取 Obelisk 数据密钥（\(status)：\(Self.securityMessage(status))）"
        case .keychainWriteFailed(let status):
            return "无法将 Obelisk 数据密钥写入 macOS Data Protection Keychain（\(status)：\(Self.securityMessage(status))）"
        case .invalidCiphertext:
            return "Obelisk 加密记录无效或已被篡改"
        case .recoveryKeyInvalid:
            return "Obelisk 恢复密钥无效"
        case .recoveryKeyDestinationExists(let url):
            return "恢复密钥文件已存在：\(url.path)"
        }
    }

    private static func securityMessage(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown Security error"
    }
}

protocol VaultKeyMaterialStore: AnyObject {
    func existingKeyData() throws -> Data?
    func persistNewKeyData(_ data: Data) throws
    func restoreKeyData(_ data: Data) throws
}

final class KeychainVaultKeyStore: VaultKeyMaterialStore {
    static let service = "com.eli.Obelisk.vault.v3"
    static let account = "primary"

    private let service: String
    private let account: String

    init(service: String = KeychainVaultKeyStore.service, account: String = KeychainVaultKeyStore.account) {
        self.service = service
        self.account = account
    }

    func existingKeyData() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ObeliskStorageError.keychainReadFailed(status)
        }
        guard data.count == 32 else {
            throw ObeliskStorageError.encryptionKeyInvalid
        }
        return data
    }

    func persistNewKeyData(_ data: Data) throws {
        guard data.count == 32 else { throw ObeliskStorageError.encryptionKeyInvalid }
        if let existing = try existingKeyData() {
            guard existing == data else { throw ObeliskStorageError.encryptionKeyInvalid }
            return
        }

        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ObeliskStorageError.keychainWriteFailed(status)
        }
    }

    func restoreKeyData(_ data: Data) throws {
        guard data.count == 32 else { throw ObeliskStorageError.encryptionKeyInvalid }
        if try existingKeyData() == nil {
            try persistNewKeyData(data)
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            throw ObeliskStorageError.keychainWriteFailed(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

final class InMemoryVaultKeyStore: VaultKeyMaterialStore {
    private var data: Data?

    init(data: Data? = nil) {
        self.data = data
    }

    func existingKeyData() throws -> Data? { data }

    func persistNewKeyData(_ data: Data) throws {
        guard data.count == 32 else { throw ObeliskStorageError.encryptionKeyInvalid }
        if let current = self.data, current != data {
            throw ObeliskStorageError.encryptionKeyInvalid
        }
        self.data = data
    }

    func restoreKeyData(_ data: Data) throws {
        guard data.count == 32 else { throw ObeliskStorageError.encryptionKeyInvalid }
        self.data = data
    }

    func removeKeyForTesting() {
        data = nil
    }
}

struct ObeliskRecoveryKey: Equatable, Sendable {
    let data: Data

    init() {
        let key = SymmetricKey(size: .bits256)
        self.data = key.withUnsafeBytes { Data($0) }
    }

    init(encoded: String) throws {
        var base64 = encoded
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64), data.count == 32 else {
            throw ObeliskStorageError.recoveryKeyInvalid
        }
        self.data = data
    }

    var encoded: String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct VaultRecordCodec {
    private static let magic = Data("OBELISKV3\0".utf8)

    func seal(_ plaintext: Data, keyData: Data, authenticatedData: Data) throws -> Data {
        guard keyData.count == 32 else { throw ObeliskStorageError.encryptionKeyInvalid }
        let box = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyData),
            authenticating: authenticatedData
        )
        guard let combined = box.combined else { throw ObeliskStorageError.invalidCiphertext }
        return Self.magic + combined
    }

    func open(_ encrypted: Data, keyData: Data, authenticatedData: Data) throws -> Data {
        guard keyData.count == 32 else { throw ObeliskStorageError.encryptionKeyInvalid }
        guard encrypted.starts(with: Self.magic) else { throw ObeliskStorageError.invalidCiphertext }
        let combined = encrypted.dropFirst(Self.magic.count)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(
                box,
                using: SymmetricKey(data: keyData),
                authenticating: authenticatedData
            )
        } catch {
            throw ObeliskStorageError.invalidCiphertext
        }
    }

    func wrapKey(_ keyData: Data, recoveryKey: ObeliskRecoveryKey, vaultID: UUID) throws -> Data {
        try seal(
            keyData,
            keyData: recoveryKey.data,
            authenticatedData: Data("obelisk.recovery.v1|\(vaultID.uuidString.lowercased())".utf8)
        )
    }

    func unwrapKey(_ wrapped: Data, recoveryKey: ObeliskRecoveryKey, vaultID: UUID) throws -> Data {
        let result = try open(
            wrapped,
            keyData: recoveryKey.data,
            authenticatedData: Data("obelisk.recovery.v1|\(vaultID.uuidString.lowercased())".utf8)
        )
        guard result.count == 32 else { throw ObeliskStorageError.recoveryKeyInvalid }
        return result
    }
}

enum RecoveryKeyDocument {
    private struct Document: Codable {
        let format: String
        let vaultID: UUID
        let createdAt: Date
        let recoveryKey: String
    }

    static func defaultURL(fileManager: FileManager = .default) -> URL {
        if let override = ProcessInfo.processInfo.environment["OBELISK_RECOVERY_KEY_OUTPUT"], !override.isEmpty {
            let preferred = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
            if !fileManager.fileExists(atPath: preferred.path) { return preferred }
            return preferred.deletingPathExtension()
                .appendingPathExtension(UUID().uuidString)
                .appendingPathExtension(preferred.pathExtension)
        }
        let preferred = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Obelisk Recovery Key.txt")
        if !fileManager.fileExists(atPath: preferred.path) { return preferred }
        return preferred.deletingPathExtension()
            .appendingPathExtension(UUID().uuidString)
            .appendingPathExtension(preferred.pathExtension)
    }

    static func persist(_ recoveryKey: ObeliskRecoveryKey, vaultID: UUID, to destination: URL) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ObeliskStorageError.recoveryKeyDestinationExists(destination)
        }
        let document = Document(
            format: "obelisk.recovery-key.v1",
            vaultID: vaultID,
            createdAt: Date(),
            recoveryKey: recoveryKey.encoded
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: destination, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    static func read(from source: URL) throws -> String {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(Document.self, from: Data(contentsOf: source))
            guard document.format == "obelisk.recovery-key.v1" else {
                throw ObeliskStorageError.recoveryKeyInvalid
            }
            _ = try ObeliskRecoveryKey(encoded: document.recoveryKey)
            return document.recoveryKey
        } catch let error as ObeliskStorageError {
            throw error
        } catch {
            throw ObeliskStorageError.recoveryKeyInvalid
        }
    }
}
