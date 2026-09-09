import Foundation
import GRDB
import Testing
@testable import ObeliskData

struct HistoryRemovalMigrationTests {
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
        let tables = ["bookmarks", "collections", "usage_events", "sync_state"]
        let before = try db.read { db throws in
            try tables.map { try Row.fetchAll(db, sql: "SELECT * FROM \($0)") }
        }
        let queued = try db.read { db throws in
            try Row.fetchAll(db, sql: """
                SELECT * FROM outbox WHERE table_name IN ('bookmarks', 'collections', 'usage_events')
                ORDER BY table_name
                """)
        }
        try migrator.migrate(db)
        try migrator.migrate(db) // Reopening must be harmless
        try db.read { db throws in
            for (index, table) in tables.enumerated() {
                #expect(try Row.fetchAll(db, sql: "SELECT * FROM \(table)") == before[index])
            }
            #expect(try Row.fetchAll(db, sql: "SELECT * FROM outbox ORDER BY table_name") == queued)
            #expect(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master WHERE name GLOB 'browser_history*'
                """) == 0)
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
