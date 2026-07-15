import Foundation
import ObeliskCore
import ObeliskData
import ObeliskSync
import PowerSync
import Testing

@Suite(.serialized)
struct ObeliskKitTests {

    @Test func deviceIdentityRestoresTheAuthenticatedDeviceAfterPreferencesAreLost() throws {
        let suiteName = "ObeliskDeviceIdentityTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let deviceID = UUID()
        let session = ObeliskAuthSession(
            accountID: UUID(),
            deviceID: deviceID,
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: .distantFuture
        )

        let restored = ObeliskDeviceIdentity.current(
            defaults: defaults,
            sessionStore: MemorySessionStore(session: session)
        )

        #expect(restored == deviceID)
        #expect(defaults.string(forKey: "obelisk.sync.device-id") == deviceID.uuidString.lowercased())
    }

    @Test func authenticatedDeviceIdentityReplacesStalePreferences() throws {
        let suiteName = "ObeliskDeviceIdentityTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(UUID().uuidString, forKey: "obelisk.sync.device-id")
        let deviceID = UUID()
        let session = ObeliskAuthSession(
            accountID: UUID(),
            deviceID: deviceID,
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: .distantFuture
        )

        let restored = ObeliskDeviceIdentity.current(
            defaults: defaults,
            sessionStore: MemorySessionStore(session: session)
        )

        #expect(restored == deviceID)
        #expect(defaults.string(forKey: "obelisk.sync.device-id") == deviceID.uuidString.lowercased())
    }

    @Test func faviconCandidatesPreferLargeDeclaredIconsAndShareHostCache() throws {
        let pageURL = try #require(URL(string: "https://example.com/articles/one"))
        let html = """
        <link rel="icon" sizes="16x16" href="/small.png">
        <link rel="apple-touch-icon" sizes="180x180" href="/touch.png">
        <link rel="mask-icon" sizes="any" href="/mask.svg">
        """

        let candidates = FaviconDownloader.candidateURLs(in: html, for: pageURL)

        #expect(candidates.first?.absoluteString == "https://example.com/touch.png")
        #expect(candidates.contains(URL(string: "https://example.com/favicon.ico")!))
        #expect(candidates.last?.absoluteString == "https://icons.duckduckgo.com/ip3/example.com.ico")
        #expect(
            FaviconDownloader.cacheKey(for: pageURL.absoluteString)
                == FaviconDownloader.cacheKey(for: "https://example.com/other")
        )
        #expect(
            FaviconDownloader.cacheKey(for: pageURL.absoluteString)
                != FaviconDownloader.cacheKey(for: "https://example.com:8443/other")
        )
    }

    @Test func snapshotPreservesNormalizedRelationships() {
        let collection = BookmarkCollection(name: "Reading")
        let bookmark = Bookmark(title: "Example", url: "https://example.com")
        let usage = UsageRecord(count: 2, lastClickedAt: Date(timeIntervalSince1970: 100))
        let history = BrowserHistoryRecord(
            id: UUID(),
            title: "History",
            url: "https://history.example",
            visitedAt: Date(timeIntervalSince1970: 200),
            browser: .safari,
            profileName: "默认"
        )
        let snapshot = ObeliskLibrarySnapshot(
            bookmarks: [bookmark],
            collections: [collection],
            collectionByBookmarkID: [bookmark.id: collection.id],
            usageByBookmarkID: [bookmark.id: usage],
            browserHistory: [history],
            browserHistorySettings: BrowserHistorySettings(
                enabledBrowsers: [.chrome, .safari]
            )
        )

        #expect(snapshot.collectionByBookmarkID[bookmark.id] == collection.id)
        #expect(snapshot.usageByBookmarkID[bookmark.id] == usage)
        #expect(snapshot.browserHistory == [history])
        #expect(snapshot.browserHistorySettings?.enabledBrowsers == [.chrome, .safari])
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

    @Test func browserHistorySupportsOnlyApprovedBrowsers() {
        #expect(BrowserHistoryBrowser.allCases == [.dia, .chrome, .safari])

        let settings = BrowserHistorySettings(
            enabledBrowsers: [.safari, .dia, .chrome]
        )

        #expect(settings.enabledBrowsers == [.dia, .chrome, .safari])
        #expect(settings.encodedEnabledSources == "dia,chrome,safari")
        #expect(
            BrowserHistorySettings(
                encodedEnabledSources: "dia,chrome,safari"
            ).enabledBrowsers == [.dia, .chrome, .safari]
        )
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
        let history = BrowserHistoryRecord(
            id: UUID(),
            title: "PowerSync history",
            url: "https://www.powersync.com/history",
            visitedAt: Date(),
            browser: .chrome,
            profileName: "默认"
        )
        let olderHistory = BrowserHistoryRecord(
            id: UUID(),
            title: "Older PowerSync history",
            url: "https://www.powersync.com/history/",
            visitedAt: history.visitedAt.addingTimeInterval(-60),
            browser: .safari,
            profileName: "默认"
        )
        try database.saveBrowserHistory([history, olderHistory])
        try database.saveBrowserHistory([history])
        try database.saveBrowserHistorySettings(
            BrowserHistorySettings(enabledBrowsers: [.chrome, .safari])
        )

        var snapshot = try database.loadSnapshot()
        #expect(snapshot.bookmarks == [bookmark])
        #expect(snapshot.collections == [collection])
        #expect(snapshot.collectionByBookmarkID[bookmark.id] == collection.id)
        #expect(snapshot.usageByBookmarkID[bookmark.id]?.count == 2)
        #expect(
            snapshot.usageByBookmarkID[bookmark.id]?.lastClickedAt
                == Date(timeIntervalSince1970: 1_789_000_200))
        #expect(snapshot.browserHistory.count == 1)
        #expect(snapshot.browserHistory[0].title == history.title)
        #expect(snapshot.browserHistory[0].url == history.url)
        #expect(snapshot.browserHistory[0].browser == history.browser)
        #expect(snapshot.browserHistorySettings?.enabledBrowsers == [.chrome, .safari])

        var queuedTables = Set<String>()
        var browserHistoryMutationCount = 0
        for try await transaction in database.powerSync.getCrudTransactions() {
            queuedTables.formUnion(transaction.crud.map(\.table))
            browserHistoryMutationCount += transaction.crud.count {
                $0.table == "browser_history_events"
            }
        }
        #expect(queuedTables == [
            "browser_history_events",
            "collections",
            "bookmarks",
            "usage_events",
            "browser_history_settings",
        ])
        #expect(browserHistoryMutationCount == 2)

        try database.saveBrowserHistorySettings(
            BrowserHistorySettings(enabledBrowsers: [.dia])
        )
        snapshot = try database.loadSnapshot()
        #expect(snapshot.browserHistorySettings?.enabledBrowsers == [.dia])

        try database.deleteCollection(id: collection.id)
        snapshot = try database.loadSnapshot()
        #expect(snapshot.collections.isEmpty)
        #expect(snapshot.collectionByBookmarkID.isEmpty)

        try database.deleteBookmark(id: bookmark.id)
        snapshot = try database.loadSnapshot()
        #expect(snapshot.bookmarks.isEmpty)
    }

    @Test func databaseObserversBroadcastChangesWithoutConsumingSyncNotifications() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskObservers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try await ObeliskDatabase.open(rootDirectory: root, deviceID: UUID())
        var firstLibraryObserver = database.libraryChanges().makeAsyncIterator()
        var secondLibraryObserver = database.libraryChanges().makeAsyncIterator()
        var pendingObserver = database.pendingUploadCounts().makeAsyncIterator()

        #expect(try await firstLibraryObserver.next() != nil)
        #expect(try await secondLibraryObserver.next() != nil)
        #expect(try await pendingObserver.next() == 0)
        #expect(try database.loadPendingUploadCount() == 0)

        try database.saveBookmark(
            Bookmark(title: "Observed", url: "https://example.com/observed"),
            collectionID: nil
        )

        #expect(try await firstLibraryObserver.next() != nil)
        #expect(try await secondLibraryObserver.next() != nil)
        #expect(try await pendingObserver.next() == 1)
        #expect(try database.loadPendingUploadCount() == 1)
    }

    @Test func browserHistoryRetentionQueuesCloudDeletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskKitHistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await ObeliskDatabase.open(
            rootDirectory: root,
            deviceID: UUID()
        )
        let now = Date()
        let record = BrowserHistoryRecord(
            id: UUID(),
            title: "Private history",
            url: "https://history.example/private",
            visitedAt: now,
            browser: .safari,
            profileName: "默认"
        )

        try database.saveBrowserHistory([record])
        #expect(try database.loadSnapshot().browserHistory.count == 1)

        try database.pruneBrowserHistory(before: now.addingTimeInterval(1))
        #expect(try database.loadSnapshot().browserHistory.isEmpty)

        var operations: [(table: String, operation: String)] = []
        for try await transaction in database.powerSync.getCrudTransactions() {
            operations.append(contentsOf: transaction.crud.map {
                (table: $0.table, operation: $0.op.rawValue)
            })
        }
        #expect(operations.contains {
            $0.table == "browser_history_events" && $0.operation == "DELETE"
        })
    }

    @Test func bookmarkStoreSharesBookmarkAndCollectionRulesAcrossPlatforms() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try await ObeliskDatabase.open(rootDirectory: root, deviceID: UUID())
        let store = BookmarkStore(database: database)
        let collection = try store.createCollection(name: " Reading ")
        let bookmark = try store.add(
            title: " Example ",
            url: "https://example.com/",
            collectionID: collection.id
        )
        let snapshot = try store.snapshot()

        #expect(collection.name == "Reading")
        #expect(bookmark.title == "Example")
        #expect(snapshot.collectionByBookmarkID[bookmark.id] == collection.id)
        #expect(throws: BookmarkStoreError.duplicateCollectionName) {
            try store.createCollection(name: "reading")
        }
        #expect(throws: BookmarkStoreError.duplicateURL("https://example.com")) {
            try store.add(title: "Duplicate", url: "https://example.com")
        }

        var edited = bookmark
        edited.title = "Edited"
        edited.url = "https://edited.example.com"
        let updated = try store.update(edited, collectionID: nil)
        #expect(updated.title == "Edited")
        #expect(updated.url == "https://edited.example.com")
        #expect(try store.snapshot().collectionByBookmarkID[bookmark.id] == nil)

        try store.delete(ids: [bookmark.id])
        #expect(try store.snapshot().bookmarks.isEmpty)
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

    @Test func bookmarkMutationsUploadImmediately() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskImmediateSync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let deviceID = UUID()
        let accountID = UUID()
        let database = try await ObeliskDatabase.open(rootDirectory: root, deviceID: deviceID)
        let store = BookmarkStore(database: database)
        let bookmark = try store.add(title: "Immediate", url: "https://immediate.example.com")

        let lock = NSLock()
        var uploadedBatches: [[CapturedMutation]] = []
        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/v1/sync/mutations")
            let body = try requestBody(request)
            let batch = try JSONDecoder().decode(CapturedMutationBatch.self, from: body)
            lock.withLock { uploadedBatches.append(batch.mutations) }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil
                )!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let auth = ObeliskAuthClient(
            configuration: ObeliskServerConfiguration(
                apiURL: URL(string: "https://api.example.test")!,
                powerSyncURL: URL(string: "https://sync.example.test")!
            ),
            deviceID: deviceID,
            store: MemorySessionStore(
                session: ObeliskAuthSession(
                    accountID: accountID,
                    deviceID: deviceID,
                    accessToken: "access",
                    refreshToken: "refresh",
                    expiresAt: Date().addingTimeInterval(3_600)
                )
            ),
            session: URLSession(configuration: sessionConfiguration)
        )
        _ = try await auth.restoreSession()

        let connector = ObeliskPowerSyncConnector(auth: auth)
        try await connector.uploadData(database: database.powerSync)
        try store.delete(ids: [bookmark.id])
        try await connector.uploadData(database: database.powerSync)

        let batches = lock.withLock { uploadedBatches }
        #expect(batches.count == 2)
        #expect(batches[0].map(\.operation) == ["PUT"])
        #expect(batches[1].map(\.operation) == ["PATCH"])
        let pending = try await database.powerSync.get(
            sql: "SELECT COUNT(*) AS count FROM ps_crud",
            parameters: [],
            mapper: { Int(try $0.getInt64(name: "count")) }
        )
        #expect(pending == 0)
        #expect(try store.snapshot().bookmarks.isEmpty)
    }

    @Test func cancelledMutationUploadRemainsQueuedWithoutBecomingASyncFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskCancelledUpload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let deviceID = UUID()
        let accountID = UUID()
        let database = try await ObeliskDatabase.open(rootDirectory: root, deviceID: deviceID)
        let store = BookmarkStore(database: database)
        _ = try store.add(title: "Cancelled", url: "https://cancelled.example.com")

        MockURLProtocol.handler = { _ in throw URLError(.cancelled) }
        defer { MockURLProtocol.handler = nil }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let auth = ObeliskAuthClient(
            configuration: ObeliskServerConfiguration(
                apiURL: URL(string: "https://api.example.test")!,
                powerSyncURL: URL(string: "https://sync.example.test")!
            ),
            deviceID: deviceID,
            store: MemorySessionStore(
                session: ObeliskAuthSession(
                    accountID: accountID,
                    deviceID: deviceID,
                    accessToken: "access",
                    refreshToken: "refresh",
                    expiresAt: Date().addingTimeInterval(3_600)
                )
            ),
            session: URLSession(configuration: sessionConfiguration)
        )
        _ = try await auth.restoreSession()

        let connector = ObeliskPowerSyncConnector(auth: auth)
        await #expect(throws: CancellationError.self) {
            try await connector.uploadData(database: database.powerSync)
        }
        #expect(try database.loadPendingUploadCount() == 1)
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

private struct CapturedMutationBatch: Decodable {
    let mutations: [CapturedMutation]
}

private struct CapturedMutation: Decodable {
    let operation: String
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }
    let stream = try #require(request.httpBodyStream)
    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count == 0 { return data }
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
        data.append(buffer, count: count)
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
