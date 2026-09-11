import Foundation
import GRDB
import Testing
@testable import ObeliskData

struct HistoryRemovalMigrationTests {
    @Test func presentationMigrationReusesCommonAndPreservesAllBookmarkKinds() throws {
        let db = try DatabaseQueue()
        let migrator = ObeliskSchema.migrator()
        try migrator.migrate(db, upTo: "2026-09-remove-browser-history")
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO collections VALUES
                    ('common', '常用', '5', 0, '{}', 'created', 'updated', NULL),
                    ('other', 'Other', '9', 1, '{}', 'created', 'updated', NULL);
                INSERT INTO bookmarks VALUES
                    ('hidden', 'other', 'Hidden', 'https://hidden.example', 0, 1, NULL, 1, NULL, '1', '{}', 'created', 'updated', NULL),
                    ('archived', 'other', 'Archived', 'https://archived.example', 0, 0, 'archived', 1, NULL, '2', '{}', 'created', 'updated', NULL),
                    ('deleted', 'other', 'Deleted', 'https://deleted.example', 0, 0, NULL, 1, NULL, '3', '{}', 'created', 'updated', 'deleted'),
                    ('optimized', NULL, 'Optimized', 'https://optimized.example', 1, 0, NULL, 0, 'Original', '4', '{}', 'created', 'updated', NULL);
                """)
        }

        try migrator.migrate(db)

        try db.read { db throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collections") == 2)
            #expect(try String.fetchOne(db, sql: "SELECT id FROM collections ORDER BY position_key LIMIT 1") == "common")
            #expect(try String.fetchOne(db, sql: "SELECT collection_id FROM bookmarks WHERE id = 'hidden'") == "common")
            #expect(try String.fetchOne(db, sql: "SELECT collection_id FROM bookmarks WHERE id = 'archived'") == "common")
            #expect(try String.fetchOne(db, sql: "SELECT collection_id FROM bookmarks WHERE id = 'deleted'") == "other")
            #expect(try String.fetchOne(db, sql: "SELECT title_optimization_state FROM bookmarks WHERE id = 'optimized'") == "succeeded")
            #expect(try String.fetchOne(db, sql: "SELECT title_optimization_state FROM bookmarks WHERE id = 'hidden'") == "not_attempted")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmarks") == 4)
        }
    }

    @Test func upgradePreservesRowsOutboxAndSyncState() throws {
        let db = try DatabaseQueue()
        let migrator = ObeliskSchema.migrator()
        try migrator.migrate(db, upTo: "2026-07-sync-rewrite")
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE browser_history_events (id TEXT PRIMARY KEY, title TEXT);
                CREATE INDEX browser_history_events_visited ON browser_history_events(title);
                CREATE TABLE browser_history_settings (id TEXT PRIMARY KEY, enabled_sources TEXT);
                INSERT INTO browser_history_events VALUES ('visit', 'Discard me');
                INSERT INTO browser_history_settings VALUES ('settings', 'safari');
                INSERT INTO collections VALUES ('collection', 'Reading', '1', 1, '{}', 'created', 'updated', NULL);
                INSERT INTO bookmarks VALUES (
                    'bookmark', 'collection', 'Kept', 'https://example.com', 0, 0, NULL,
                    0, NULL, '1', '{}', 'created', 'updated', 'deleted'
                );
                INSERT INTO usage_events VALUES ('usage', 'bookmark', 'device', 'occurred', 'created');
                INSERT INTO sync_state VALUES ('cursor', '9876'), ('hlc', 'preserved-clock');
                INSERT INTO outbox VALUES
                    ('bookmarks', 'bookmark', 'queued', 3, 'retry'),
                    ('collections', 'collection', 'queued', 0, NULL),
                    ('usage_events', 'usage', 'queued', 1, 'retry'),
                    ('browser_history', 'local-device', 'queued', 0, NULL),
                    ('browser_history_settings', 'settings', 'queued', 5, 'rejected');
                """)
        }
        try migrator.migrate(db)
        try migrator.migrate(db) // Reopening must be harmless
        try db.read { db throws in
            #expect(try String.fetchOne(db, sql: "SELECT title FROM bookmarks") == "Kept")
            #expect(try String.fetchOne(db, sql: "SELECT title_optimization_state FROM bookmarks") == "not_attempted")
            #expect(try String.fetchOne(db, sql: "SELECT name FROM collections") == "Reading")
            #expect(try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE id = 'cursor'") == "9876")
            #expect(try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE id = 'hlc'") == "preserved-clock")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_events") == 1)
            let queuedKeys = try String.fetchAll(
                db,
                sql: "SELECT table_name || ':' || row_id FROM outbox ORDER BY table_name"
            )
            #expect(queuedKeys == ["bookmarks:bookmark", "collections:collection", "usage_events:usage"])
            #expect(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master WHERE name GLOB 'browser_history*'
                """) == 0)
            let bookmarkColumns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('bookmarks')")
            #expect(!bookmarkColumns.contains("is_pinned"))
            #expect(!bookmarkColumns.contains("title_optimized"))
            let collectionColumns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('collections')")
            #expect(!collectionColumns.contains("show_in_menu"))
        }
    }

    @Test func freshDatabaseHasOnlyCurrentDomainTables() throws {
        let db = try DatabaseQueue()
        try ObeliskSchema.migrator().migrate(db)
        try db.read { db throws in
            #expect(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master WHERE name GLOB 'browser_history*'
                """) == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox") == 0)
        }
    }
}
