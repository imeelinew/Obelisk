import Foundation
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

    @Test func unfinishedBrowsersRemainVisibleButAreNotQueried() throws {
        #expect(BrowserHistoryBrowser.firefox.optionTitle == "Firefox（尚未完成）")
        #expect(BrowserHistoryBrowser.safari.optionTitle == "Safari（尚未完成）")
        #expect(!BrowserHistoryBrowser.firefox.isImplemented)
        #expect(!BrowserHistoryBrowser.safari.isImplemented)

        #expect(throws: BrowserHistoryStoreError.self) {
            _ = try BrowserHistoryStore(browsers: [.firefox, .safari]).loadRecentSections()
        }
    }

    @Test func menuPreferencesDefaultToDiaAndTenRecords() {
        let suiteName = "BrowserHistoryMenuPreferences-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(BrowserHistoryPreferences.enabledBrowsers(defaults: defaults) == [.dia])
        #expect(
            BrowserHistoryPreferences.menuRecordLimit(defaults: defaults)
                == BrowserHistoryPreferences.defaultMenuRecordLimit
        )

        defaults.set("dia,firefox", forKey: BrowserHistoryPreferences.enabledSourcesStorageKey)
        defaults.set(4, forKey: BrowserHistoryPreferences.menuRecordLimitStorageKey)
        #expect(BrowserHistoryPreferences.enabledBrowsers(defaults: defaults) == [.dia])
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
