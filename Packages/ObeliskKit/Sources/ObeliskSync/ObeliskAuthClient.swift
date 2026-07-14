import Foundation
import PowerSync

public actor ObeliskAuthClient {
    private static let requestTimeout: TimeInterval = 30

    private struct CredentialsRequest: Encodable {
        var email: String
        var password: String
        var deviceID: UUID

        private enum CodingKeys: String, CodingKey {
            case email, password
            case deviceID = "deviceId"
        }
    }

    private struct RefreshRequest: Encodable {
        var refreshToken: String
    }

    private struct PowerSyncTokenResponse: Decodable {
        var token: String
    }

    private struct ErrorResponse: Decodable {
        var error: String
    }

    public nonisolated let configuration: ObeliskServerConfiguration
    public nonisolated let deviceID: UUID

    private let store: any ObeliskSessionStore
    private let session: URLSession
    private var current: ObeliskAuthSession?
    private var refreshTask: Task<ObeliskAuthSession, Error>?

    public init(
        configuration: ObeliskServerConfiguration,
        deviceID: UUID = ObeliskDeviceIdentity.current(),
        store: any ObeliskSessionStore = KeychainObeliskSessionStore(),
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        self.deviceID = deviceID
        self.store = store
        self.session = session ?? Self.makeSession()
    }

    public func restoreSession() throws -> ObeliskAuthSession? {
        let restored = try store.load()
        if let restored, restored.deviceID != deviceID {
            throw ObeliskAuthError.invalidServerResponse
        }
        current = restored
        return current
    }

    @discardableResult
    public func login(email: String, password: String) async throws -> ObeliskAuthSession {
        try await authenticate(email: email, password: password)
    }

    public func signOut() throws {
        refreshTask?.cancel()
        refreshTask = nil
        try store.clear()
        current = nil
    }

    public func testAPIConnection() async throws {
        var request = URLRequest(
            url: configuration.apiURL.appending(path: "healthz"),
            timeoutInterval: Self.requestTimeout
        )
        request.httpMethod = "GET"
        _ = try await responseData(for: request, expectedStatus: 200)
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
        _ = try await responseData(for: request, expectedStatus: 204)
    }

    private func authenticate(email: String, password: String) async throws -> ObeliskAuthSession {
        refreshTask?.cancel()
        refreshTask = nil
        var request = URLRequest(
            url: configuration.apiURL.appending(path: "v1/auth/login"),
            timeoutInterval: Self.requestTimeout
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(
            CredentialsRequest(email: email, password: password, deviceID: deviceID)
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

        if let refreshTask {
            let refreshed = try await refreshTask.value
            return refreshed.accessToken
        }

        let task = Task { try await self.refresh(current) }
        refreshTask = task
        do {
            let refreshed = try await task.value
            refreshTask = nil
            return refreshed.accessToken
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private func refresh(_ expired: ObeliskAuthSession) async throws -> ObeliskAuthSession {
        var request = URLRequest(
            url: configuration.apiURL.appending(path: "v1/auth/refresh"),
            timeoutInterval: Self.requestTimeout
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(RefreshRequest(refreshToken: expired.refreshToken))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let refreshed: ObeliskAuthSession = try await send(request)
        try Task.checkCancellation()
        guard refreshed.accountID == expired.accountID, refreshed.deviceID == expired.deviceID else {
            throw ObeliskAuthError.invalidServerResponse
        }
        try store.save(refreshed)
        current = refreshed
        return refreshed
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data = try await responseData(for: request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }

    private func responseData(
        for request: URLRequest,
        expectedStatus: Int? = nil
    ) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ObeliskAuthError.invalidServerResponse
        }
        let accepted = expectedStatus.map { http.statusCode == $0 }
            ?? (200..<300).contains(http.statusCode)
        guard accepted else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error)
                ?? "Server returned HTTP \(http.statusCode)"
            throw ObeliskAuthError.server(message)
        }
        return data
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
