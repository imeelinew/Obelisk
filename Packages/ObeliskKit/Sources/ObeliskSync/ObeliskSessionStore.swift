import Foundation
import Security

public protocol SyncAccessKeyStoring: Sendable {
    func load() throws -> String?
    func save(_ key: String) throws
    func clear() throws
}

/// Keychain storage for the single sync access key. The key is generated
/// once when the Worker is deployed and pasted into every device.
public struct SyncAccessKeyStore: SyncAccessKeyStoring {
    public static let service = "com.eli.Obelisk.sync.credentials"
    public static let account = "primary"

    public init() {}

    public func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SyncAccessKeyStoreError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ key: String) throws {
        let data = Data(key.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw SyncAccessKeyStoreError.keychain(updateStatus)
        }
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SyncAccessKeyStoreError.keychain(addStatus)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SyncAccessKeyStoreError.keychain(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

public enum SyncAccessKeyStoreError: LocalizedError {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "Keychain operation failed (\(status))"
        }
    }
}

public enum ObeliskDeviceIdentity {
    private static let key = "obelisk.sync.device-id"

    public static func current(defaults: UserDefaults = .standard) -> UUID {
        if let value = defaults.string(forKey: key), let id = UUID(uuidString: value) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString.lowercased(), forKey: key)
        return id
    }
}
