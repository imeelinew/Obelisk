import Foundation
import ObeliskCore
import ObeliskData
import ObeliskSync
import PowerSync
import Testing

@Suite(.serialized)
struct ObeliskKitTests {

    @Test func snapshotPreservesNormalizedRelationships() {
        let collection = BookmarkCollection(name: "Reading")
        let bookmark = Bookmark(title: "Example", url: "https://example.com")
        let usage = UsageRecord(count: 2, lastClickedAt: Date(timeIntervalSince1970: 100))
        let snapshot = ObeliskLibrarySnapshot(
            bookmarks: [bookmark],
            collections: [collection],
            collectionByBookmarkID: [bookmark.id: collection.id],
            usageByBookmarkID: [bookmark.id: usage]
        )

        #expect(snapshot.collectionByBookmarkID[bookmark.id] == collection.id)
        #expect(snapshot.usageByBookmarkID[bookmark.id] == usage)
    }

    @Test func logicalClockOrdersConcurrentEventsDeterministically() {
        let deviceA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let deviceB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let now = Date(timeIntervalSince1970: 100)
        var clockA = LogicalClock(deviceID: deviceA)
        var clockB = LogicalClock(deviceID: deviceB)

        let first = clockA.tick(now: now)
        let second = clockA.tick(now: now)
        let concurrent = clockB.tick(now: now)

        #expect(first < second)
        #expect(first < concurrent)
        #expect(clockB.observe(second, now: now) > second)
    }

    @Test func powerSyncDatabaseRoundTripsNormalizedDataAndQueuesWrites() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskKitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try await ObeliskDatabase.open(
            rootDirectory: root,
            deviceID: UUID()
        )
        let collection = BookmarkCollection(name: "Reference", sortOrder: 7, showInMenu: true)
        let bookmark = Bookmark(
            title: "PowerSync",
            url: "https://www.powersync.com",
            createdAt: Date(timeIntervalSince1970: 1_789_000_000),
            originalTitle: "PowerSync"
        )

        try database.saveCollection(collection)
        try database.saveBookmark(bookmark, collectionID: collection.id)
        try database.recordUsage(
            bookmarkID: bookmark.id, at: Date(timeIntervalSince1970: 1_789_000_100))
        try database.recordUsage(
            bookmarkID: bookmark.id, at: Date(timeIntervalSince1970: 1_789_000_200))

        var snapshot = try database.loadSnapshot()
        #expect(snapshot.bookmarks == [bookmark])
        #expect(snapshot.collections == [collection])
        #expect(snapshot.collectionByBookmarkID[bookmark.id] == collection.id)
        #expect(snapshot.usageByBookmarkID[bookmark.id]?.count == 2)
        #expect(
            snapshot.usageByBookmarkID[bookmark.id]?.lastClickedAt
                == Date(timeIntervalSince1970: 1_789_000_200))

        var queuedTables = Set<String>()
        for try await transaction in database.powerSync.getCrudTransactions() {
            queuedTables.formUnion(transaction.crud.map(\.table))
        }
        #expect(queuedTables == ["collections", "bookmarks", "usage_events"])

        try database.deleteCollection(id: collection.id)
        snapshot = try database.loadSnapshot()
        #expect(snapshot.collections.isEmpty)
        #expect(snapshot.collectionByBookmarkID.isEmpty)

        try database.deleteBookmark(id: bookmark.id)
        snapshot = try database.loadSnapshot()
        #expect(snapshot.bookmarks.isEmpty)
    }

    @Test func localWritesAdvancePastObservedRemoteVersions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskHLC-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let localDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let remoteDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let database = try await ObeliskDatabase.open(
            rootDirectory: root,
            deviceID: localDevice
        )
        var bookmark = Bookmark(title: "Before", url: "https://example.com")
        try database.saveBookmark(bookmark, collectionID: nil)

        let remote = LogicalTimestamp(
            milliseconds: Int64(Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000),
            counter: 7,
            deviceID: remoteDevice
        )
        let remoteVersions = ["title": remote]
        let encodedRemoteVersions = String(
            data: try JSONEncoder().encode(remoteVersions),
            encoding: .utf8
        )!
        _ = try await database.powerSync.execute(
            sql: "UPDATE bookmarks SET field_versions = ? WHERE id = ?",
            parameters: [encodedRemoteVersions, bookmark.id.uuidString.lowercased()]
        )

        bookmark.title = "After"
        try database.saveBookmark(bookmark, collectionID: nil)
        let encodedLocalVersions = try await database.powerSync.get(
            sql: "SELECT field_versions FROM bookmarks WHERE id = ?",
            parameters: [bookmark.id.uuidString.lowercased()],
            mapper: { try $0.getString(name: "field_versions") }
        )
        let localVersions = try JSONDecoder().decode(
            [String: LogicalTimestamp].self,
            from: Data(encodedLocalVersions.utf8)
        )
        let localTitle = try #require(localVersions["title"])

        #expect(localTitle > remote)
        #expect(localTitle.deviceID == localDevice)
        #expect(localTitle.milliseconds == remote.milliseconds)
        #expect(localTitle.counter == remote.counter + 1)
    }

    @Test func authClientDecodesServerDatesAndPersistsTheSession() async throws {
        let accountID = UUID()
        let deviceID = UUID()
        let response = """
            {
              "accountId": "\(accountID.uuidString.lowercased())",
              "deviceId": "\(deviceID.uuidString.lowercased())",
              "accessToken": "access",
              "refreshToken": "refresh",
              "expiresAt": "2026-07-14T02:22:38.123456Z"
            }
            """
        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/v1/auth/login")
            #expect(request.timeoutInterval == 30)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(response.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let store = MemorySessionStore()
        let client = ObeliskAuthClient(
            configuration: ObeliskServerConfiguration(
                apiURL: URL(string: "https://api.example.test")!,
                powerSyncURL: URL(string: "https://sync.example.test")!
            ),
            deviceID: deviceID,
            store: store,
            session: URLSession(configuration: configuration)
        )

        let authenticated = try await client.login(
            email: "me@example.com", password: "correct horse battery staple")
        #expect(authenticated.accountID == accountID)
        #expect(authenticated.deviceID == deviceID)
        #expect(authenticated.expiresAt.timeIntervalSince1970 == 1_783_995_758.123456)
        #expect(try store.load() == authenticated)
    }

    @Test func authClientTestsTheConfiguredAPIHealthEndpoint() async throws {
        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.absoluteString == "https://api.example.test/healthz")
            #expect(request.timeoutInterval == 30)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data("{\"status\":\"ok\"}".utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let client = ObeliskAuthClient(
            configuration: ObeliskServerConfiguration(
                apiURL: URL(string: "https://api.example.test")!,
                powerSyncURL: URL(string: "https://sync.example.test")!
            ),
            store: MemorySessionStore(),
            session: URLSession(configuration: sessionConfiguration)
        )

        try await client.testAPIConnection()
    }

    @Test func authClientCoalescesConcurrentTokenRefreshes() async throws {
        let accountID = UUID()
        let deviceID = UUID()
        let expired = ObeliskAuthSession(
            accountID: accountID,
            deviceID: deviceID,
            accessToken: "expired-access",
            refreshToken: "refresh-1",
            expiresAt: Date(timeIntervalSince1970: 0)
        )
        let store = MemorySessionStore(session: expired)
        let lock = NSLock()
        var refreshCount = 0

        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/auth/refresh":
                lock.withLock { refreshCount += 1 }
                Thread.sleep(forTimeInterval: 0.05)
                let response = """
                    {
                      "accountId": "\(accountID.uuidString.lowercased())",
                      "deviceId": "\(deviceID.uuidString.lowercased())",
                      "accessToken": "fresh-access",
                      "refreshToken": "refresh-2",
                      "expiresAt": "2030-01-01T00:00:00Z"
                    }
                    """
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(response.utf8)
                )
            case "/v1/auth/powersync-token":
                let response = """
                    {"token":"powersync","expiresAt":"2030-01-01T00:00:00Z"}
                    """
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(response.utf8)
                )
            default:
                throw URLError(.badURL)
            }
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = ObeliskAuthClient(
            configuration: ObeliskServerConfiguration(
                apiURL: URL(string: "https://api.example.test")!,
                powerSyncURL: URL(string: "https://sync.example.test")!
            ),
            deviceID: deviceID,
            store: store,
            session: URLSession(configuration: configuration)
        )
        _ = try await client.restoreSession()

        async let first = client.powerSyncCredentials()
        async let second = client.powerSyncCredentials()
        _ = try await (first, second)

        #expect(lock.withLock { refreshCount } == 1)
        #expect(try store.load()?.accessToken == "fresh-access")
        #expect(try store.load()?.refreshToken == "refresh-2")
    }

    @Test func serverConfigurationRequiresExplicitEndpoints() throws {
        let configuration = try ObeliskServerConfiguration.load(
            environment: [
                "OBELISK_API_URL": "https://api.example.test",
                "OBELISK_POWERSYNC_URL": "https://sync.example.test",
            ], infoDictionary: [:])

        #expect(configuration.apiURL.absoluteString == "https://api.example.test")
        #expect(configuration.powerSyncURL.absoluteString == "https://sync.example.test")
        #expect(throws: ObeliskServerConfigurationError.self) {
            _ = try ObeliskServerConfiguration.load(environment: [:], infoDictionary: [:])
        }
    }

    @Test func localDatabaseBindsToExactlyOneAccount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskAccountBinding-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = UUID()
        let device = UUID()

        let localDatabase = try await ObeliskDatabase.open(rootDirectory: root, deviceID: device)
        try localDatabase.bindToCloudAccount(account)
        try localDatabase.bindToCloudAccount(account)
        #expect(throws: ObeliskDatabaseError.self) {
            try localDatabase.bindToCloudAccount(UUID())
        }
    }

}

private final class MemorySessionStore: ObeliskSessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: ObeliskAuthSession?

    init(session: ObeliskAuthSession? = nil) {
        self.session = session
    }

    func load() throws -> ObeliskAuthSession? {
        lock.withLock { session }
    }

    func save(_ session: ObeliskAuthSession) throws {
        lock.withLock { self.session = session }
    }

    func clear() throws {
        lock.withLock { session = nil }
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
