import Foundation
import PowerSync

public actor ObeliskAuthClient {
    private static let requestTimeout: TimeInterval = 30

    private struct CredentialsRequest: Encodable {
        var email: String
        var password: String
        var deviceId: UUID
    }

    private struct RefreshRequest: Encodable {
        var refreshToken: String
    }

    private struct PowerSyncTokenResponse: Decodable {
        var token: String
        var expiresAt: Date
    }

    private struct ErrorResponse: Decodable {
        var error: String
    }

    public let configuration: ObeliskServerConfiguration
    public let deviceID: UUID

    private let store: any ObeliskSessionStore
    private let session: URLSession
    private var current: ObeliskAuthSession?

    public init(
        configuration: ObeliskServerConfiguration,
        deviceID: UUID = ObeliskDeviceIdentity.current(),
        store: any ObeliskSessionStore = KeychainObeliskSessionStore(),
        session: URLSession? = nil
    ) throws {
        self.configuration = configuration
        self.deviceID = deviceID
        self.store = store
        self.session = session ?? Self.makeSession()
        self.current = try store.load()
    }

    public func restoredSession() -> ObeliskAuthSession? {
        current
    }

    @discardableResult
    public func login(email: String, password: String) async throws -> ObeliskAuthSession {
        try await authenticate(path: "v1/auth/login", email: email, password: password)
    }

    public func signOut() throws {
        try store.clear()
        current = nil
    }

    public func powerSyncCredentials() async throws -> PowerSyncCredentials {
        let accessToken = try await validAccessToken()
        var request = URLRequest(
            url: configuration.apiURL.appending(path: "v1/auth/powersync-token"),
            timeoutInterval: Self.requestTimeout
        )
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let response: PowerSyncTokenResponse = try await send(request)
        return PowerSyncCredentials(
            endpoint: configuration.powerSyncURL.absoluteString,
            token: response.token
        )
    }

    func upload(_ mutations: [ObeliskMutationUpload]) async throws {
        let accessToken = try await validAccessToken()
        var request = URLRequest(
            url: configuration.apiURL.appending(path: "v1/sync/mutations"),
            timeoutInterval: Self.requestTimeout
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(ObeliskMutationBatch(mutations: mutations))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 204 else {
            throw ObeliskAuthError.invalidServerResponse
        }
    }

    private func authenticate(path: String, email: String, password: String) async throws -> ObeliskAuthSession {
        var request = URLRequest(
            url: configuration.apiURL.appending(path: path),
            timeoutInterval: Self.requestTimeout
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(
            CredentialsRequest(email: email, password: password, deviceId: deviceID)
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let authenticated: ObeliskAuthSession = try await send(request)
        guard authenticated.deviceID == deviceID else {
            throw ObeliskAuthError.invalidServerResponse
        }
        try store.save(authenticated)
        current = authenticated
        return authenticated
    }

    private func validAccessToken(now: Date = Date()) async throws -> String {
        guard let current else {
            throw ObeliskAuthError.signedOut
        }
        if current.expiresAt > now.addingTimeInterval(60) {
            return current.accessToken
        }

        var request = URLRequest(
            url: configuration.apiURL.appending(path: "v1/auth/refresh"),
            timeoutInterval: Self.requestTimeout
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(RefreshRequest(refreshToken: current.refreshToken))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let refreshed: ObeliskAuthSession = try await send(request)
        guard refreshed.accountID == current.accountID, refreshed.deviceID == current.deviceID else {
            throw ObeliskAuthError.invalidServerResponse
        }
        try store.save(refreshed)
        self.current = refreshed
        return refreshed.accessToken
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ObeliskAuthError.invalidServerResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error)
                ?? "Server returned HTTP \(http.statusCode)"
            throw ObeliskAuthError.server(message)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }

    private nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }
}

public enum ObeliskAuthError: LocalizedError {
    case signedOut
    case invalidServerResponse
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .signedOut:
            "Sign in is required"
        case .invalidServerResponse:
            "The Obelisk server returned an invalid response"
        case .server(let message):
            message
        }
    }
}
