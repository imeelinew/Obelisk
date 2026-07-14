import Foundation

public struct ObeliskServerConfiguration: Equatable, Sendable {
    public var apiURL: URL
    public var powerSyncURL: URL

    public init(apiURL: URL, powerSyncURL: URL) {
        self.apiURL = apiURL
        self.powerSyncURL = powerSyncURL
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) throws -> ObeliskServerConfiguration {
        guard let apiURL = endpoint(
            environment["OBELISK_API_URL"] ?? infoDictionary["ObeliskAPIURL"] as? String
        ) else {
            throw ObeliskServerConfigurationError.missing("ObeliskAPIURL")
        }
        guard let powerSyncURL = endpoint(
            environment["OBELISK_POWERSYNC_URL"] ?? infoDictionary["ObeliskPowerSyncURL"] as? String
        ) else {
            throw ObeliskServerConfigurationError.missing("ObeliskPowerSyncURL")
        }
        return ObeliskServerConfiguration(apiURL: apiURL, powerSyncURL: powerSyncURL)
    }

    private static func endpoint(_ value: String?) -> URL? {
        guard
            let value,
            let url = URL(string: value),
            let scheme = url.scheme,
            ["http", "https"].contains(scheme),
            url.host != nil
        else {
            return nil
        }
        return url
    }
}

public enum ObeliskServerConfigurationError: LocalizedError {
    case missing(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let name):
            "Missing required server configuration: \(name)"
        }
    }
}
