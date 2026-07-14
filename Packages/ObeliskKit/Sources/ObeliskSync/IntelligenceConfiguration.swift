import Foundation
import Security

public enum LLMModelSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case remote
    case local

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .remote: return "远程 API"
        case .local: return "本地模型 (LM Studio)"
        }
    }
}

public struct LLMProfilesSettings: Codable, Equatable, Sendable {
    public var activeSource: LLMModelSource
    public var remote: LLMConfig
    public var local: LLMConfig

    public init(
        activeSource: LLMModelSource = .remote,
        remote: LLMConfig = .init(),
        local: LLMConfig = .lmStudioPreset
    ) {
        self.activeSource = activeSource
        self.remote = remote
        self.local = local
    }

    public var activeConfig: LLMConfig {
        switch activeSource {
        case .remote: remote
        case .local: local
        }
    }
}

public struct LLMConfig: Codable, Equatable, Sendable {
    public var apiKey: String
    public var model: String
    public var baseURL: String

    private enum CodingKeys: String, CodingKey {
        case apiKey, model, baseURL
    }

    public init(
        apiKey: String = "",
        model: String = "",
        baseURL: String = "https://api.openai.com/v1/chat/completions"
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
    }

    public static let lmStudioPreset = LLMConfig(
        apiKey: "lm-studio",
        model: "qwen3.5-4b",
        baseURL: "http://localhost:1234/v1/chat/completions"
    )

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
            ?? "https://api.openai.com/v1/chat/completions"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !apiKey.isEmpty {
            try container.encode(apiKey, forKey: .apiKey)
        }
        try container.encode(model, forKey: .model)
        try container.encode(baseURL, forKey: .baseURL)
    }
}

public final class LLMConfigStore: @unchecked Sendable {
    private static let keychainService = "com.eli.Obelisk.llm-apikey.v3"
    private static let remoteKeychainAccount = "remote"
    private static let profilesKey = "llmProfilesSettings"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadProfiles() -> LLMProfilesSettings {
        let stored = defaults.data(forKey: Self.profilesKey)
        var settings = stored.flatMap { try? JSONDecoder().decode(LLMProfilesSettings.self, from: $0) }
            ?? LLMProfilesSettings()
        settings.remote.apiKey = (try? readAPIKey()) ?? ""
        if settings.local.apiKey.isEmpty {
            settings.local.apiKey = LLMConfig.lmStudioPreset.apiKey
        }
        if settings.local.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var local = LLMConfig.lmStudioPreset
            local.apiKey = settings.local.apiKey
            settings.local = local
        }
        return settings
    }

    public func load() -> LLMConfig {
        loadProfiles().activeConfig
    }

    public func save(_ settings: LLMProfilesSettings) throws {
        try saveAPIKey(settings.remote.apiKey)
        var persisted = settings
        persisted.remote.apiKey = ""
        defaults.set(try JSONEncoder().encode(persisted), forKey: Self.profilesKey)
    }

    public func save(_ config: LLMConfig) throws {
        var settings = loadProfiles()
        switch settings.activeSource {
        case .remote: settings.remote = config
        case .local: settings.local = config
        }
        try save(settings)
    }

    private func readAPIKey() throws -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw LLMConfigStoreError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    private func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let status = SecItemDelete(keychainQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw LLMConfigStoreError.keychain(status)
            }
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        if SecItemCopyMatching(keychainQuery as CFDictionary, nil) == errSecSuccess {
            let status = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else { throw LLMConfigStoreError.keychain(status) }
            return
        }

        var query = keychainQuery
        query.merge(attributes) { _, new in new }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw LLMConfigStoreError.keychain(status) }
    }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.remoteKeychainAccount,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

public enum LLMConfigStoreError: LocalizedError {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown Security error"
            return "钥匙串操作失败（\(status)：\(message)）"
        }
    }
}
