import Foundation
import ObeliskCore
import SQLite3
import Testing
@testable import Obelisk

@Suite(.serialized)
struct BrowserHistoryStoreTests {
    @Test func loadsRecentUniqueChromeURLsWithoutMutatingDatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskBrowserHistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let historyURL = root
            .appendingPathComponent("Google", isDirectory: true)
            .appendingPathComponent("Chrome", isDirectory: true)
            .appendingPathComponent("Default", isDirectory: true)
            .appendingPathComponent("History")
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var database: OpaquePointer?
        #expect(sqlite3_open(historyURL.path, &database) == SQLITE_OK)
        guard let database else { return }
        defer { sqlite3_close(database) }

        try execute(
            "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT, last_visit_time INTEGER NOT NULL);",
            in: database
        )

        let now = Date()
        try insert(
            id: 1,
            url: "https://example.com/article",
            title: "Newest title",
            date: now.addingTimeInterval(-60),
            into: database
        )
        try insert(
            id: 2,
            url: "https://example.com/article",
            title: "Older duplicate",
            date: now.addingTimeInterval(-120),
            into: database
        )
        try insert(
            id: 3,
            url: "https://openai.com",
            title: "OpenAI",
            date: now.addingTimeInterval(-180),
            into: database
        )
        try insert(
            id: 4,
            url: "https://too-old.example",
            title: "Too old",
            date: now.addingTimeInterval(-31 * 24 * 60 * 60),
            into: database
        )

        let sections = try BrowserHistoryStore(
            browsers: [.chrome],
            applicationSupportDirectory: root
        ).loadRecentSections(now: now)
        let records = sections.flatMap(\.records)

        #expect(records.count == 2)
        #expect(records.map(\.title) == ["Newest title", "OpenAI"])
        #expect(records.allSatisfy { $0.browser == .chrome })
        #expect(try rowCount(in: database) == 4)
    }

    @Test func loadsRecentSafariHistoryUsingSafariTimestamp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskSafariHistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let safariDirectory = root.appendingPathComponent("Safari", isDirectory: true)
        let historyURL = safariDirectory.appendingPathComponent("History.db")
        try FileManager.default.createDirectory(at: safariDirectory, withIntermediateDirectories: true)

        var database: OpaquePointer?
        #expect(sqlite3_open(historyURL.path, &database) == SQLITE_OK)
        guard let database else { return }
        defer { sqlite3_close(database) }

        try execute(
            "CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT NOT NULL UNIQUE);",
            in: database
        )
        try execute(
            """
            CREATE TABLE history_visits (
                id INTEGER PRIMARY KEY,
                history_item INTEGER NOT NULL,
                visit_time REAL NOT NULL,
                title TEXT,
                load_successful BOOLEAN NOT NULL DEFAULT 1,
                synthesized BOOLEAN NOT NULL DEFAULT 0
            );
            """,
            in: database
        )

        let now = Date()
        try insertSafariItem(id: 1, url: "https://example.com/iphone", into: database)
        try insertSafariVisit(
            id: 11,
            itemID: 1,
            title: "Visited on iPhone",
            date: now.addingTimeInterval(-45),
            into: database
        )
        try insertSafariItem(id: 2, url: "https://failed.example", into: database)
        try insertSafariVisit(
            id: 12,
            itemID: 2,
            title: "Failed load",
            date: now.addingTimeInterval(-30),
            loadSuccessful: false,
            into: database
        )
        try insertSafariItem(id: 3, url: "https://old.example", into: database)
        try insertSafariVisit(
            id: 13,
            itemID: 3,
            title: "Too old",
            date: now.addingTimeInterval(-31 * 24 * 60 * 60),
            into: database
        )

        let sections = try BrowserHistoryStore(
            browsers: [.safari],
            applicationSupportDirectory: root,
            safariDirectory: safariDirectory
        ).loadRecentSections(now: now)
        let records = sections.flatMap(\.records)

        #expect(records.count == 1)
        #expect(records[0].title == "Visited on iPhone")
        #expect(records[0].url == "https://example.com/iphone")
        #expect(records[0].browser == .safari)
        #expect(abs(records[0].visitedAt.timeIntervalSince(now.addingTimeInterval(-45))) < 0.001)
    }

    @Test func mergesBrowsersInExactVisitTimeOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskMixedHistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let chromeHistoryURL = root
            .appendingPathComponent("Google", isDirectory: true)
            .appendingPathComponent("Chrome", isDirectory: true)
            .appendingPathComponent("Default", isDirectory: true)
            .appendingPathComponent("History")
        try FileManager.default.createDirectory(
            at: chromeHistoryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var chromeDatabase: OpaquePointer?
        #expect(sqlite3_open(chromeHistoryURL.path, &chromeDatabase) == SQLITE_OK)
        guard let chromeDatabase else { return }
        defer { sqlite3_close(chromeDatabase) }
        try execute(
            "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT, last_visit_time INTEGER NOT NULL);",
            in: chromeDatabase
        )

        let safariDirectory = root.appendingPathComponent("Safari", isDirectory: true)
        let safariHistoryURL = safariDirectory.appendingPathComponent("History.db")
        try FileManager.default.createDirectory(at: safariDirectory, withIntermediateDirectories: true)
        var safariDatabase: OpaquePointer?
        #expect(sqlite3_open(safariHistoryURL.path, &safariDatabase) == SQLITE_OK)
        guard let safariDatabase else { return }
        defer { sqlite3_close(safariDatabase) }
        try execute(
            "CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT NOT NULL UNIQUE);",
            in: safariDatabase
        )
        try execute(
            """
            CREATE TABLE history_visits (
                id INTEGER PRIMARY KEY,
                history_item INTEGER NOT NULL,
                visit_time REAL NOT NULL,
                title TEXT,
                load_successful BOOLEAN NOT NULL DEFAULT 1,
                synthesized BOOLEAN NOT NULL DEFAULT 0
            );
            """,
            in: safariDatabase
        )

        let now = Date()
        try insert(id: 1, url: "https://chrome-new.example", title: "Chrome new", date: now.addingTimeInterval(-30), into: chromeDatabase)
        try insertSafariItem(id: 1, url: "https://safari.example", into: safariDatabase)
        try insertSafariVisit(id: 1, itemID: 1, title: "Safari middle", date: now.addingTimeInterval(-60), into: safariDatabase)
        try insert(id: 2, url: "https://chrome-old.example", title: "Chrome old", date: now.addingTimeInterval(-90), into: chromeDatabase)

        let records = try BrowserHistoryStore(
            browsers: [.chrome, .safari],
            applicationSupportDirectory: root,
            safariDirectory: safariDirectory
        ).loadRecentSections(now: now).flatMap(\.records)

        #expect(records.map(\.title) == ["Chrome new", "Safari middle", "Chrome old"])
        #expect(records.map(\.browser) == [.chrome, .safari, .chrome])
    }

    @Test func firefoxRemainsVisibleButIsNotQueried() throws {
        #expect(BrowserHistoryBrowser.firefox.optionTitle == "Firefox（尚未完成）")
        #expect(BrowserHistoryBrowser.safari.optionTitle == "Safari")
        #expect(!BrowserHistoryBrowser.firefox.isImplemented)
        #expect(BrowserHistoryBrowser.safari.isImplemented)

        #expect(throws: BrowserHistoryStoreError.self) {
            _ = try BrowserHistoryStore(browsers: [.firefox]).loadRecentSections()
        }
    }

    @Test func safariPermissionFailureRequestsFullDiskAccess() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskSafariPermissionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let safariDirectory = root.appendingPathComponent("Safari", isDirectory: true)
        let historyURL = safariDirectory.appendingPathComponent("History.db")
        try FileManager.default.createDirectory(at: safariDirectory, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: historyURL.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: historyURL.path)

        do {
            _ = try BrowserHistoryStore(
                browsers: [.safari],
                applicationSupportDirectory: root,
                safariDirectory: safariDirectory
            ).loadRecentSections()
            Issue.record("Expected Safari history read to require Full Disk Access")
        } catch let error as BrowserHistoryStoreError {
            #expect(error.requiresFullDiskAccess)
        }
    }

    @Test func sqliteAuthorizationFailuresArePermissionErrors() {
        #expect(BrowserHistoryStore.isPermissionSQLiteCode(SQLITE_AUTH))
        #expect(BrowserHistoryStore.isPermissionSQLiteCode(SQLITE_PERM))
        #expect(BrowserHistoryStore.isPermissionSQLiteCode(SQLITE_AUTH | (3 << 8)))
        #expect(!BrowserHistoryStore.isPermissionSQLiteCode(SQLITE_BUSY))
    }

    @Test func menuPreferencesDefaultToDiaAndTenRecords() {
        let suiteName = "BrowserHistoryMenuPreferences-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(BrowserHistoryPreferences.legacyEnabledBrowsers(defaults: defaults) == nil)
        #expect(
            BrowserHistoryPreferences.menuRecordLimit(defaults: defaults)
                == BrowserHistoryPreferences.defaultMenuRecordLimit
        )

        defaults.set(
            "dia,firefox,safari",
            forKey: BrowserHistoryPreferences.legacyEnabledSourcesStorageKey
        )
        defaults.set(4, forKey: BrowserHistoryPreferences.menuRecordLimitStorageKey)
        #expect(BrowserHistoryPreferences.legacyEnabledBrowsers(defaults: defaults) == [.dia, .safari])
        #expect(BrowserHistoryPreferences.menuRecordLimit(defaults: defaults) == 4)
    }

    private func insert(
        id: Int64,
        url: String,
        title: String,
        date: Date,
        into database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO urls (id, url, title, last_visit_time) VALUES (?, ?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TestDatabaseError.sqlite
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, id)
        sqlite3_bind_text(statement, 2, url, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 4, chromiumTimestamp(for: date))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TestDatabaseError.sqlite
        }
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw TestDatabaseError.sqlite
        }
    }

    private func insertSafariItem(
        id: Int64,
        url: String,
        into database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO history_items (id, url) VALUES (?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TestDatabaseError.sqlite
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, id)
        sqlite3_bind_text(statement, 2, url, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TestDatabaseError.sqlite
        }
    }

    private func insertSafariVisit(
        id: Int64,
        itemID: Int64,
        title: String,
        date: Date,
        loadSuccessful: Bool = true,
        into database: OpaquePointer
    ) throws {
        let sql = """
        INSERT INTO history_visits
            (id, history_item, visit_time, title, load_successful, synthesized)
        VALUES (?, ?, ?, ?, ?, 0);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TestDatabaseError.sqlite
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, id)
        sqlite3_bind_int64(statement, 2, itemID)
        sqlite3_bind_double(statement, 3, date.timeIntervalSinceReferenceDate)
        sqlite3_bind_text(statement, 4, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 5, loadSuccessful ? 1 : 0)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TestDatabaseError.sqlite
        }
    }

    private func rowCount(in database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM urls;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TestDatabaseError.sqlite
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw TestDatabaseError.sqlite
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func chromiumTimestamp(for date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
    }
}

private enum TestDatabaseError: Error {
    case sqlite
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
