import Foundation
import ObeliskData

/// HTTP client for the Worker sync API. One bearer key, three endpoints.
public struct ObeliskSyncClient: Sendable {
    public struct PushRowResult: Decodable, Sendable {
        public var table: String
        public var id: String
        public var status: String
        public var error: String?

        public var isApplied: Bool { status == "applied" }
    }

    public struct PushResponse: Decodable, Sendable {
        public var results: [PushRowResult]
        public var cursor: Int64
    }

    private struct PushRequestBody: Encodable {
        var rows: [SyncPushRow]
    }

    private struct HistoryRequestBody: Encodable {
        var deviceId: String
        var records: [SyncHistoryRecord]
    }

    private struct ErrorResponse: Decodable {
        var error: String
    }

    public let baseURL: URL

    private let accessKey: String
    private let session: URLSession

    public init(baseURL: URL, accessKey: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.accessKey = accessKey
        self.session = session ?? Self.makeSession()
    }

    public func testConnection() async throws {
        var request = URLRequest(url: baseURL.appending(path: "healthz"))
        request.httpMethod = "GET"
        _ = try await responseData(for: request, authorized: false)
    }

    public func push(_ rows: [SyncPushRow]) async throws -> PushResponse {
        var request = URLRequest(url: baseURL.appending(path: "v1/push"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(PushRequestBody(rows: rows))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try await responseData(for: request)
        return try JSONDecoder().decode(PushResponse.self, from: data)
    }

    public func changes(since cursor: Int64) async throws -> SyncChangesPage {
        var components = URLComponents(
            url: baseURL.appending(path: "v1/changes"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "since", value: String(cursor))]
        guard let url = components?.url else {
            throw ObeliskSyncError.invalidServerResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data = try await responseData(for: request)
        return try JSONDecoder().decode(SyncChangesPage.self, from: data)
    }

    public func reconcileHistory(deviceID: UUID, records: [SyncHistoryRecord]) async throws {
        var request = URLRequest(url: baseURL.appending(path: "v1/browser-history"))
        request.httpMethod = "PUT"
        request.httpBody = try JSONEncoder().encode(
            HistoryRequestBody(deviceId: deviceID.uuidString.lowercased(), records: records)
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await responseData(for: request)
    }

    private func responseData(for request: URLRequest, authorized: Bool = true) async throws -> Data {
        var request = request
        if authorized {
            request.setValue("Bearer \(accessKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ObeliskSyncError.invalidServerResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error)
                ?? "Server returned HTTP \(http.statusCode)"
            if http.statusCode == 401 {
                throw ObeliskSyncError.invalidAccessKey
            }
            throw ObeliskSyncError.server(message)
        }
        return data
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }
}

public enum ObeliskSyncError: LocalizedError, Equatable {
    case notConfigured
    case invalidAccessKey
    case invalidServerResponse
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "尚未配置同步服务地址和访问密钥"
        case .invalidAccessKey:
            "访问密钥无效"
        case .invalidServerResponse:
            "同步服务返回了无效响应"
        case .server(let message):
            message
        }
    }
}
