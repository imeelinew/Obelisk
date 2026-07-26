import Foundation
import GRDB

/// Local SQLite schema. Plain GRDB tables; synchronization state lives in
/// `sync_state` (HLC clock, pull cursor) and `outbox` (rows waiting for
/// upload, one entry per row, coalesced on rewrite).
public enum ObeliskSchema {
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("2026-07-sync-rewrite") { database in
            let legacy = try LegacyPowerSyncData.extract(database)
            try LegacyPowerSyncData.dropLegacyObjects(database)
            try createTables(database)
            try legacy?.insert(into: database)
        }
        return migrator
    }

    private static func createTables(_ database: Database) throws {
        try database.execute(sql: """
        CREATE TABLE sync_state (
            id TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );

        CREATE TABLE outbox (
            table_name TEXT NOT NULL,
            row_id TEXT NOT NULL,
            queued_at TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            PRIMARY KEY (table_name, row_id)
        );

        CREATE TABLE collections (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            position_key TEXT NOT NULL,
            show_in_menu INTEGER NOT NULL,
            field_versions TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            deleted_at TEXT
        );
        CREATE INDEX collections_active_position
            ON collections (deleted_at, position_key);

        CREATE TABLE bookmarks (
            id TEXT PRIMARY KEY NOT NULL,
            collection_id TEXT,
            title TEXT NOT NULL,
            url TEXT NOT NULL,
            title_optimized INTEGER NOT NULL,
            is_hidden INTEGER NOT NULL,
            archived_at TEXT,
            is_pinned INTEGER NOT NULL,
            original_title TEXT,
            position_key TEXT NOT NULL,
            field_versions TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            deleted_at TEXT
        );
        CREATE INDEX bookmarks_active_position
            ON bookmarks (deleted_at, position_key);
        CREATE INDEX bookmarks_collection
            ON bookmarks (collection_id);

        CREATE TABLE usage_events (
            id TEXT PRIMARY KEY NOT NULL,
            bookmark_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            occurred_at TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE INDEX usage_events_bookmark
            ON usage_events (bookmark_id, occurred_at DESC);

        CREATE TABLE browser_history_events (
            id TEXT PRIMARY KEY NOT NULL,
            source_device_id TEXT NOT NULL,
            browser TEXT NOT NULL,
            profile_name TEXT NOT NULL,
            title TEXT NOT NULL,
            url TEXT NOT NULL,
            visited_at TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE INDEX browser_history_events_visited
            ON browser_history_events (visited_at DESC);
        CREATE INDEX browser_history_events_device
            ON browser_history_events (source_device_id);

        CREATE TABLE browser_history_settings (
            id TEXT PRIMARY KEY NOT NULL,
            enabled_sources TEXT NOT NULL,
            field_versions TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        """)
    }
}

/// One-time takeover of databases written by the retired PowerSync stack.
/// Domain rows live in `ps_data__<table>` as JSON blobs; the extension also
/// left views and triggers behind. Data is copied out, every `ps_*` object is
/// dropped, and the sync queue (`ps_crud`) is intentionally discarded: the
/// state-based protocol re-uploads current rows on the next full push.
struct LegacyPowerSyncData {
    var collections: [[String: DatabaseValue]]
    var bookmarks: [[String: DatabaseValue]]
    var usageEvents: [[String: DatabaseValue]]
    var browserHistoryEvents: [[String: DatabaseValue]]
    var browserHistorySettings: [[String: DatabaseValue]]
    var hlcState: String?

    static func extract(_ database: Database) throws -> LegacyPowerSyncData? {
        guard try tableExists(database, "ps_data__bookmarks") else {
            return nil
        }

        func rows(_ table: String, fields: [String]) throws -> [[String: DatabaseValue]] {
            let selections = fields
                .map { "json_extract(data, '$.\($0)') AS \($0)" }
                .joined(separator: ", ")
            let fetched = try Row.fetchAll(
                database,
                sql: "SELECT id, \(selections) FROM \(table)"
            )
            return fetched.map { row in
                var values: [String: DatabaseValue] = ["id": row["id"]]
                for field in fields {
                    values[field] = row[field]
                }
                return values
            }
        }

        let hlc: String? = try tableExists(database, "ps_data_local__sync_state")
            ? String.fetchOne(
                database,
                sql: """
                SELECT json_extract(data, '$.value')
                FROM ps_data_local__sync_state
                WHERE id = 'hlc'
                """
            )
            : nil

        return LegacyPowerSyncData(
            collections: try rows("ps_data__collections", fields: [
                "name", "position_key", "show_in_menu",
                "field_versions", "created_at", "updated_at", "deleted_at",
            ]),
            bookmarks: try rows("ps_data__bookmarks", fields: [
                "collection_id", "title", "url", "title_optimized", "is_hidden",
                "archived_at", "is_pinned", "original_title", "position_key",
                "field_versions", "created_at", "updated_at", "deleted_at",
            ]),
            usageEvents: try rows("ps_data__usage_events", fields: [
                "bookmark_id", "device_id", "occurred_at", "created_at",
            ]),
            browserHistoryEvents: try rows("ps_data__browser_history_events", fields: [
                "source_device_id", "browser", "profile_name", "title",
                "url", "visited_at", "created_at",
            ]),
            browserHistorySettings: try rows("ps_data__browser_history_settings", fields: [
                "enabled_sources", "field_versions", "created_at", "updated_at",
            ]),
            hlcState: hlc
        )
    }

    static func dropLegacyObjects(_ database: Database) throws {
        let objects = try Row.fetchAll(
            database,
            sql: """
            SELECT type, name FROM sqlite_master
            WHERE name LIKE 'ps\\_%' ESCAPE '\\'
               OR name LIKE 'powersync%'
               OR (type = 'view' AND name IN (
                    'collections', 'bookmarks', 'usage_events',
                    'browser_history_events', 'browser_history_settings', 'sync_state'
               ))
            """
        )
        // Triggers first: they reference functions from the removed extension.
        let order = ["trigger": 0, "view": 1, "table": 2, "index": 3]
        for row in objects.sorted(by: { order[$0["type"], default: 4] < order[$1["type"], default: 4] }) {
            let type: String = row["type"]
            let name: String = row["name"]
            guard name != "sqlite_sequence", ["trigger", "view", "table", "index"].contains(type) else {
                continue
            }
            try database.execute(sql: "DROP \(type.uppercased()) IF EXISTS \"\(name)\"")
        }
    }

    func insert(into database: Database) throws {
        func insertRows(_ rows: [[String: DatabaseValue]], into table: String) throws {
            for values in rows {
                let columns = values.keys.sorted()
                let placeholders = columns.map { _ in "?" }.joined(separator: ", ")
                try database.execute(
                    sql: """
                    INSERT OR IGNORE INTO \(table) (\(columns.joined(separator: ", ")))
                    VALUES (\(placeholders))
                    """,
                    arguments: StatementArguments(columns.map { values[$0] })
                )
            }
        }
        try insertRows(collections, into: "collections")
        try insertRows(bookmarks, into: "bookmarks")
        try insertRows(usageEvents, into: "usage_events")
        try insertRows(browserHistoryEvents, into: "browser_history_events")
        try insertRows(browserHistorySettings, into: "browser_history_settings")
        if let hlcState {
            try database.execute(
                sql: "INSERT INTO sync_state (id, value) VALUES ('hlc', ?)",
                arguments: [hlcState]
            )
        }
    }

    private static func tableExists(_ database: Database, _ name: String) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            arguments: [name]
        ) ?? false
    }
}
