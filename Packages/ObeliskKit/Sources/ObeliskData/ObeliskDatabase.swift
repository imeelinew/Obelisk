import CryptoKit
import Foundation
import GRDB
import ObeliskCore
import PowerSync
import PowerSyncGRDB

public final class ObeliskDatabase: @unchecked Sendable {
    public static let fileName = "obelisk-sync.sqlite"

    public let rootDirectory: URL
    public let fileURL: URL
    public let deviceID: UUID
    public let powerSync: any PowerSyncDatabaseProtocol

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
        try configuration.configurePowerSync(schema: ObeliskSchema.current)
        let pool = try DatabasePool(path: fileURL.path, configuration: configuration)
        self.pool = pool
        self.powerSync = openPowerSyncWithGRDB(
            pool: pool,
            schema: ObeliskSchema.current,
            identifier: fileURL.path
        )
        try applyPrivatePermissions()
    }

    public static func open(
        rootDirectory: URL,
        deviceID: UUID
    ) async throws -> ObeliskDatabase {
        let database = try ObeliskDatabase(
            rootDirectory: rootDirectory,
            deviceID: deviceID
        )
        _ = try await database.powerSync.getPowerSyncVersion()
        return database
    }

    public func bindToCloudAccount(_ accountID: UUID) throws {
        try bind(to: accountID)
    }

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

    public func libraryChanges() -> AsyncThrowingStream<Void, any Error> {
        let pool = pool
        let observation = ValueObservation
            .tracking { database in
                try String.fetchAll(
                    database,
                    sql: """
                    SELECT 'bookmark:' || id || ':' || updated_at FROM bookmarks
                    UNION ALL
                    SELECT 'collection:' || id || ':' || updated_at FROM collections
                    UNION ALL
                    SELECT 'usage:' || id || ':' || occurred_at FROM usage_events
                    UNION ALL
                    SELECT 'history:' || id || ':' || visited_at FROM browser_history_events
                    UNION ALL
                    SELECT 'history-settings:' || id || ':' || updated_at FROM browser_history_settings
                    """
                )
            }
            .removeDuplicates()

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await _ in observation.values(in: pool) {
                        guard !Task.isCancelled else { break }
                        continuation.yield(())
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

    public func pendingUploadCounts() -> AsyncThrowingStream<Int, any Error> {
        let pool = pool
        let observation = ValueObservation
            .tracking { database in
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM ps_crud") ?? 0
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
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM ps_crud") ?? 0
        }
    }

    public func saveBookmark(_ bookmark: Bookmark, collectionID: UUID?) throws {
        let now = Date()
        try writeMutation { database in
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
            let mutationID = UUID().uuidString.lowercased()
            if let current {
                var versions = try Self.decodeVersions(current["field_versions"])
                let timestamp = try nextTimestamp(database, observing: Array(versions.values), now: now)
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
                        field_versions = ?, updated_at = ?, deleted_at = NULL, _metadata = ?
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
                        mutationID,
                        id,
                    ]
                )
            } else {
                let timestamp = try nextTimestamp(database, now: now)
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
                        position_key, field_versions, created_at, updated_at, deleted_at, _metadata
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
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
                        mutationID,
                    ]
                )
            }
        }
    }

    public func saveCollection(_ collection: BookmarkCollection) throws {
        let now = Date()
        try writeMutation { database in
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
            let mutationID = UUID().uuidString.lowercased()
            let position = Self.collectionPosition(collection.sortOrder)
            if let current {
                var versions = try Self.decodeVersions(current["field_versions"])
                let timestamp = try nextTimestamp(database, observing: Array(versions.values), now: now)
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
                        field_versions = ?, updated_at = ?, deleted_at = NULL, _metadata = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        collection.name,
                        position,
                        collection.showInMenu,
                        try Self.encodeVersions(versions),
                        Self.encodeDate(now),
                        mutationID,
                        id,
                    ]
                )
            } else {
                let timestamp = try nextTimestamp(database, now: now)
                let versionedFields = ["name", "position_key", "show_in_menu", "deleted_at"]
                let versions = Dictionary(uniqueKeysWithValues: versionedFields.map { ($0, timestamp) })
                try database.execute(
                    sql: """
                    INSERT INTO collections (
                        id, name, position_key, show_in_menu,
                        field_versions, created_at, updated_at, deleted_at, _metadata
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?)
                    """,
                    arguments: [
                        id,
                        collection.name,
                        position,
                        collection.showInMenu,
                        try Self.encodeVersions(versions),
                        Self.encodeDate(now),
                        Self.encodeDate(now),
                        mutationID,
                    ]
                )
            }
        }
    }

    public func deleteBookmark(id: UUID, at date: Date = Date()) throws {
        try writeMutation { database in
            guard let rawVersions = try String.fetchOne(
                database,
                sql: "SELECT field_versions FROM bookmarks WHERE id = ? AND deleted_at IS NULL",
                arguments: [id.uuidString.lowercased()]
            ) else { return }
            var versions = try Self.decodeVersions(rawVersions)
            let timestamp = try nextTimestamp(database, observing: Array(versions.values), now: date)
            versions["deleted_at"] = timestamp
            versions["is_pinned"] = timestamp
            try database.execute(
                sql: """
                UPDATE bookmarks
                SET deleted_at = ?, updated_at = ?, is_pinned = 0,
                    field_versions = ?, _metadata = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [
                    Self.encodeDate(date),
                    Self.encodeDate(date),
                    try Self.encodeVersions(versions),
                    UUID().uuidString.lowercased(),
                    id.uuidString.lowercased(),
                ]
            )
        }
    }

    public func deleteCollection(id: UUID, at date: Date = Date()) throws {
        try writeMutation { database in
            guard let rawVersions = try String.fetchOne(
                database,
                sql: "SELECT field_versions FROM collections WHERE id = ? AND deleted_at IS NULL",
                arguments: [id.uuidString.lowercased()]
            ) else { return }
            var versions = try Self.decodeVersions(rawVersions)
            let timestamp = try nextTimestamp(database, observing: Array(versions.values), now: date)
            versions["deleted_at"] = timestamp
            try database.execute(
                sql: """
                UPDATE collections
                SET deleted_at = ?, updated_at = ?, field_versions = ?, _metadata = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [
                    Self.encodeDate(date),
                    Self.encodeDate(date),
                    try Self.encodeVersions(versions),
                    UUID().uuidString.lowercased(),
                    id.uuidString.lowercased(),
                ]
            )
            let bookmarkRows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, field_versions FROM bookmarks
                WHERE collection_id = ? AND deleted_at IS NULL
                """,
                arguments: [id.uuidString.lowercased()]
            )
            for row in bookmarkRows {
                var bookmarkVersions = try Self.decodeVersions(row["field_versions"])
                let bookmarkTimestamp = try nextTimestamp(
                    database,
                    observing: Array(bookmarkVersions.values),
                    now: date
                )
                bookmarkVersions["collection_id"] = bookmarkTimestamp
                try database.execute(
                    sql: """
                    UPDATE bookmarks
                    SET collection_id = NULL, updated_at = ?, field_versions = ?, _metadata = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        Self.encodeDate(date),
                        try Self.encodeVersions(bookmarkVersions),
                        UUID().uuidString.lowercased(),
                        row["id"] as String,
                    ]
                )
            }
        }
    }

    public func setCollection(_ collectionID: UUID?, for bookmarkIDs: Set<UUID>) throws {
        guard !bookmarkIDs.isEmpty else { return }
        let now = Date()
        try writeMutation { database in
            for bookmarkID in bookmarkIDs {
                guard let row = try Row.fetchOne(
                    database,
                    sql: """
                    SELECT collection_id, field_versions FROM bookmarks
                    WHERE id = ? AND deleted_at IS NULL
                    """,
                    arguments: [bookmarkID.uuidString.lowercased()]
                ) else { continue }
                let collection = collectionID?.uuidString.lowercased()
                let current: String? = row["collection_id"]
                guard current != collection else { continue }
                var versions = try Self.decodeVersions(row["field_versions"])
                let timestamp = try nextTimestamp(database, observing: Array(versions.values), now: now)
                versions["collection_id"] = timestamp
                try database.execute(
                    sql: """
                    UPDATE bookmarks
                    SET collection_id = ?, updated_at = ?, field_versions = ?, _metadata = ?
                    WHERE id = ? AND deleted_at IS NULL
                    """,
                    arguments: [
                        collection,
                        Self.encodeDate(now),
                        try Self.encodeVersions(versions),
                        UUID().uuidString.lowercased(),
                        bookmarkID.uuidString.lowercased(),
                    ]
                )
            }
        }
    }

    public func recordUsage(bookmarkID: UUID, at date: Date = Date()) throws {
        try writeMutation { database in
            let eventID = UUID().uuidString.lowercased()
            try database.execute(
                sql: """
                INSERT INTO usage_events (
                    id, bookmark_id, device_id, occurred_at, created_at, _metadata
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    eventID,
                    bookmarkID.uuidString.lowercased(),
                    deviceID.uuidString.lowercased(),
                    Self.encodeDate(date),
                    Self.encodeDate(date),
                    eventID,
                ]
            )
        }
    }

    public func saveBrowserHistorySettings(_ settings: BrowserHistorySettings) throws {
        let now = Date()
        try writeMutation { database in
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
            let mutationID = UUID().uuidString.lowercased()

            if let current {
                var versions = try Self.decodeVersions(current["field_versions"])
                let timestamp = try nextTimestamp(
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
                    SET enabled_sources = ?, field_versions = ?, updated_at = ?, _metadata = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        enabledSources,
                        try Self.encodeVersions(versions),
                        Self.encodeDate(now),
                        mutationID,
                        id,
                    ]
                )
            } else {
                let timestamp = try nextTimestamp(database, now: now)
                let versions = ["enabled_sources": timestamp]
                try database.execute(
                    sql: """
                    INSERT INTO browser_history_settings (
                        id, enabled_sources, field_versions, created_at, updated_at, _metadata
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        id,
                        enabledSources,
                        try Self.encodeVersions(versions),
                        Self.encodeDate(now),
                        Self.encodeDate(now),
                        mutationID,
                    ]
                )
            }
        }
    }

    public func saveBrowserHistory(_ records: [BrowserHistoryRecord]) throws {
        let cutoff = Date().addingTimeInterval(
            -TimeInterval(BrowserHistoryGrouping.dayLimit) * 86_400
        )
        try pruneBrowserHistory(before: cutoff)
        let existingIDs = try pool.read { database in
            Set(try String.fetchAll(database, sql: "SELECT id FROM browser_history_events"))
        }
        var candidateIDs = Set<UUID>()
        let candidates = records
            .filter { $0.visitedAt >= cutoff }
            .prefix(BrowserHistoryGrouping.recordLimit)
            .compactMap { record -> (id: UUID, record: BrowserHistoryRecord)? in
                let id = browserHistoryEventID(for: record)
                guard
                    !existingIDs.contains(id.uuidString.lowercased()),
                    candidateIDs.insert(id).inserted
                else {
                    return nil
                }
                return (id: id, record: record)
            }

        for offset in stride(from: 0, to: candidates.count, by: 400) {
            let end = min(offset + 400, candidates.count)
            let batch = candidates[offset..<end]
            try writeMutation { database in
                for candidate in batch {
                    let record = candidate.record
                    try database.execute(
                        sql: """
                        INSERT OR IGNORE INTO browser_history_events (
                            id, source_device_id, browser, profile_name, title,
                            url, visited_at, created_at, _metadata
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            candidate.id.uuidString.lowercased(),
                            deviceID.uuidString.lowercased(),
                            record.browser.rawValue,
                            record.profileName,
                            record.title,
                            record.url,
                            Self.encodeDate(record.visitedAt),
                            Self.encodeDate(Date()),
                            UUID().uuidString.lowercased(),
                        ]
                    )
                }
            }
        }
    }

    public func pruneBrowserHistory(before cutoff: Date) throws {
        let ids = try pool.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT id FROM browser_history_events WHERE visited_at < ?",
                arguments: [Self.encodeDate(cutoff)]
            )
        }
        for offset in stride(from: 0, to: ids.count, by: 400) {
            let end = min(offset + 400, ids.count)
            let batch = ids[offset..<end]
            try writeMutation { database in
                for id in batch {
                    try database.execute(
                        sql: "UPDATE browser_history_events SET _metadata = ? WHERE id = ?",
                        arguments: [UUID().uuidString.lowercased(), id]
                    )
                    try database.execute(
                        sql: "DELETE FROM browser_history_events WHERE id = ?",
                        arguments: [id]
                    )
                }
            }
        }
    }

    private func writeMutation(_ updates: (Database) throws -> Void) throws {
        try pool.write { database in
            let previousQueueID = try Int64.fetchOne(
                database,
                sql: "SELECT IFNULL(MAX(id), 0) FROM ps_crud"
            ) ?? 0
            try updates(database)
            let currentQueueID = try Int64.fetchOne(
                database,
                sql: "SELECT IFNULL(MAX(id), 0) FROM ps_crud"
            ) ?? 0
            if currentQueueID != previousQueueID {
                try database.notifyChanges(in: Table("ps_crud"))
            }
        }
    }

    private func bind(to accountID: UUID) throws {
        let account = accountID.uuidString.lowercased()
        try pool.write { database in
            let existing: String? = try String.fetchOne(
                database,
                sql: "SELECT value FROM sync_state WHERE id = 'account_id'"
            )
            if let existing {
                guard existing == account else {
                    throw ObeliskDatabaseError.accountMismatch
                }
                return
            }
            try database.execute(
                sql: "INSERT INTO sync_state(id, value) VALUES ('account_id', ?)",
                arguments: [account]
            )
        }
    }

    private func applyPrivatePermissions() throws {
        for path in [fileURL.path, fileURL.path + "-wal", fileURL.path + "-shm"]
        where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

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
        if raw == nil {
            try database.execute(
                sql: "INSERT INTO sync_state(id, value) VALUES ('hlc', ?)",
                arguments: [encoded]
            )
        } else {
            try database.execute(
                sql: "UPDATE sync_state SET value = ? WHERE id = 'hlc'",
                arguments: [encoded]
            )
        }
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

    private static func decodeVersions(_ value: String) throws -> [String: LogicalTimestamp] {
        guard let data = value.data(using: .utf8) else {
            throw ObeliskDatabaseError.invalidRow("field_versions")
        }
        return try JSONDecoder().decode([String: LogicalTimestamp].self, from: data)
    }

    private static func encodeVersions(_ versions: [String: LogicalTimestamp]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(versions)
        guard let value = String(data: data, encoding: .utf8) else {
            throw ObeliskDatabaseError.invalidRow("field_versions")
        }
        return value
    }

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

    private static func encodeDate(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon))
    }

    private static func decodeDate(_ value: String) -> Date? {
        try? Date(value, strategy: .iso8601)
    }
}

public enum ObeliskDatabaseError: LocalizedError {
    case invalidRow(String)
    case accountMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidRow(let table):
            "Invalid row in \(table)"
        case .accountMismatch:
            "This local database belongs to another Obelisk account"
        }
    }
}
