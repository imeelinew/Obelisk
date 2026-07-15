import Foundation
import Security

public struct ObeliskAuthSession: Codable, Equatable, Sendable {
    public var accountID: UUID
    public var deviceID: UUID
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(
        accountID: UUID,
        deviceID: UUID,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date
    ) {
        self.accountID = accountID
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case deviceID = "deviceId"
        case accessToken
        case refreshToken
        case expiresAt
    }
}

public protocol ObeliskSessionStore: Sendable {
    func load() throws -> ObeliskAuthSession?
    func save(_ session: ObeliskAuthSession) throws
    func clear() throws
}

public final class KeychainObeliskSessionStore: ObeliskSessionStore, @unchecked Sendable {
    public static let service = "com.eli.Obelisk.sync.session"
    public static let account = "primary"

    public init() {}

    public func load() throws -> ObeliskAuthSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ObeliskSessionStoreError.keychain(status)
        }
        return try JSONDecoder().decode(ObeliskAuthSession.self, from: data)
    }

    public func save(_ session: ObeliskAuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw ObeliskSessionStoreError.keychain(updateStatus)
        }
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ObeliskSessionStoreError.keychain(addStatus)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ObeliskSessionStoreError.keychain(status)
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

public enum ObeliskSessionStoreError: LocalizedError {
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

    public static func current(
        defaults: UserDefaults = .standard,
        sessionStore: any ObeliskSessionStore = KeychainObeliskSessionStore()
    ) -> UUID {
        if let session = try? sessionStore.load() {
            defaults.set(session.deviceID.uuidString.lowercased(), forKey: key)
            return session.deviceID
        }
        if let value = defaults.string(forKey: key), let id = UUID(uuidString: value) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString.lowercased(), forKey: key)
        return id
    }
}
