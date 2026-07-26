import CryptoKit
import Foundation
import GRDB
import ObeliskCore

/// Local SQLite database and the client half of the state-based sync
/// protocol. Every domain write runs in one transaction that also registers
/// the touched row in `outbox`; the sync engine uploads full row state and
/// merges remote rows back with the same per-field HLC rules the server uses.
public final class ObeliskDatabase: @unchecked Sendable {
    public static let fileName = "obelisk-sync.sqlite"
    public static let historyOutboxTable = "browser_history"
    static let historyOutboxRowID = "local-device"

    public let rootDirectory: URL
    public let fileURL: URL
    public let deviceID: UUID

    private let pool: DatabasePool

    private init(rootDirectory: URL, deviceID: UUID) throws {
        self.rootDirectory = rootDirectory
        self.fileURL = rootDirectory.appendingPathComponent(Self.fileName)
        self.deviceID = deviceID

        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirectory.path)
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        let pool = try DatabasePool(path: fileURL.path, configuration: configuration)
        self.pool = pool
        try ObeliskSchema.migrator().migrate(pool)
        try applyPrivatePermissions()
    }

    public static func open(
        rootDirectory: URL,
        deviceID: UUID
    ) throws -> ObeliskDatabase {
        let database = try ObeliskDatabase(
            rootDirectory: rootDirectory,
            deviceID: deviceID
        )
        try database.removeUnsupportedBrowserHistoryData()
        return database
    }

    // MARK: - Snapshot

    public func loadSnapshot() throws -> ObeliskLibrarySnapshot {
        try pool.read { database in
            let bookmarkRows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, collection_id, title, url, title_optimized, is_hidden,
                       archived_at, is_pinned, original_title, created_at
                FROM bookmarks
                WHERE deleted_at IS NULL
                ORDER BY position_key, id
                """
            )
            let collectionRows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, name, position_key, show_in_menu
                FROM collections
                WHERE deleted_at IS NULL
                ORDER BY position_key, id
                """
            )
            let usageRows = try Row.fetchAll(
                database,
                sql: """
                SELECT bookmark_id, COUNT(*) AS usage_count, MAX(occurred_at) AS last_clicked_at
                FROM usage_events
                GROUP BY bookmark_id
                """
            )
            let historyCutoff = Date().addingTimeInterval(
                -TimeInterval(BrowserHistoryGrouping.dayLimit) * 86_400
            )
            let browserHistoryRows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, browser, profile_name, title, url, visited_at
                FROM browser_history_events
                WHERE visited_at >= ?
                ORDER BY visited_at DESC, id DESC
                LIMIT ?
                """,
                arguments: [
                    Self.encodeDate(historyCutoff),
                    BrowserHistoryGrouping.recordLimit * 5,
                ]
            )
            let browserHistorySettingsRow = try Row.fetchOne(
                database,
                sql: """
                SELECT enabled_sources
                FROM browser_history_settings
                WHERE id = ?
                """,
                arguments: [BrowserHistorySettings.sharedID.uuidString.lowercased()]
            )

            let bookmarks = try bookmarkRows.map(Self.bookmark)
            let collections = try collectionRows.enumerated().map { index, row in
                try Self.collection(row, fallbackOrder: index)
            }
            let membership = Dictionary(
                uniqueKeysWithValues: bookmarkRows.compactMap { row -> (UUID, UUID)? in
                    guard
                        let bookmarkID = UUID(uuidString: row["id"]),
                        let rawCollectionID: String = row["collection_id"],
                        let collectionID = UUID(uuidString: rawCollectionID)
                    else {
                        return nil
                    }
                    return (bookmarkID, collectionID)
                }
            )
            let usage = try Dictionary(
                uniqueKeysWithValues: usageRows.map { row -> (UUID, UsageRecord) in
                    guard
                        let bookmarkID = UUID(uuidString: row["bookmark_id"]),
                        let rawDate: String = row["last_clicked_at"],
                        let date = Self.decodeDate(rawDate)
                    else {
                        throw ObeliskDatabaseError.invalidRow("usage_events")
                    }
                    let count: Int = row["usage_count"]
                    return (bookmarkID, UsageRecord(count: count, lastClickedAt: date))
                }
            )
            var seenHistoryURLs = Set<String>()
            let browserHistory = try browserHistoryRows.compactMap { row -> BrowserHistoryRecord? in
                let record = try Self.browserHistoryRecord(row)
                let normalizedURL = BookmarkStore.normalizedURL(record.url)
                guard seenHistoryURLs.insert(normalizedURL).inserted else { return nil }
                return record
            }
            .prefix(BrowserHistoryGrouping.recordLimit)
            let browserHistorySettings = browserHistorySettingsRow.map { row in
                BrowserHistorySettings(encodedEnabledSources: row["enabled_sources"])
            }

            return ObeliskLibrarySnapshot(
                bookmarks: bookmarks,
                collections: collections,
                collectionByBookmarkID: membership,
                usageByBookmarkID: usage,
                browserHistory: Array(browserHistory),
                browserHistorySettings: browserHistorySettings
            )
        }
    }

    // MARK: - Observation

    /// Emits after every committed transaction that touches library tables,
    /// including remote changes applied by the sync engine.
    public func libraryChanges() -> AsyncThrowingStream<Void, any Error> {
        let observation = DatabaseRegionObservation(tracking: [
            Table("bookmarks"),
            Table("collections"),
            Table("usage_events"),
            Table("browser_history_events"),
            Table("browser_history_settings"),
        ])
        let pool = pool
        return AsyncThrowingStream { continuation in
            let cancellable = observation.start(
                in: pool,
                onError: { error in continuation.finish(throwing: error) },
                onChange: { _ in continuation.yield(()) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    public func pendingUploadCounts() -> AsyncThrowingStream<Int, any Error> {
        let pool = pool
        let observation = ValueObservation
            .tracking { database in
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM outbox") ?? 0
            }
            .removeDuplicates()

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await count in observation.values(in: pool) {
                        guard !Task.isCancelled else { break }
                        continuation.yield(count)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func loadPendingUploadCount() throws -> Int {
        try pool.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM outbox") ?? 0
        }
    }

    // MARK: - Domain writes

    public func saveBookmark(_ bookmark: Bookmark, collectionID: UUID?) throws {
        let now = Date()
        try pool.write { database in
            let id = bookmark.id.uuidString.lowercased()
            let current = try Row.fetchOne(
                database,
                sql: """
                SELECT collection_id, title, url, title_optimized, is_hidden,
                       archived_at, is_pinned, original_title, position_key,
                       field_versions, deleted_at
                FROM bookmarks
                WHERE id = ?
                """,
                arguments: [id]
            )
            if let current {
                var versions = try Self.decodeVersions(current["field_versions"])
                let timestamp = try self.nextTimestamp(database, observing: Array(versions.values), now: now)
                let collection = collectionID?.uuidString.lowercased()
                let archived = bookmark.archivedAt.map(Self.encodeDate)
                var changed = false
                Self.markChange("collection_id", current["collection_id"] as String?, collection, timestamp, &versions, &changed)
                Self.markChange("title", current["title"] as String, bookmark.title, timestamp, &versions, &changed)
                Self.markChange("url", current["url"] as String, bookmark.url, timestamp, &versions, &changed)
                Self.markChange("title_optimized", current["title_optimized"] as Bool, bookmark.titleOptimized, timestamp, &versions, &changed)
                Self.markChange("is_hidden", current["is_hidden"] as Bool, bookmark.isHidden, timestamp, &versions, &changed)
                Self.markChange("archived_at", current["archived_at"] as String?, archived, timestamp, &versions, &changed)
                Self.markChange("is_pinned", current["is_pinned"] as Bool, bookmark.isPinned, timestamp, &versions, &changed)
                Self.markChange("original_title", current["original_title"] as String?, bookmark.originalTitle, timestamp, &versions, &changed)
                Self.markChange("deleted_at", current["deleted_at"] as String?, nil as String?, timestamp, &versions, &changed)
                guard changed else { return }
                try database.execute(
                    sql: """
                    UPDATE bookmarks SET
                        collection_id = ?, title = ?, url = ?, title_optimized = ?,
                        is_hidden = ?, archived_at = ?, is_pinned = ?, original_title = ?,
                        field_versions = ?, updated_at = ?, deleted_at = NULL
                    WHERE id = ?
                    """,
                    arguments: [
                        collection,
                        bookmark.title,
                        bookmark.url,
                        bookmark.titleOptimized,
                        bookmark.isHidden,
                        archived,
                        bookmark.isPinned,
                        bookmark.originalTitle,
                        try Self.encodeVersions(versions),
                        Self.encodeDate(now),
                        id,
                    ]
                )
            } else {
                let timestamp = try self.nextTimestamp(database, now: now)
                let position = Self.bookmarkPosition(bookmark)
                let versionedFields = [
                    "collection_id", "title", "url", "title_optimized", "is_hidden",
                    "archived_at", "is_pinned", "original_title", "position_key", "deleted_at",
                ]
                let versions = Dictionary(uniqueKeysWithValues: versionedFields.map { ($0, timestamp) })
                try database.execute(
                    sql: """
                    INSERT INTO bookmarks (
                        id, collection_id, title, url, title_optimized,
                        is_hidden, archived_at, is_pinned, original_title,
                        position_key, field_versions, created_at, updated_at, deleted_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    """,
                    arguments: [
                        id,
                        collectionID?.uuidString.lowercased(),
                        bookmark.title,
                        bookmark.url,
                        bookmark.titleOptimized,
                        bookmark.isHidden,
                        bookmark.archivedAt.map(Self.encodeDate),
                        bookmark.isPinned,
                        bookmark.originalTitle,
                        position,
                        try Self.encodeVersions(versions),
                        Self.encodeDate(bookmark.createdAt),
                        Self.encodeDate(now),
                    ]
                )
            }
            try Self.enqueueOutbox(database, table: "bookmarks", rowID: id, now: now)
        }
    }

    public func saveCollection(_ collection: BookmarkCollection) throws {
        let now = Date()
        try pool.write { database in
            let id = collection.id.uuidString.lowercased()
            let current = try Row.fetchOne(
                database,
                sql: """
                SELECT name, position_key, show_in_menu, field_versions, deleted_at
                FROM collections
                WHERE id = ?
                """,
                arguments: [id]
            )
            let position = Self.collectionPosition(collection.sortOrder)
            if let current {
                var versions = try Self.decodeVersions(current["field_versions"])
                let timestamp = try self.nextTimestamp(database, observing: Array(versions.values), now: now)
                var changed = false
                Self.markChange("name", current["name"] as String, collection.name, timestamp, &versions, &changed)
                Self.markChange("position_key", current["position_key"] as String, position, timestamp, &versions, &changed)
                Self.markChange("show_in_menu", current["show_in_menu"] as Bool, collection.showInMenu, timestamp, &versions, &changed)
                Self.markChange("deleted_at", current["deleted_at"] as String?, nil as String?, timestamp, &versions, &changed)
                guard changed else { return }
                try database.execute(
                    sql: """
                    UPDATE collections SET
                        name = ?, position_key = ?, show_in_menu = ?,
                        field_versions = ?, updated_at = ?, deleted_at = NULL
                    WHERE id = ?
                    """,
                    arguments: [
                        collection.name,
                        position,
                        collection.showInMenu,
                        try Self.encodeVersions(versions),
                        Self.encodeDate(now),
                        id,
                    ]
                )
            } else {
                let timestamp = try self.nextTimestamp(database, now: now)
                let versionedFields = ["name", "position_key", "show_in_menu", "deleted_at"]
                let versions = Dictionary(uniqueKeysWithValues: versionedFields.map { ($0, timestamp) })
                try database.execute(
                    sql: """
                    INSERT INTO collections (
                        id, name, position_key, show_in_menu,
                        field_versions, created_at, updated_at, deleted_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                    """,
                    arguments: [
                        id,
                        collection.name,
                        position,
                        collection.showInMenu,
                        try Self.encodeVersions(versions),
                        Self.encodeDate(now),
                        Self.encodeDate(now),
                    ]
                )
            }
            try Self.enqueueOutbox(database, table: "collections", rowID: id, now: now)
        }
    }

    public func deleteBookmark(id: UUID, at date: Date = Date()) throws {
        try pool.write { database in
            let rowID = id.uuidString.lowercased()
            guard let rawVersions = try String.fetchOne(
                database,
                sql: "SELECT field_versions FROM bookmarks WHERE id = ? AND deleted_at IS NULL",
                arguments: [rowID]
            ) else { return }
            var versions = try Self.decodeVersions(rawVersions)
            let timestamp = try self.nextTimestamp(database, observing: Array(versions.values), now: date)
            versions["deleted_at"] = timestamp
            versions["is_pinned"] = timestamp
            try database.execute(
                sql: """
                UPDATE bookmarks
                SET deleted_at = ?, updated_at = ?, is_pinned = 0, field_versions = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [
                    Self.encodeDate(date),
                    Self.encodeDate(date),
                    try Self.encodeVersions(versions),
                    rowID,
                ]
            )
            try Self.enqueueOutbox(database, table: "bookmarks", rowID: rowID, now: date)
        }
    }

    public func deleteCollection(id: UUID, at date: Date = Date()) throws {
        try pool.write { database in
            let rowID = id.uuidString.lowercased()
            guard let rawVersions = try String.fetchOne(
                database,
                sql: "SELECT field_versions FROM collections WHERE id = ? AND deleted_at IS NULL",
                arguments: [rowID]
            ) else { return }
            var versions = try Self.decodeVersions(rawVersions)
            let timestamp = try self.nextTimestamp(database, observing: Array(versions.values), now: date)
            versions["deleted_at"] = timestamp
            try database.execute(
                sql: """
                UPDATE collections
                SET deleted_at = ?, updated_at = ?, field_versions = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [
                    Self.encodeDate(date),
                    Self.encodeDate(date),
                    try Self.encodeVersions(versions),
                    rowID,
                ]
            )
            try Self.enqueueOutbox(database, table: "collections", rowID: rowID, now: date)

            let bookmarkRows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, field_versions FROM bookmarks
                WHERE collection_id = ? AND deleted_at IS NULL
                """,
                arguments: [rowID]
            )
            for row in bookmarkRows {
                var bookmarkVersions = try Self.decodeVersions(row["field_versions"])
                let bookmarkTimestamp = try self.nextTimestamp(
                    database,
                    observing: Array(bookmarkVersions.values),
                    now: date
                )
                bookmarkVersions["collection_id"] = bookmarkTimestamp
                let bookmarkID: String = row["id"]
                try database.execute(
                    sql: """
                    UPDATE bookmarks
                    SET collection_id = NULL, updated_at = ?, field_versions = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        Self.encodeDate(date),
                        try Self.encodeVersions(bookmarkVersions),
                        bookmarkID,
                    ]
                )
                try Self.enqueueOutbox(database, table: "bookmarks", rowID: bookmarkID, now: date)
            }
        }
    }

    public func setCollection(_ collectionID: UUID?, for bookmarkIDs: Set<UUID>) throws {
        guard !bookmarkIDs.isEmpty else { return }
        let now = Date()
        try pool.write { database in
            for bookmarkID in bookmarkIDs {
                let rowID = bookmarkID.uuidString.lowercased()
                guard let row = try Row.fetchOne(
                    database,
                    sql: """
                    SELECT collection_id, field_versions FROM bookmarks
                    WHERE id = ? AND deleted_at IS NULL
                    """,
                    arguments: [rowID]
                ) else { continue }
                let collection = collectionID?.uuidString.lowercased()
                let current: String? = row["collection_id"]
                guard current != collection else { continue }
                var versions = try Self.decodeVersions(row["field_versions"])
                let timestamp = try self.nextTimestamp(database, observing: Array(versions.values), now: now)
                versions["collection_id"] = timestamp
                try database.execute(
                    sql: """
                    UPDATE bookmarks
                    SET collection_id = ?, updated_at = ?, field_versions = ?
                    WHERE id = ? AND deleted_at IS NULL
                    """,
                    arguments: [
                        collection,
                        Self.encodeDate(now),
                        try Self.encodeVersions(versions),
                        rowID,
                    ]
                )
                try Self.enqueueOutbox(database, table: "bookmarks", rowID: rowID, now: now)
            }
        }
    }

    public func recordUsage(bookmarkID: UUID, at date: Date = Date()) throws {
        try pool.write { database in
            let eventID = UUID().uuidString.lowercased()
            try database.execute(
                sql: """
                INSERT INTO usage_events (
                    id, bookmark_id, device_id, occurred_at, created_at
                ) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    eventID,
                    bookmarkID.uuidString.lowercased(),
                    deviceID.uuidString.lowercased(),
                    Self.encodeDate(date),
                    Self.encodeDate(date),
                ]
            )
            try Self.enqueueOutbox(database, table: "usage_events", rowID: eventID, now: date)
        }
    }

    public func saveBrowserHistorySettings(_ settings: BrowserHistorySettings) throws {
        let now = Date()
        try pool.write { database in
            let id = BrowserHistorySettings.sharedID.uuidString.lowercased()
            let current = try Row.fetchOne(
                database,
                sql: """
                SELECT enabled_sources, field_versions
                FROM browser_history_settings
                WHERE id = ?
                """,
                arguments: [id]
            )
            let enabledSources = settings.encodedEnabledSources

            if let current {
                var versions = try Self.decodeVersions(current["field_versions"])
                let timestamp = try self.nextTimestamp(
                    database,
                    observing: Array(versions.values),
                    now: now
                )
                var changed = false
                Self.markChange(
                    "enabled_sources",
                    current["enabled_sources"] as String,
                    enabledSources,
                    timestamp,
                    &versions,
                    &changed
                )
                guard changed else { return }
                try database.execute(
                    sql: """
                    UPDATE browser_history_settings
                    SET enabled_sources = ?, field_versions = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        enabledSources,
                        try Self.encodeVersions(versions),
                        Self.encodeDate(now),
                        id,
                    ]
                )
            } else {
                let timestamp = try self.nextTimestamp(database, now: now)
                let versions = ["enabled_sources": timestamp]
                try database.execute(
                    sql: """
                    INSERT INTO browser_history_settings (
                        id, enabled_sources, field_versions, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        id,
                        enabledSources,
                        try Self.encodeVersions(versions),
                        Self.encodeDate(now),
                        Self.encodeDate(now),
                    ]
                )
            }
            try Self.enqueueOutbox(database, table: "browser_history_settings", rowID: id, now: now)
        }
    }

    // MARK: - Browser history mirror

    public func reconcileBrowserHistory(
        _ records: [BrowserHistoryRecord],
        for browsers: Set<BrowserHistoryBrowser>
    ) throws {
        guard !browsers.isEmpty else { return }

        let now = Date()
        let cutoff = now.addingTimeInterval(
            -TimeInterval(BrowserHistoryGrouping.dayLimit) * 86_400
        )
        var desiredIDs = Set<UUID>()
        let desiredRecords = records
            .filter { browsers.contains($0.browser) && $0.visitedAt >= cutoff }
            .prefix(BrowserHistoryGrouping.recordLimit)
            .compactMap { record -> (id: UUID, record: BrowserHistoryRecord)? in
                let id = browserHistoryEventID(for: record)
                guard desiredIDs.insert(id).inserted else { return nil }
                return (id: id, record: record)
            }
        let desiredIDStrings = Set(desiredIDs.map { $0.uuidString.lowercased() })
        let sourceDeviceID = deviceID.uuidString.lowercased()

        try pool.write { database in
            try database.execute(
                sql: "DELETE FROM browser_history_events WHERE visited_at < ?",
                arguments: [Self.encodeDate(cutoff)]
            )
            var changed = database.changesCount > 0

            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, browser, profile_name, title, url, visited_at
                FROM browser_history_events
                WHERE source_device_id = ?
                """,
                arguments: [sourceDeviceID]
            )
            var existing: [String: Row] = [:]
            for row in rows {
                existing[row["id"]] = row
            }

            for (id, row) in existing {
                let browserValue: String = row["browser"]
                guard
                    let browser = BrowserHistoryBrowser(rawValue: browserValue),
                    browsers.contains(browser),
                    !desiredIDStrings.contains(id)
                else { continue }
                try database.execute(
                    sql: "DELETE FROM browser_history_events WHERE id = ?",
                    arguments: [id]
                )
                changed = true
            }

            for desired in desiredRecords {
                let id = desired.id.uuidString.lowercased()
                let record = desired.record
                let visited = Self.encodeDate(record.visitedAt)
                if let row = existing[id] {
                    let matches = row["browser"] as String == record.browser.rawValue
                        && row["profile_name"] as String == record.profileName
                        && row["title"] as String == record.title
                        && row["url"] as String == record.url
                        && row["visited_at"] as String == visited
                    guard !matches else { continue }
                    try database.execute(
                        sql: """
                        UPDATE browser_history_events
                        SET browser = ?, profile_name = ?, title = ?, url = ?, visited_at = ?
                        WHERE id = ? AND source_device_id = ?
                        """,
                        arguments: [
                            record.browser.rawValue,
                            record.profileName,
                            record.title,
                            record.url,
                            visited,
                            id,
                            sourceDeviceID,
                        ]
                    )
                } else {
                    try database.execute(
                        sql: """
                        INSERT INTO browser_history_events (
                            id, source_device_id, browser, profile_name, title,
                            url, visited_at, created_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            id,
                            sourceDeviceID,
                            record.browser.rawValue,
                            record.profileName,
                            record.title,
                            record.url,
                            visited,
                            Self.encodeDate(Date()),
                        ]
                    )
                }
                changed = true
            }

            if changed {
                try Self.enqueueHistoryPush(database, now: now)
            }
        }
    }

    public func pruneBrowserHistory(before cutoff: Date) throws {
        try pool.write { database in
            try database.execute(
                sql: "DELETE FROM browser_history_events WHERE visited_at < ?",
                arguments: [Self.encodeDate(cutoff)]
            )
            if database.changesCount > 0 {
                try Self.enqueueHistoryPush(database, now: Date())
            }
        }
    }

    private func removeUnsupportedBrowserHistoryData() throws {
        try pool.write { database in
            try database.execute(
                sql: """
                DELETE FROM browser_history_events
                WHERE browser NOT IN (?, ?, ?)
                """,
                arguments: [
                    BrowserHistoryBrowser.dia.rawValue,
                    BrowserHistoryBrowser.chrome.rawValue,
                    BrowserHistoryBrowser.safari.rawValue,
                ]
            )
            if database.changesCount > 0 {
                try Self.enqueueHistoryPush(database, now: Date())
            }
        }

        let storedSources: String? = try pool.read { database in
            try String.fetchOne(
                database,
                sql: """
                SELECT enabled_sources
                FROM browser_history_settings
                WHERE id = ?
                """,
                arguments: [BrowserHistorySettings.sharedID.uuidString.lowercased()]
            )
        }
        guard let storedSources else { return }
        let normalizedSettings = BrowserHistorySettings(encodedEnabledSources: storedSources)
        guard normalizedSettings.encodedEnabledSources != storedSources else { return }
        try saveBrowserHistorySettings(normalizedSettings)
    }

    /// Rows this device owns, in the shape the reconcile endpoint expects.
    public func localHistoryRecords() throws -> [SyncHistoryRecord] {
        try pool.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, browser, profile_name, title, url, visited_at, created_at
                FROM browser_history_events
                WHERE source_device_id = ?
                ORDER BY visited_at DESC
                """,
                arguments: [deviceID.uuidString.lowercased()]
            )
            return rows.map { row in
                SyncHistoryRecord(
                    id: row["id"],
                    browser: row["browser"],
                    profileName: row["profile_name"],
                    title: row["title"],
                    url: row["url"],
                    visitedAt: row["visited_at"],
                    createdAt: row["created_at"]
                )
            }
        }
    }

    // MARK: - Outbox

    static func enqueueOutbox(_ database: Database, table: String, rowID: String, now: Date) throws {
        try database.execute(
            sql: """
            INSERT INTO outbox (table_name, row_id, queued_at, attempts, last_error)
            VALUES (?, ?, ?, 0, NULL)
            ON CONFLICT (table_name, row_id) DO UPDATE SET
                queued_at = excluded.queued_at, attempts = 0, last_error = NULL
            """,
            arguments: [table, rowID, encodeDate(now)]
        )
    }

    static func enqueueHistoryPush(_ database: Database, now: Date) throws {
        try enqueueOutbox(database, table: historyOutboxTable, rowID: historyOutboxRowID, now: now)
    }

    /// Registers every current row for upload. Used for the initial push and
    /// for recovery; with state-based merge this is always safe to repeat.
    public func enqueueFullPush() throws {
        let now = Date()
        try pool.write { database in
            for table in ["bookmarks", "collections", "usage_events", "browser_history_settings"] {
                let ids = try String.fetchAll(database, sql: "SELECT id FROM \(table)")
                for id in ids {
                    try Self.enqueueOutbox(database, table: table, rowID: id, now: now)
                }
            }
            try Self.enqueueHistoryPush(database, now: now)
        }
    }

    public func outboxBatch(limit: Int = 300, maxAttempts: Int = 5) throws -> [SyncOutboxEntry] {
        try pool.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT table_name, row_id, queued_at, attempts
                FROM outbox
                WHERE attempts < ?
                ORDER BY queued_at, table_name, row_id
                LIMIT ?
                """,
                arguments: [maxAttempts, limit]
            )
            return rows.map { row in
                SyncOutboxEntry(
                    tableName: row["table_name"],
                    rowID: row["row_id"],
                    queuedAt: row["queued_at"],
                    attempts: row["attempts"]
                )
            }
        }
    }

    /// Builds upload payloads for outbox entries. Returns `nil` for rows that
    /// no longer exist locally; those entries can be completed immediately.
    public func pushRow(for entry: SyncOutboxEntry) throws -> SyncPushRow? {
        try pool.read { database in
            switch entry.tableName {
            case "bookmarks":
                return try Self.versionedPushRow(
                    database,
                    table: "bookmarks",
                    id: entry.rowID,
                    fields: [
                        "collection_id", "title", "url", "title_optimized", "is_hidden",
                        "archived_at", "is_pinned", "original_title", "position_key", "deleted_at",
                    ]
                )
            case "collections":
                return try Self.versionedPushRow(
                    database,
                    table: "collections",
                    id: entry.rowID,
                    fields: ["name", "position_key", "show_in_menu", "deleted_at"]
                )
            case "browser_history_settings":
                return try Self.versionedPushRow(
                    database,
                    table: "browser_history_settings",
                    id: entry.rowID,
                    fields: ["enabled_sources"]
                )
            case "usage_events":
                guard let row = try Row.fetchOne(
                    database,
                    sql: """
                    SELECT bookmark_id, device_id, occurred_at, created_at
                    FROM usage_events WHERE id = ?
                    """,
                    arguments: [entry.rowID]
                ) else { return nil }
                return SyncPushRow(
                    table: "usage_events",
                    id: entry.rowID,
                    values: [
                        "bookmark_id": .string(row["bookmark_id"]),
                        "device_id": .string(row["device_id"]),
                        "occurred_at": .string(row["occurred_at"]),
                        "created_at": .string(row["created_at"]),
                    ]
                )
            default:
                return nil
            }
        }
    }

    private static func versionedPushRow(
        _ database: Database,
        table: String,
        id: String,
        fields: [String]
    ) throws -> SyncPushRow? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM \(table) WHERE id = ?",
            arguments: [id]
        ) else { return nil }
        var values: [String: SyncJSONValue] = [:]
        for field in fields {
            values[field] = jsonValue(row[field])
        }
        values["created_at"] = jsonValue(row["created_at"])
        let versions = try decodeVersions(row["field_versions"])
        return SyncPushRow(table: table, id: id, values: values, fieldVersions: versions)
    }

    private static func jsonValue(_ value: DatabaseValue) -> SyncJSONValue {
        switch value.storage {
        case .null:
            return .null
        case .int64(let integer):
            return .integer(Int(integer))
        case .string(let string):
            return .string(string)
        case .double(let double):
            return .integer(Int(double))
        case .blob:
            return .null
        }
    }

    public func completeOutboxEntries(_ entries: [SyncOutboxEntry]) throws {
        guard !entries.isEmpty else { return }
        try pool.write { database in
            for entry in entries {
                try database.execute(
                    sql: """
                    DELETE FROM outbox
                    WHERE table_name = ? AND row_id = ? AND queued_at = ?
                    """,
                    arguments: [entry.tableName, entry.rowID, entry.queuedAt]
                )
            }
        }
    }

    public func recordOutboxFailure(_ entry: SyncOutboxEntry, message: String) throws {
        try pool.write { database in
            try database.execute(
                sql: """
                UPDATE outbox
                SET attempts = attempts + 1, last_error = ?
                WHERE table_name = ? AND row_id = ? AND queued_at = ?
                """,
                arguments: [message, entry.tableName, entry.rowID, entry.queuedAt]
            )
        }
    }

    // MARK: - Remote apply

    public func syncCursor() throws -> Int64 {
        try pool.read { database in
            let raw = try String.fetchOne(
                database,
                sql: "SELECT value FROM sync_state WHERE id = 'cursor'"
            )
            return raw.flatMap(Int64.init) ?? 0
        }
    }

    public func setSyncCursor(_ cursor: Int64) throws {
        try pool.write { database in
            try database.execute(
                sql: """
                INSERT INTO sync_state (id, value) VALUES ('cursor', ?)
                ON CONFLICT (id) DO UPDATE SET value = excluded.value
                """,
                arguments: [String(cursor)]
            )
        }
    }

    public func resetSyncCursor() throws {
        try pool.write { database in
            try database.execute(sql: "DELETE FROM sync_state WHERE id = 'cursor'")
        }
    }

    /// Applies one page of remote changes in a single transaction, merging
    /// versioned rows field-by-field with the same rules the server uses.
    /// These writes never re-enter the outbox.
    public func applyRemoteChanges(_ page: SyncChangesPage) throws {
        let ownDeviceID = deviceID.uuidString.lowercased()
        try pool.write { database in
            for row in page.collections {
                try Self.applyRemoteVersionedRow(
                    database,
                    table: "collections",
                    fields: ["name", "position_key", "show_in_menu", "deleted_at"],
                    row: row
                )
            }
            for row in page.bookmarks {
                try Self.applyRemoteVersionedRow(
                    database,
                    table: "bookmarks",
                    fields: [
                        "collection_id", "title", "url", "title_optimized", "is_hidden",
                        "archived_at", "is_pinned", "original_title", "position_key", "deleted_at",
                    ],
                    row: row
                )
            }
            for row in page.browserHistorySettings {
                try Self.applyRemoteVersionedRow(
                    database,
                    table: "browser_history_settings",
                    fields: ["enabled_sources"],
                    row: row
                )
            }
            for event in page.usageEvents {
                try database.execute(
                    sql: """
                    INSERT INTO usage_events (id, bookmark_id, device_id, occurred_at, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO NOTHING
                    """,
                    arguments: [
                        event.id.lowercased(),
                        event.bookmarkID.lowercased(),
                        event.deviceID.lowercased(),
                        event.occurredAt,
                        event.createdAt,
                    ]
                )
            }
            // The local browser is the source of truth for this device's own
            // rows; only mirror rows owned by other devices.
            for event in page.browserHistoryEvents where event.sourceDeviceID.lowercased() != ownDeviceID {
                try database.execute(
                    sql: """
                    INSERT INTO browser_history_events (
                        id, source_device_id, browser, profile_name, title,
                        url, visited_at, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET
                        browser = excluded.browser,
                        profile_name = excluded.profile_name,
                        title = excluded.title,
                        url = excluded.url,
                        visited_at = excluded.visited_at
                    """,
                    arguments: [
                        event.id.lowercased(),
                        event.sourceDeviceID.lowercased(),
                        event.browser,
                        event.profileName,
                        event.title,
                        event.url,
                        event.visitedAt,
                        event.createdAt,
                    ]
                )
            }
            for id in page.browserHistoryDeletions {
                try database.execute(
                    sql: "DELETE FROM browser_history_events WHERE id = ? AND source_device_id != ?",
                    arguments: [id.lowercased(), ownDeviceID]
                )
            }
        }
    }

    private static func applyRemoteVersionedRow(
        _ database: Database,
        table: String,
        fields: [String],
        row: SyncRemoteVersionedRow
    ) throws {
        let current = try Row.fetchOne(
            database,
            sql: "SELECT * FROM \(table) WHERE id = ?",
            arguments: [row.id]
        )

        if let current {
            var versions = try decodeVersions(current["field_versions"])
            var accepted: [String: SyncJSONValue] = [:]
            for field in fields {
                guard
                    let value = row.values[field],
                    let incoming = row.fieldVersions[field]
                else { continue }
                if let existing = versions[field], !(incoming > existing) {
                    continue
                }
                accepted[field] = value
                versions[field] = incoming
            }
            guard !accepted.isEmpty else { return }

            if table == "bookmarks" {
                enforcePinInvariant(current: current, accepted: &accepted, versions: &versions)
            }

            let columns = accepted.keys.sorted()
            let sets = columns.map { "\($0) = ?" } + ["field_versions = ?", "updated_at = ?"]
            var arguments = columns.map { databaseValue(accepted[$0]!) }
            arguments.append(try encodeVersions(versions).databaseValue)
            arguments.append(encodeDate(Date()).databaseValue)
            arguments.append(row.id.databaseValue)
            try database.execute(
                sql: "UPDATE \(table) SET \(sets.joined(separator: ", ")) WHERE id = ?",
                arguments: StatementArguments(arguments)
            )
        } else {
            var accepted: [String: SyncJSONValue] = [:]
            for field in fields {
                accepted[field] = row.values[field] ?? .null
            }
            var versions = row.fieldVersions
            if table == "bookmarks" {
                enforcePinInvariant(current: nil, accepted: &accepted, versions: &versions)
            }
            let createdAt: String
            if case .string(let value)? = row.values["created_at"] {
                createdAt = value
            } else {
                createdAt = encodeDate(Date())
            }
            let columns = accepted.keys.sorted()
            let names = ["id"] + columns + ["field_versions", "created_at", "updated_at"]
            var arguments: [DatabaseValue] = [row.id.databaseValue]
            arguments.append(contentsOf: columns.map { databaseValue(accepted[$0]!) })
            arguments.append(try encodeVersions(versions).databaseValue)
            arguments.append(createdAt.databaseValue)
            arguments.append(encodeDate(Date()).databaseValue)
            let placeholders = names.map { _ in "?" }.joined(separator: ", ")
            try database.execute(
                sql: """
                INSERT INTO \(table) (\(names.joined(separator: ", ")))
                VALUES (\(placeholders))
                ON CONFLICT (id) DO NOTHING
                """,
                arguments: StatementArguments(arguments)
            )
        }
    }

    /// Hidden, archived, or deleted bookmarks cannot stay pinned. Mirrors the
    /// server rule so every replica converges on the same outcome.
    private static func enforcePinInvariant(
        current: Row?,
        accepted: inout [String: SyncJSONValue],
        versions: inout [String: LogicalTimestamp]
    ) {
        func finalValue(_ field: String) -> SyncJSONValue? {
            if let value = accepted[field] { return value }
            guard let current else { return nil }
            let value: DatabaseValue = current[field]
            return jsonValue(value)
        }
        let hidden = finalValue("is_hidden") == .integer(1) || finalValue("is_hidden") == .boolean(true)
        let archived = {
            if let value = finalValue("archived_at"), value != .null { return true }
            return false
        }()
        let deleted = {
            if let value = finalValue("deleted_at"), value != .null { return true }
            return false
        }()
        let pinned = finalValue("is_pinned") == .integer(1) || finalValue("is_pinned") == .boolean(true)
        guard pinned, hidden || archived || deleted else { return }

        var maximum = versions["is_pinned"]
        for field in ["is_hidden", "archived_at", "deleted_at"] {
            if let candidate = versions[field], maximum.map({ candidate > $0 }) ?? true {
                maximum = candidate
            }
        }
        if let maximum {
            versions["is_pinned"] = maximum
        }
        accepted["is_pinned"] = .integer(0)
    }

    private static func databaseValue(_ value: SyncJSONValue) -> DatabaseValue {
        switch value {
        case .string(let string): return string.databaseValue
        case .integer(let integer): return integer.databaseValue
        case .boolean(let boolean): return (boolean ? 1 : 0).databaseValue
        case .null: return .null
        }
    }

    // MARK: - HLC

    private func nextTimestamp(
        _ database: Database,
        observing versions: [LogicalTimestamp] = [],
        now: Date
    ) throws -> LogicalTimestamp {
        let raw: String? = try String.fetchOne(
            database,
            sql: "SELECT value FROM sync_state WHERE id = 'hlc'"
        )
        let previous = try raw.map { value in
            guard let data = value.data(using: .utf8) else {
                throw ObeliskDatabaseError.invalidRow("sync_state")
            }
            return try JSONDecoder().decode(LogicalTimestamp.self, from: data)
        }
        var clock = LogicalClock(
            deviceID: deviceID,
            lastMilliseconds: previous?.milliseconds ?? 0,
            counter: previous?.counter ?? 0
        )
        let timestamp: LogicalTimestamp
        if let remote = versions.max() {
            timestamp = clock.observe(remote, now: now)
        } else {
            timestamp = clock.tick(now: now)
        }
        let data = try JSONEncoder().encode(timestamp)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw ObeliskDatabaseError.invalidRow("sync_state")
        }
        try database.execute(
            sql: """
            INSERT INTO sync_state (id, value) VALUES ('hlc', ?)
            ON CONFLICT (id) DO UPDATE SET value = excluded.value
            """,
            arguments: [encoded]
        )
        return timestamp
    }

    private static func markChange<Value: Equatable>(
        _ field: String,
        _ current: Value,
        _ next: Value,
        _ timestamp: LogicalTimestamp,
        _ versions: inout [String: LogicalTimestamp],
        _ changed: inout Bool
    ) {
        guard current != next else { return }
        versions[field] = timestamp
        changed = true
    }

    static func decodeVersions(_ value: String) throws -> [String: LogicalTimestamp] {
        guard let data = value.data(using: .utf8) else {
            throw ObeliskDatabaseError.invalidRow("field_versions")
        }
        return try JSONDecoder().decode([String: LogicalTimestamp].self, from: data)
    }

    static func encodeVersions(_ versions: [String: LogicalTimestamp]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(versions)
        guard let value = String(data: data, encoding: .utf8) else {
            throw ObeliskDatabaseError.invalidRow("field_versions")
        }
        return value
    }

    // MARK: - Row mapping

    private static func bookmark(_ row: Row) throws -> Bookmark {
        guard
            let id = UUID(uuidString: row["id"]),
            let rawCreatedAt: String = row["created_at"],
            let createdAt = decodeDate(rawCreatedAt)
        else {
            throw ObeliskDatabaseError.invalidRow("bookmarks")
        }
        let rawArchivedAt: String? = row["archived_at"]
        return Bookmark(
            id: id,
            title: row["title"],
            url: row["url"],
            createdAt: createdAt,
            titleOptimized: row["title_optimized"],
            isHidden: row["is_hidden"],
            archivedAt: rawArchivedAt.flatMap(decodeDate),
            isPinned: row["is_pinned"],
            originalTitle: row["original_title"]
        )
    }

    private static func collection(_ row: Row, fallbackOrder: Int) throws -> BookmarkCollection {
        guard let id = UUID(uuidString: row["id"]) else {
            throw ObeliskDatabaseError.invalidRow("collections")
        }
        let position: String = row["position_key"]
        return BookmarkCollection(
            id: id,
            name: row["name"],
            sortOrder: Int(position) ?? fallbackOrder,
            showInMenu: row["show_in_menu"]
        )
    }

    private static func browserHistoryRecord(_ row: Row) throws -> BrowserHistoryRecord {
        guard
            let id = UUID(uuidString: row["id"]),
            let browser = BrowserHistoryBrowser(rawValue: row["browser"]),
            let rawVisitedAt: String = row["visited_at"],
            let visitedAt = decodeDate(rawVisitedAt)
        else {
            throw ObeliskDatabaseError.invalidRow("browser_history_events")
        }
        return BrowserHistoryRecord(
            id: id,
            title: row["title"],
            url: row["url"],
            visitedAt: visitedAt,
            browser: browser,
            profileName: row["profile_name"]
        )
    }

    private func browserHistoryEventID(for record: BrowserHistoryRecord) -> UUID {
        let material = [
            deviceID.uuidString.lowercased(),
            record.id.uuidString.lowercased(),
            Self.encodeDate(record.visitedAt),
        ].joined(separator: "|")
        var bytes = Array(SHA256.hash(data: Data(material.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func bookmarkPosition(_ bookmark: Bookmark) -> String {
        String(format: "%020lld-%@", Int64(bookmark.createdAt.timeIntervalSince1970 * 1_000), bookmark.id.uuidString.lowercased())
    }

    private static func collectionPosition(_ sortOrder: Int) -> String {
        String(format: "%020d", sortOrder)
    }

    static func encodeDate(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon))
    }

    static func decodeDate(_ value: String) -> Date? {
        try? Date(value, strategy: .iso8601)
    }

    private func applyPrivatePermissions() throws {
        for path in [fileURL.path, fileURL.path + "-wal", fileURL.path + "-shm"]
        where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
}

public enum ObeliskDatabaseError: LocalizedError {
    case invalidRow(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRow(let table):
            "Invalid row in \(table)"
        }
    }
}
