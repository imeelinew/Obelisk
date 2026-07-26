import Foundation
import GRDB
import ObeliskCore
import ObeliskData
import Testing

@testable import ObeliskSync

@Suite(.serialized)
struct ObeliskKitTests {

    @Test func deviceIdentityIsStableAcrossLaunches() throws {
        let suiteName = "ObeliskDeviceIdentityTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = ObeliskDeviceIdentity.current(defaults: defaults)
        let second = ObeliskDeviceIdentity.current(defaults: defaults)

        #expect(first == second)
        #expect(defaults.string(forKey: "obelisk.sync.device-id") == first.uuidString.lowercased())
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

    @Test func logicalClockSurvivesCounterSaturation() {
        let device = UUID()
        let now = Date(timeIntervalSince1970: 100)
        var clock = LogicalClock(deviceID: device, lastMilliseconds: 100_000, counter: .max)

        let ticked = clock.tick(now: now)
        #expect(ticked.milliseconds == 100_001)
        #expect(ticked.counter == 0)

        var observer = LogicalClock(deviceID: device, lastMilliseconds: 100_000, counter: 5)
        let remote = LogicalTimestamp(milliseconds: 100_000, counter: .max, deviceID: UUID())
        let observed = observer.observe(remote, now: now)
        #expect(observed > remote)
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

    @Test func databaseRoundTripsNormalizedDataAndQueuesOutbox() throws {
        let root = temporaryRoot("Roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try ObeliskDatabase.open(rootDirectory: root, deviceID: UUID())
        let collection = BookmarkCollection(name: "Reference", sortOrder: 7, showInMenu: true)
        let bookmark = Bookmark(
            title: "Obelisk",
            url: "https://obelisk.example",
            createdAt: Date(timeIntervalSince1970: 1_789_000_000),
            originalTitle: "Obelisk"
        )

        try database.saveCollection(collection)
        try database.saveBookmark(bookmark, collectionID: collection.id)
        try database.recordUsage(
            bookmarkID: bookmark.id, at: Date(timeIntervalSince1970: 1_789_000_100))
        try database.recordUsage(
            bookmarkID: bookmark.id, at: Date(timeIntervalSince1970: 1_789_000_200))
        let history = BrowserHistoryRecord(
            id: UUID(),
            title: "History",
            url: "https://obelisk.example/history",
            visitedAt: Date(),
            browser: .chrome,
            profileName: "默认"
        )
        try database.reconcileBrowserHistory([history], for: [.chrome])
        try database.saveBrowserHistorySettings(
            BrowserHistorySettings(enabledBrowsers: [.chrome, .safari])
        )

        var snapshot = try database.loadSnapshot()
        #expect(snapshot.bookmarks == [bookmark])
        #expect(snapshot.collections == [collection])
        #expect(snapshot.collectionByBookmarkID[bookmark.id] == collection.id)
        #expect(snapshot.usageByBookmarkID[bookmark.id]?.count == 2)
        #expect(snapshot.browserHistory.count == 1)
        #expect(snapshot.browserHistorySettings?.enabledBrowsers == [.chrome, .safari])

        let batch = try database.outboxBatch()
        #expect(Set(batch.map(\.tableName)) == [
            "collections",
            "bookmarks",
            "usage_events",
            ObeliskDatabase.historyOutboxTable,
            "browser_history_settings",
        ])

        let bookmarkEntry = try #require(batch.first { $0.tableName == "bookmarks" })
        let payload = try #require(try database.pushRow(for: bookmarkEntry))
        #expect(payload.values["title"] == .string("Obelisk"))
        #expect(payload.values["url"] == .string("https://obelisk.example"))
        #expect(payload.values["collection_id"] == .string(collection.id.uuidString.lowercased()))
        #expect(payload.fieldVersions?["title"] != nil)

        try database.deleteCollection(id: collection.id)
        snapshot = try database.loadSnapshot()
        #expect(snapshot.collections.isEmpty)
        #expect(snapshot.collectionByBookmarkID.isEmpty)

        try database.deleteBookmark(id: bookmark.id)
        snapshot = try database.loadSnapshot()
        #expect(snapshot.bookmarks.isEmpty)

        let deleteEntry = try #require(
            try database.outboxBatch().first { $0.tableName == "bookmarks" }
        )
        let deletePayload = try #require(try database.pushRow(for: deleteEntry))
        #expect(deletePayload.values["deleted_at"] != .null)
    }

    @Test func databaseObserversBroadcastChanges() async throws {
        let root = temporaryRoot("Observers")
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try ObeliskDatabase.open(rootDirectory: root, deviceID: UUID())
        var libraryObserver = database.libraryChanges().makeAsyncIterator()
        var pendingObserver = database.pendingUploadCounts().makeAsyncIterator()

        #expect(try await pendingObserver.next() == 0)
        #expect(try database.loadPendingUploadCount() == 0)

        try database.saveBookmark(
            Bookmark(title: "Observed", url: "https://example.com/observed"),
            collectionID: nil
        )

        #expect(try await libraryObserver.next() != nil)
        #expect(try await pendingObserver.next() == 1)
        #expect(try database.loadPendingUploadCount() == 1)
    }

    @Test func browserHistoryRetentionQueuesHistoryPush() throws {
        let root = temporaryRoot("HistoryRetention")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ObeliskDatabase.open(rootDirectory: root, deviceID: UUID())
        let now = Date()
        let record = BrowserHistoryRecord(
            id: UUID(),
            title: "Private history",
            url: "https://history.example/private",
            visitedAt: now,
            browser: .safari,
            profileName: "默认"
        )

        try database.reconcileBrowserHistory([record], for: [.safari])
        #expect(try database.loadSnapshot().browserHistory.count == 1)
        try database.completeOutboxEntries(try database.outboxBatch())
        #expect(try database.loadPendingUploadCount() == 0)

        try database.pruneBrowserHistory(before: now.addingTimeInterval(1))
        #expect(try database.loadSnapshot().browserHistory.isEmpty)
        #expect(try database.localHistoryRecords().isEmpty)

        let batch = try database.outboxBatch()
        #expect(batch.map(\.tableName) == [ObeliskDatabase.historyOutboxTable])
    }

    @Test func browserHistoryReconciliationMirrorsSourceUpdatesAndDeletions() throws {
        let root = temporaryRoot("HistoryMirror")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ObeliskDatabase.open(rootDirectory: root, deviceID: UUID())
        let now = Date()
        let retained = BrowserHistoryRecord(
            id: UUID(),
            title: "Original title",
            url: "https://example.com/retained",
            visitedAt: now,
            browser: .chrome,
            profileName: "默认"
        )
        let removed = BrowserHistoryRecord(
            id: UUID(),
            title: "Removed",
            url: "https://example.com/removed",
            visitedAt: now.addingTimeInterval(-1),
            browser: .chrome,
            profileName: "默认"
        )
        let safari = BrowserHistoryRecord(
            id: UUID(),
            title: "Safari",
            url: "https://example.com/safari",
            visitedAt: now.addingTimeInterval(-2),
            browser: .safari,
            profileName: "Safari"
        )

        try database.reconcileBrowserHistory([retained, removed], for: [.chrome])
        try database.reconcileBrowserHistory([safari], for: [.safari])

        let updated = BrowserHistoryRecord(
            id: retained.id,
            title: "Updated title",
            url: retained.url,
            visitedAt: retained.visitedAt,
            browser: retained.browser,
            profileName: retained.profileName
        )
        try database.reconcileBrowserHistory([updated], for: [.chrome])

        let snapshot = try database.loadSnapshot()
        #expect(snapshot.browserHistory.count == 2)
        #expect(snapshot.browserHistory.contains { $0.title == "Updated title" })
        #expect(snapshot.browserHistory.contains { $0.title == "Safari" })
        #expect(!snapshot.browserHistory.contains { $0.url == removed.url })

        let localRecords = try database.localHistoryRecords()
        #expect(localRecords.count == 2)
        #expect(localRecords.contains { $0.title == "Updated title" })
    }

    @Test func bookmarkStoreSharesBookmarkAndCollectionRulesAcrossPlatforms() throws {
        let root = temporaryRoot("Store")
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try ObeliskDatabase.open(rootDirectory: root, deviceID: UUID())
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

    @Test func remoteMergePrefersNewerFieldVersionsPerField() throws {
        let root = temporaryRoot("RemoteMerge")
        defer { try? FileManager.default.removeItem(at: root) }
        let localDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let remoteDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let database = try ObeliskDatabase.open(rootDirectory: root, deviceID: localDevice)

        let bookmark = Bookmark(title: "Local title", url: "https://example.com")
        try database.saveBookmark(bookmark, collectionID: nil)

        let future = Int64(Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000)
        let past = Int64(Date().addingTimeInterval(-3_600).timeIntervalSince1970 * 1_000)

        // A newer remote title wins; an older remote pin state loses.
        let page = try changesPage(
            bookmarks: [
                remoteBookmarkJSON(
                    id: bookmark.id,
                    title: "Remote title",
                    url: "https://example.com",
                    isPinned: true,
                    titleVersion: (future, remoteDevice),
                    otherVersion: (past, remoteDevice)
                )
            ]
        )
        try database.applyRemoteChanges(page)

        let snapshot = try database.loadSnapshot()
        #expect(snapshot.bookmarks.count == 1)
        #expect(snapshot.bookmarks[0].title == "Remote title")
        #expect(snapshot.bookmarks[0].isPinned == false)

        // Applying the same page again changes nothing.
        try database.applyRemoteChanges(page)
        #expect(try database.loadSnapshot().bookmarks[0].title == "Remote title")
    }

    @Test func localWritesAdvancePastObservedRemoteVersions() throws {
        let root = temporaryRoot("HLCAdvance")
        defer { try? FileManager.default.removeItem(at: root) }
        let localDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let remoteDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let database = try ObeliskDatabase.open(rootDirectory: root, deviceID: localDevice)

        var bookmark = Bookmark(title: "Before", url: "https://example.com")
        try database.saveBookmark(bookmark, collectionID: nil)

        let futureMilliseconds = Int64(Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000)
        let page = try changesPage(
            bookmarks: [
                remoteBookmarkJSON(
                    id: bookmark.id,
                    title: "Remote",
                    url: "https://example.com",
                    isPinned: false,
                    titleVersion: (futureMilliseconds, remoteDevice),
                    otherVersion: (0, remoteDevice)
                )
            ]
        )
        try database.applyRemoteChanges(page)

        bookmark.title = "After"
        try database.saveBookmark(bookmark, collectionID: nil)

        let entry = try #require(try database.outboxBatch().first { $0.tableName == "bookmarks" })
        let payload = try #require(try database.pushRow(for: entry))
        let titleVersion = try #require(payload.fieldVersions?["title"])
        let remote = LogicalTimestamp(
            milliseconds: futureMilliseconds, counter: 7, deviceID: remoteDevice
        )

        #expect(payload.values["title"] == .string("After"))
        #expect(titleVersion.deviceID == localDevice)
        #expect(titleVersion.milliseconds == futureMilliseconds)
        #expect(titleVersion > remote)
    }

    @Test func remoteApplyDoesNotEnqueueUploads() throws {
        let root = temporaryRoot("RemoteApplyOutbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ObeliskDatabase.open(rootDirectory: root, deviceID: UUID())

        let page = try changesPage(
            bookmarks: [
                remoteBookmarkJSON(
                    id: UUID(),
                    title: "From cloud",
                    url: "https://cloud.example",
                    isPinned: false,
                    titleVersion: (1_000, UUID()),
                    otherVersion: (1_000, UUID())
                )
            ]
        )
        try database.applyRemoteChanges(page)

        #expect(try database.loadSnapshot().bookmarks.count == 1)
        #expect(try database.loadPendingUploadCount() == 0)
    }

    @Test func remoteHistoryMirrorsOtherDevicesOnly() throws {
        let root = temporaryRoot("RemoteHistory")
        defer { try? FileManager.default.removeItem(at: root) }
        let localDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let otherDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let database = try ObeliskDatabase.open(rootDirectory: root, deviceID: localDevice)

        let ownRecord = BrowserHistoryRecord(
            id: UUID(),
            title: "Own row",
            url: "https://example.com/own",
            visitedAt: Date(),
            browser: .safari,
            profileName: "默认"
        )
        try database.reconcileBrowserHistory([ownRecord], for: [.safari])
        let ownID = try #require(try database.localHistoryRecords().first?.id)

        let remoteID = UUID().uuidString.lowercased()
        let visited = Date().addingTimeInterval(-60)
        let page = try changesPage(
            browserHistoryEvents: [
                """
                {
                  "id": "\(remoteID)",
                  "source_device_id": "\(otherDevice.uuidString.lowercased())",
                  "browser": "chrome",
                  "profile_name": "Work",
                  "title": "Remote visit",
                  "url": "https://example.com/remote",
                  "visited_at": "\(isoString(visited))",
                  "created_at": "\(isoString(visited))"
                }
                """
            ],
            browserHistoryDeletions: [ownID]
        )
        try database.applyRemoteChanges(page)

        let snapshot = try database.loadSnapshot()
        // The remote row is mirrored; the deletion must not touch this
        // device's own row.
        #expect(snapshot.browserHistory.contains { $0.title == "Remote visit" })
        #expect(snapshot.browserHistory.contains { $0.title == "Own row" })
    }

    @Test func outboxCompletionRespectsRequeuedEntries() throws {
        let root = temporaryRoot("OutboxRequeue")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ObeliskDatabase.open(rootDirectory: root, deviceID: UUID())

        var bookmark = Bookmark(title: "First", url: "https://example.com")
        try database.saveBookmark(bookmark, collectionID: nil)
        let entry = try #require(try database.outboxBatch().first)

        // The row changes again while the first upload is in flight.
        try await0_1()
        bookmark.title = "Second"
        try database.saveBookmark(bookmark, collectionID: nil)

        try database.completeOutboxEntries([entry])
        #expect(try database.loadPendingUploadCount() == 1)

        let fresh = try #require(try database.outboxBatch().first)
        try database.completeOutboxEntries([fresh])
        #expect(try database.loadPendingUploadCount() == 0)
    }

    @Test func legacyPowerSyncDatabaseMigrates() throws {
        let root = temporaryRoot("LegacyMigration")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent(ObeliskDatabase.fileName)

        let deviceID = UUID()
        let bookmarkID = UUID().uuidString.lowercased()
        let versions = """
        {"title":{"milliseconds":1000,"counter":0,"deviceID":"\(deviceID.uuidString)"}}
        """

        // Simulate the file layout the retired PowerSync stack left behind.
        let legacy = try DatabaseQueue(path: fileURL.path)
        try legacy.write { db in
            try db.execute(sql: """
            CREATE TABLE ps_data__bookmarks (id TEXT PRIMARY KEY, data TEXT);
            CREATE TABLE ps_data__collections (id TEXT PRIMARY KEY, data TEXT);
            CREATE TABLE ps_data__usage_events (id TEXT PRIMARY KEY, data TEXT);
            CREATE TABLE ps_data__browser_history_events (id TEXT PRIMARY KEY, data TEXT);
            CREATE TABLE ps_data__browser_history_settings (id TEXT PRIMARY KEY, data TEXT);
            CREATE TABLE ps_data_local__sync_state (id TEXT PRIMARY KEY, data TEXT);
            CREATE TABLE ps_crud (id INTEGER PRIMARY KEY, data TEXT);
            CREATE VIEW bookmarks AS SELECT id, json_extract(data, '$.title') AS title FROM ps_data__bookmarks;
            """)
            let data = """
            {
              "collection_id": null,
              "title": "Migrated",
              "url": "https://migrated.example",
              "title_optimized": 0,
              "is_hidden": 0,
              "archived_at": null,
              "is_pinned": 1,
              "original_title": "Migrated",
              "position_key": "00000000000000000001-x",
              "field_versions": \(versions.trimmingCharacters(in: .whitespacesAndNewlines)),
              "created_at": "2026-07-01T00:00:00.000Z",
              "updated_at": "2026-07-01T00:00:00.000Z",
              "deleted_at": null
            }
            """
            try db.execute(
                sql: "INSERT INTO ps_data__bookmarks (id, data) VALUES (?, json(?))",
                arguments: [bookmarkID, data]
            )
            try db.execute(
                sql: "INSERT INTO ps_crud (data) VALUES ('{\"op\":\"PATCH\"}')"
            )
        }

        let database = try ObeliskDatabase.open(rootDirectory: root, deviceID: deviceID)
        let snapshot = try database.loadSnapshot()
        #expect(snapshot.bookmarks.count == 1)
        #expect(snapshot.bookmarks[0].title == "Migrated")
        #expect(snapshot.bookmarks[0].isPinned == true)

        // Every PowerSync artifact is gone, including the poisoned queue.
        let inspector = try DatabaseQueue(path: fileURL.path)
        let leftovers = try inspector.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'ps\\_%' ESCAPE '\\'"
            ) ?? -1
        }
        #expect(leftovers == 0)
    }

    @Test func syncEngineDrainsOutboxAndAppliesRemoteChanges() async throws {
        let root = temporaryRoot("Engine")
        defer { try? FileManager.default.removeItem(at: root) }
        let localDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let database = try ObeliskDatabase.open(rootDirectory: root, deviceID: localDevice)
        let store = BookmarkStore(database: database)
        _ = try store.add(title: "Local", url: "https://local.example")

        let remoteBookmarkID = UUID()
        let remoteJSON = try remoteBookmarkJSON(
            id: remoteBookmarkID,
            title: "Remote",
            url: "https://remote.example",
            isPinned: false,
            titleVersion: (2_000, UUID()),
            otherVersion: (2_000, UUID())
        )

        let lock = NSLock()
        var pushedRowKeys: [String] = []
        MockURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/push"):
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
                let rows = body["rows"] as! [[String: Any]]
                let results = rows.map { row in
                    [
                        "table": row["table"] as! String,
                        "id": row["id"] as! String,
                        "status": "applied",
                    ]
                }
                lock.withLock {
                    pushedRowKeys.append(contentsOf: rows.map {
                        "\($0["table"] as! String)/\($0["id"] as! String)"
                    })
                }
                let payload = try JSONSerialization.data(
                    withJSONObject: ["results": results, "cursor": 5]
                )
                return (httpResponse(request, 200), payload)
            case ("GET", "/v1/changes"):
                let payload = """
                {
                  "cursor": 6,
                  "hasMore": false,
                  "collections": [],
                  "bookmarks": [\(remoteJSON)],
                  "usageEvents": [],
                  "browserHistoryEvents": [],
                  "browserHistoryDeletions": [],
                  "browserHistorySettings": []
                }
                """
                return (httpResponse(request, 200), Data(payload.utf8))
            case ("PUT", "/v1/browser-history"):
                return (httpResponse(request, 200), Data("{\"cursor\":5}".utf8))
            default:
                throw URLError(.badURL)
            }
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = ObeliskSyncClient(
            baseURL: URL(string: "https://sync.example.test")!,
            accessKey: "test-key",
            session: URLSession(configuration: configuration)
        )
        let engine = SyncEngine(database: database)
        await engine.setClient(client)

        let outcome = await engine.performSync()
        guard case .success(let rejected) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(rejected == nil)
        #expect(try database.loadPendingUploadCount() == 0)
        #expect(try database.syncCursor() == 6)

        let snapshot = try database.loadSnapshot()
        #expect(snapshot.bookmarks.contains { $0.id == remoteBookmarkID })
        #expect(snapshot.bookmarks.contains { $0.title == "Local" })
        #expect(lock.withLock { pushedRowKeys }.contains { $0.hasPrefix("bookmarks/") })
    }

    @Test func rejectedRowDoesNotBlockOtherUploads() async throws {
        let root = temporaryRoot("RejectedRow")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ObeliskDatabase.open(rootDirectory: root, deviceID: UUID())
        let store = BookmarkStore(database: database)
        let poisoned = try store.add(title: "Poisoned", url: "https://poisoned.example")
        _ = try store.add(title: "Healthy", url: "https://healthy.example")

        MockURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/push"):
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
                let rows = body["rows"] as! [[String: Any]]
                let results = rows.map { row -> [String: Any] in
                    let id = row["id"] as! String
                    if id == poisoned.id.uuidString.lowercased() {
                        return [
                            "table": row["table"] as! String,
                            "id": id,
                            "status": "rejected",
                            "error": "url is invalid",
                        ]
                    }
                    return ["table": row["table"] as! String, "id": id, "status": "applied"]
                }
                let payload = try JSONSerialization.data(
                    withJSONObject: ["results": results, "cursor": 1]
                )
                return (httpResponse(request, 200), payload)
            case ("GET", "/v1/changes"):
                let payload = """
                {
                  "cursor": 1, "hasMore": false, "collections": [], "bookmarks": [],
                  "usageEvents": [], "browserHistoryEvents": [],
                  "browserHistoryDeletions": [], "browserHistorySettings": []
                }
                """
                return (httpResponse(request, 200), Data(payload.utf8))
            default:
                throw URLError(.badURL)
            }
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = ObeliskSyncClient(
            baseURL: URL(string: "https://sync.example.test")!,
            accessKey: "test-key",
            session: URLSession(configuration: configuration)
        )
        let engine = SyncEngine(database: database)
        await engine.setClient(client)

        let outcome = await engine.performSync()
        guard case .success(let rejected) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(rejected?.contains("url is invalid") == true)

        // Only the poisoned row remains queued, with the failure recorded.
        let remaining = try database.outboxBatch()
        #expect(remaining.count == 1)
        #expect(remaining[0].rowID == poisoned.id.uuidString.lowercased())
        #expect(remaining[0].attempts == 1)
    }

    /// Full-stack check against a locally running Worker (`wrangler dev`).
    /// Run with: OBELISK_E2E_URL=http://localhost:8787 swift test
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OBELISK_E2E_URL"] != nil))
    func endToEndTwoDeviceSyncAgainstLocalWorker() async throws {
        let base = try #require(
            URL(string: ProcessInfo.processInfo.environment["OBELISK_E2E_URL"]!)
        )
        let key = ProcessInfo.processInfo.environment["OBELISK_E2E_KEY"]
            ?? "test-access-key-0123456789abcdef"

        let rootA = temporaryRoot("E2EDeviceA")
        let rootB = temporaryRoot("E2EDeviceB")
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let databaseA = try ObeliskDatabase.open(rootDirectory: rootA, deviceID: UUID())
        let databaseB = try ObeliskDatabase.open(rootDirectory: rootB, deviceID: UUID())
        // Bypass any system proxy so localhost reaches wrangler dev directly.
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.connectionProxyDictionary = [:]
        let client = ObeliskSyncClient(
            baseURL: base,
            accessKey: key,
            session: URLSession(configuration: sessionConfiguration)
        )
        let engineA = SyncEngine(database: databaseA)
        let engineB = SyncEngine(database: databaseB)
        await engineA.setClient(client)
        await engineB.setClient(client)

        // Device A creates a bookmark inside a collection and syncs.
        let storeA = BookmarkStore(database: databaseA)
        let collection = try storeA.createCollection(name: "E2E-\(UUID().uuidString.prefix(8))")
        let bookmark = try storeA.add(
            title: "E2E bookmark",
            url: "https://e2e.example/\(UUID().uuidString)",
            collectionID: collection.id
        )
        var outcome = await engineA.performSync()
        guard case .success(nil) = outcome else {
            Issue.record("device A initial sync failed: \(outcome)")
            return
        }

        // Device B pulls it, edits the title, records usage, mirrors browser
        // history, and syncs back.
        outcome = await engineB.performSync()
        guard case .success(nil) = outcome else {
            Issue.record("device B initial sync failed: \(outcome)")
            return
        }
        let storeB = BookmarkStore(database: databaseB)
        var snapshotB = try storeB.snapshot()
        let pulled = try #require(snapshotB.bookmarks.first { $0.id == bookmark.id })
        #expect(pulled.title == "E2E bookmark")
        #expect(snapshotB.collectionByBookmarkID[bookmark.id] == collection.id)

        var edited = pulled
        edited.title = "Edited on B"
        _ = try storeB.update(edited, collectionID: collection.id)
        try databaseB.recordUsage(bookmarkID: bookmark.id)
        try databaseB.reconcileBrowserHistory(
            [
                BrowserHistoryRecord(
                    id: UUID(),
                    title: "B visit",
                    url: "https://e2e.example/visit",
                    visitedAt: Date(),
                    browser: .safari,
                    profileName: "默认"
                )
            ],
            for: [.safari]
        )
        outcome = await engineB.performSync()
        guard case .success(nil) = outcome else {
            Issue.record("device B upload failed: \(outcome)")
            return
        }
        #expect(try databaseB.loadPendingUploadCount() == 0)

        // Device A converges: edited title, usage count, mirrored history.
        outcome = await engineA.performSync()
        guard case .success(nil) = outcome else {
            Issue.record("device A converge failed: \(outcome)")
            return
        }
        let snapshotA = try storeA.snapshot()
        #expect(snapshotA.bookmarks.first { $0.id == bookmark.id }?.title == "Edited on B")
        #expect(snapshotA.usageByBookmarkID[bookmark.id]?.count == 1)
        #expect(snapshotA.browserHistory.contains { $0.title == "B visit" })

        // Device A deletes the bookmark; device B converges.
        try storeA.delete(ids: [bookmark.id])
        outcome = await engineA.performSync()
        guard case .success(nil) = outcome else {
            Issue.record("device A delete sync failed: \(outcome)")
            return
        }
        outcome = await engineB.performSync()
        guard case .success(nil) = outcome else {
            Issue.record("device B delete converge failed: \(outcome)")
            return
        }
        snapshotB = try storeB.snapshot()
        #expect(!snapshotB.bookmarks.contains { $0.id == bookmark.id })
    }

    // MARK: - Helpers

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Obelisk\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func await0_1() throws {
        Thread.sleep(forTimeInterval: 0.01)
    }

    private func isoString(_ date: Date) -> String {
        date.formatted(
            .iso8601.year().month().day()
                .time(includingFractionalSeconds: true)
                .timeZone(separator: .colon)
        )
    }

    private func versionJSON(_ milliseconds: Int64, _ device: UUID, counter: Int = 7) -> String {
        """
        {"milliseconds": \(milliseconds), "counter": \(counter), "deviceID": "\(device.uuidString.lowercased())"}
        """
    }

    private func remoteBookmarkJSON(
        id: UUID,
        title: String,
        url: String,
        isPinned: Bool,
        titleVersion: (Int64, UUID),
        otherVersion: (Int64, UUID)
    ) throws -> String {
        let fields = [
            "collection_id", "url", "title_optimized", "is_hidden",
            "archived_at", "is_pinned", "original_title", "position_key", "deleted_at",
        ]
        let otherVersions = fields
            .map { "\"\($0)\": \(versionJSON(otherVersion.0, otherVersion.1))" }
            .joined(separator: ", ")
        return """
        {
          "id": "\(id.uuidString.lowercased())",
          "collection_id": null,
          "title": "\(title)",
          "url": "\(url)",
          "title_optimized": 0,
          "is_hidden": 0,
          "archived_at": null,
          "is_pinned": \(isPinned ? 1 : 0),
          "original_title": null,
          "position_key": "00000000000000000001-x",
          "created_at": "2026-07-01T00:00:00.000Z",
          "updated_at": "2026-07-01T00:00:00.000Z",
          "deleted_at": null,
          "fieldVersions": {
            "title": \(versionJSON(titleVersion.0, titleVersion.1)),
            \(otherVersions)
          }
        }
        """
    }

    private func changesPage(
        bookmarks: [String] = [],
        browserHistoryEvents: [String] = [],
        browserHistoryDeletions: [String] = []
    ) throws -> SyncChangesPage {
        let deletions = browserHistoryDeletions.map { "\"\($0)\"" }.joined(separator: ", ")
        let json = """
        {
          "cursor": 100,
          "hasMore": false,
          "collections": [],
          "bookmarks": [\(bookmarks.joined(separator: ", "))],
          "usageEvents": [],
          "browserHistoryEvents": [\(browserHistoryEvents.joined(separator: ", "))],
          "browserHistoryDeletions": [\(deletions)],
          "browserHistorySettings": []
        }
        """
        return try JSONDecoder().decode(SyncChangesPage.self, from: Data(json.utf8))
    }
}

private func httpResponse(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
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
