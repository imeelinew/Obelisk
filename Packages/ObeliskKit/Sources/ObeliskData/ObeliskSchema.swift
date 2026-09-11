import Foundation
import GRDB
import ObeliskCore

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
        migrator.registerMigration("2026-09-remove-browser-history") { database in
            try database.execute(sql: """
                DELETE FROM outbox
                WHERE table_name IN (
                    'browser_history', 'browser_history_events',
                    'browser_history_settings', 'browser_history_tombstones'
                );
                DROP TABLE IF EXISTS browser_history_events;
                DROP TABLE IF EXISTS browser_history_settings;
                DROP TABLE IF EXISTS browser_history_tombstones;
                """)
        }
        migrator.registerMigration("2026-09-unify-bookmark-presentation") { database in
            try migrateUnifiedBookmarkPresentation(database)
        }
        return migrator
    }

    private static let commonCollectionID = "65b1a579-07c4-4f0c-97ee-3dd4af479cc3"
    private static let migrationDate = "2026-09-11T07:43:51.000Z"
    private static let migrationTimestamp = LogicalTimestamp(
        milliseconds: 1_789_112_631_000,
        counter: 0,
        deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    )

    private static func migrateUnifiedBookmarkPresentation(_ database: Database) throws {
        let hasPinnedBookmarks = try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM bookmarks WHERE is_pinned = 1 AND deleted_at IS NULL)"
        ) ?? false
        let existingCommonID = try String.fetchOne(
            database,
            sql: """
            SELECT id FROM collections
            WHERE deleted_at IS NULL AND name = ? COLLATE NOCASE
            ORDER BY created_at, id
            LIMIT 1
            """,
            arguments: ["常用"]
        )
        let commonID = existingCommonID ?? commonCollectionID

        if hasPinnedBookmarks, existingCommonID == nil {
            let versions = try ObeliskDatabase.encodeVersions([
                "name": migrationTimestamp,
                "position_key": migrationTimestamp,
                "show_in_menu": migrationTimestamp,
                "deleted_at": migrationTimestamp,
            ])
            try database.execute(
                sql: """
                INSERT INTO collections (
                    id, name, position_key, show_in_menu, field_versions,
                    created_at, updated_at, deleted_at
                ) VALUES (?, ?, ?, 0, ?, ?, ?, NULL)
                """,
                arguments: [
                    commonID,
                    "常用",
                    collectionPosition(0),
                    versions,
                    migrationDate,
                    migrationDate,
                ]
            )
        }

        let collectionRows = try Row.fetchAll(
            database,
            sql: "SELECT * FROM collections ORDER BY position_key, id"
        )
        let activeIDs = collectionRows.compactMap { row -> String? in
            let deletedAt: String? = row["deleted_at"]
            return deletedAt == nil ? row["id"] : nil
        }
        let orderedActiveIDs = hasPinnedBookmarks || existingCommonID != nil
            ? [commonID] + activeIDs.filter { $0 != commonID }
            : activeIDs
        let activePositions = Dictionary(
            uniqueKeysWithValues: orderedActiveIDs.enumerated().map { ($0.element, collectionPosition($0.offset)) }
        )

        try database.execute(sql: """
            CREATE TABLE collections_next (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                position_key TEXT NOT NULL,
                field_versions TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                deleted_at TEXT
            )
            """)
        for row in collectionRows {
            let id: String = row["id"]
            let oldPosition: String = row["position_key"]
            let position = activePositions[id] ?? oldPosition
            var versions = try ObeliskDatabase.decodeVersions(row["field_versions"])
            versions.removeValue(forKey: "show_in_menu")
            if position != oldPosition {
                versions["position_key"] = max(versions["position_key"] ?? migrationTimestamp, migrationTimestamp)
            }
            try database.execute(
                sql: """
                INSERT INTO collections_next (
                    id, name, position_key, field_versions, created_at, updated_at, deleted_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    id,
                    row["name"] as String,
                    position,
                    try ObeliskDatabase.encodeVersions(versions),
                    row["created_at"] as String,
                    row["updated_at"] as String,
                    row["deleted_at"] as String?,
                ]
            )
        }

        let bookmarkRows = try Row.fetchAll(database, sql: "SELECT * FROM bookmarks")
        try database.execute(sql: """
            CREATE TABLE bookmarks_next (
                id TEXT PRIMARY KEY NOT NULL,
                collection_id TEXT,
                title TEXT NOT NULL,
                url TEXT NOT NULL,
                title_optimization_state TEXT NOT NULL,
                is_hidden INTEGER NOT NULL,
                archived_at TEXT,
                original_title TEXT,
                position_key TEXT NOT NULL,
                field_versions TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                deleted_at TEXT
            )
            """)
        for row in bookmarkRows {
            let wasPinned: Bool = row["is_pinned"]
            let deletedAt: String? = row["deleted_at"]
            let shouldMigratePin = wasPinned && deletedAt == nil
            let wasOptimized: Bool = row["title_optimized"]
            var versions = try ObeliskDatabase.decodeVersions(row["field_versions"])
            versions["title_optimization_state"] = versions["title_optimized"] ?? migrationTimestamp
            versions.removeValue(forKey: "title_optimized")
            if shouldMigratePin {
                versions["collection_id"] = max(
                    versions["collection_id"] ?? migrationTimestamp,
                    versions["is_pinned"] ?? migrationTimestamp
                )
            }
            versions.removeValue(forKey: "is_pinned")
            let oldCollectionID: String? = row["collection_id"]
            try database.execute(
                sql: """
                INSERT INTO bookmarks_next (
                    id, collection_id, title, url, title_optimization_state,
                    is_hidden, archived_at, original_title, position_key,
                    field_versions, created_at, updated_at, deleted_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    row["id"] as String,
                    shouldMigratePin ? commonID : oldCollectionID,
                    row["title"] as String,
                    row["url"] as String,
                    wasOptimized ? TitleOptimizationState.succeeded.rawValue : TitleOptimizationState.notAttempted.rawValue,
                    row["is_hidden"] as Bool,
                    row["archived_at"] as String?,
                    row["original_title"] as String?,
                    row["position_key"] as String,
                    try ObeliskDatabase.encodeVersions(versions),
                    row["created_at"] as String,
                    row["updated_at"] as String,
                    deletedAt,
                ]
            )
        }

        try database.execute(sql: """
            DROP TABLE bookmarks;
            ALTER TABLE bookmarks_next RENAME TO bookmarks;
            CREATE INDEX bookmarks_active_position ON bookmarks (deleted_at, position_key);
            CREATE INDEX bookmarks_collection ON bookmarks (collection_id);
            DROP TABLE collections;
            ALTER TABLE collections_next RENAME TO collections;
            CREATE INDEX collections_active_position ON collections (deleted_at, position_key);
            """)

        for table in ["bookmarks", "collections"] {
            let ids = try String.fetchAll(database, sql: "SELECT id FROM \(table)")
            for id in ids {
                try ObeliskDatabase.enqueueOutbox(
                    database,
                    table: table,
                    rowID: id,
                    now: Date(timeIntervalSince1970: 1_789_112_631)
                )
            }
        }
    }

    private static func collectionPosition(_ sortOrder: Int) -> String {
        String(format: "%020d", sortOrder)
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
