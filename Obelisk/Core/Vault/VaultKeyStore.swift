import CryptoKit
import Foundation
import LocalAuthentication
import os
import Security

public enum VaultKeyStoreError: LocalizedError {
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case encryptionKeyMissing
    case encryptionKeyWouldOverwrite
    case accessControlUnavailable

    public var errorDescription: String? {
        switch self {
        case .keychainReadFailed:
            return "无法从钥匙串读取 Vault 加密密钥"
        case .keychainWriteFailed:
            return "无法将 Vault 加密密钥保存到钥匙串"
        case .encryptionKeyMissing:
            return "找不到 Vault 加密密钥，无法解密本地数据"
        case .encryptionKeyWouldOverwrite:
            return "拒绝写入新的 Vault 主密钥：磁盘上已有加密数据，且新密钥无法解密现有文件"
        case .accessControlUnavailable:
            return "无法创建 Vault 密钥访问控制"
        }
    }
}

public final class VaultKeyStore {
    private static let keyLog = Logger(subsystem: "com.eli.Obelisk", category: "VaultKeychain")
    private static let service = "com.eli.Obelisk.vault-v2"
    private static let account = "master-v2"

    private let encryptedPayloadsRoot: URL?
    private let blobCodec = VaultBlobCodec()

    public init(encryptedPayloadsRoot: URL? = nil) {
        self.encryptedPayloadsRoot = encryptedPayloadsRoot
    }

    public func symmetricKey(authenticationContext: LAContext?) throws -> SymmetricKey {
        let data = try keyData(authenticationContext: authenticationContext)
        return SymmetricKey(data: data)
    }

    public func getOrCreateKey(authenticationContext: LAContext?) throws -> SymmetricKey {
        if let data = try readKeyData(authenticationContext: authenticationContext) {
            return SymmetricKey(data: data)
        }
        if let root = encryptedPayloadsRootDirectory(),
           VaultPaths.isVaultV2Present(in: root) || ObeliskPrivateStorage.hasEncryptedPayloads(in: root) {
            throw VaultKeyStoreError.encryptionKeyMissing
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try saveKeyData(data, authenticationContext: authenticationContext)
        return key
    }

    public func persistKeyMaterial(_ data: Data, authenticationContext: LAContext?) throws {
        try saveKeyData(data, authenticationContext: authenticationContext)
    }

    public func canDecryptManifest(at url: URL, keyData: Data, authenticationContext: LAContext?) -> Bool {
        guard let encrypted = try? Data(contentsOf: url),
              let manifestBlobId = manifestBlobIdFromStoredEnvelope(encrypted) else {
            return false
        }
        return blobCodec.canOpen(
            encrypted,
            logicalName: VaultPaths.manifestLogicalName,
            blobId: manifestBlobId,
            using: keyData
        )
    }

    private func manifestBlobIdFromStoredEnvelope(_ data: Data) -> UUID? {
        struct Envelope: Codable { let blobId: String }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let id = UUID(uuidString: envelope.blobId) else {
            return nil
        }
        return id
    }

    private func keyData(authenticationContext: LAContext?) throws -> Data {
        if let data = try readKeyData(authenticationContext: authenticationContext) {
            return data
        }
        throw VaultKeyStoreError.encryptionKeyMissing
    }

    private func readKeyData(authenticationContext: LAContext?) throws -> Data? {
        if let data = try readKeyData(includeAccessGroup: false, authenticationContext: authenticationContext) {
            return data
        }
        return try readKeyData(includeAccessGroup: true, authenticationContext: authenticationContext)
    }

    private func readKeyData(includeAccessGroup: Bool, authenticationContext: LAContext?) throws -> Data? {
        var query = baseQuery(includeAccessGroup: includeAccessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let authenticationContext {
            query[kSecUseAuthenticationContext as String] = authenticationContext
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw VaultKeyStoreError.keychainReadFailed(status)
        }
        return data
    }

    private func saveKeyData(_ data: Data, authenticationContext: LAContext?) throws {
        guard data.count == 32 else {
            throw VaultKeyStoreError.encryptionKeyWouldOverwrite
        }

        if let existing = try readKeyData(authenticationContext: authenticationContext), existing != data {
            try assertMayReplaceKey(with: data, authenticationContext: authenticationContext)
        } else if let existing = try readKeyData(authenticationContext: authenticationContext), existing == data {
            return
        }

        let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            accessibility,
            .userPresence,
            &accessError
        ) else {
            throw VaultKeyStoreError.accessControlUnavailable
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
            kSecAttrAccessControl as String: accessControl
        ]

        var query = baseQuery(includeAccessGroup: ObeliskKeychain.accessGroup != nil)
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else {
                throw VaultKeyStoreError.keychainWriteFailed(status)
            }
            return
        }

        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VaultKeyStoreError.keychainWriteFailed(status)
        }
    }

    private func assertMayReplaceKey(with newData: Data, authenticationContext: LAContext?) throws {
        guard let root = encryptedPayloadsRootDirectory(),
              VaultPaths.isVaultV2Present(in: root),
              let manifestURL = Optional(VaultPaths.manifestURL(in: root)),
              FileManager.default.fileExists(atPath: manifestURL.path) else {
            return
        }
        guard canDecryptManifest(at: manifestURL, keyData: newData, authenticationContext: authenticationContext) else {
            throw VaultKeyStoreError.encryptionKeyWouldOverwrite
        }
    }

    private func encryptedPayloadsRootDirectory() -> URL? {
        encryptedPayloadsRoot ?? Self.defaultRecoveryRootDirectory()
    }

    private static func defaultRecoveryRootDirectory() -> URL? {
        if let override = ProcessInfo.processInfo.environment["UNIBOOKMARK_HOME"],
           !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("Obelisk")
    }

    private func baseQuery(includeAccessGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        if includeAccessGroup {
            ObeliskKeychain.applyAccessGroup(to: &query)
        }
        return query
    }
}
