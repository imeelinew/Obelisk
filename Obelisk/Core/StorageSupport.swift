import Foundation
import Security

enum ObeliskPrivateStorage {
    static let vaultDirectoryName = "Data"

    static func faviconDirectory(in rootDirectory: URL) -> URL {
        if BookmarkStore.environmentRootOverride() != nil {
            return rootDirectory
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("Favicons", isDirectory: true)
        }
        let fileManager = FileManager.default
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
        return cacheRoot
            .appendingPathComponent("com.eli.Obelisk", isDirectory: true)
            .appendingPathComponent("Favicons", isDirectory: true)
    }

    static func faviconIndexURL(rootDirectory: URL) -> URL {
        faviconDirectory(in: rootDirectory).appendingPathComponent("index.json")
    }

    static func faviconIconURL(rootDirectory: URL, key: String) -> URL {
        faviconDirectory(in: rootDirectory).appendingPathComponent("\(key).png")
    }
}

enum LocalFileAccess {
    static func readData(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    static func writeData(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions = [.atomic]
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: options)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func removeItem(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

final class KeychainAPIKeyStore {
    static let service = "com.eli.Obelisk.llm-apikey.v3"

    private let service: String
    private let account: String

    init(account: String = "default", service: String = KeychainAPIKeyStore.service) {
        self.account = account
        self.service = service
    }

    func readAPIKey() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ObeliskStorageError.keychainReadFailed(status)
        }
        return String(data: data, encoding: .utf8)
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try deleteAPIKey()
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let query = baseQuery()
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else { throw ObeliskStorageError.keychainWriteFailed(status) }
            return
        }

        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw ObeliskStorageError.keychainWriteFailed(status) }
    }

    func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ObeliskStorageError.keychainWriteFailed(status)
        }
    }

    func hasAPIKey() -> Bool {
        (try? readAPIKey())?.isEmpty == false
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
