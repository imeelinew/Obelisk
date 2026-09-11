import Foundation
import GRDB
import ObeliskCore

/// Local SQLite database and the client half of the state-based sync
/// protocol. Every domain write runs in one transaction that also registers
/// the touched row in `outbox`; the sync engine uploads full row state and
/// merges remote rows back with the same per-field HLC rules the server uses.
public final class ObeliskDatabase: @unchecked Sendable {
    public static let fileName = "obelisk-sync.sqlite"

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
        try ObeliskDatabase(
            rootDirectory: rootDirectory,
            deviceID: deviceID
        )
    }

    // MARK: - Snapshot

    public func loadSnapshot() throws -> ObeliskLibrarySnapshot {
        try pool.read { database in
            let bookmarkRows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, collection_id, title, url, title_optimization_state, is_hidden,
                       archived_at, original_title, created_at
                FROM bookmarks
                WHERE deleted_at IS NULL
                ORDER BY position_key, id
                """
            )
            let collectionRows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, name, position_key
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
            return ObeliskLibrarySnapshot(
                bookmarks: bookmarks,
                collections: collections,
                collectionByBookmarkID: membership,
                usageByBookmarkID: usage
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
                SELECT collection_id, title, url, title_optimization_state, is_hidden,
                       archived_at, original_title, position_key,
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
                Self.markChange(
                    "title_optimization_state",
                    current["title_optimization_state"] as String,
                    bookmark.titleOptimizationState.rawValue,
                    timestamp,
                    &versions,
                    &changed
                )
                Self.markChange("is_hidden", current["is_hidden"] as Bool, bookmark.isHidden, timestamp, &versions, &changed)
                Self.markChange("archived_at", current["archived_at"] as String?, archived, timestamp, &versions, &changed)
                Self.markChange("original_title", current["original_title"] as String?, bookmark.originalTitle, timestamp, &versions, &changed)
                Self.markChange("deleted_at", current["deleted_at"] as String?, nil as String?, timestamp, &versions, &changed)
                guard changed else { return }
                try database.execute(
                    sql: """
                    UPDATE bookmarks SET
                        collection_id = ?, title = ?, url = ?, title_optimization_state = ?,
                        is_hidden = ?, archived_at = ?, original_title = ?,
                        field_versions = ?, updated_at = ?, deleted_at = NULL
                    WHERE id = ?
                    """,
                    arguments: [
                        collection,
                        bookmark.title,
                        bookmark.url,
                        bookmark.titleOptimizationState.rawValue,
                        bookmark.isHidden,
                        archived,
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
                    "collection_id", "title", "url", "title_optimization_state", "is_hidden",
                    "archived_at", "original_title", "position_key", "deleted_at",
                ]
                let versions = Dictionary(uniqueKeysWithValues: versionedFields.map { ($0, timestamp) })
                try database.execute(
                    sql: """
                    INSERT INTO bookmarks (
                        id, collection_id, title, url, title_optimization_state,
                        is_hidden, archived_at, original_title,
                        position_key, field_versions, created_at, updated_at, deleted_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    """,
                    arguments: [
                        id,
                        collectionID?.uuidString.lowercased(),
                        bookmark.title,
                        bookmark.url,
                        bookmark.titleOptimizationState.rawValue,
                        bookmark.isHidden,
                        bookmark.archivedAt.map(Self.encodeDate),
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
                SELECT name, position_key, field_versions, deleted_at
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
                Self.markChange("deleted_at", current["deleted_at"] as String?, nil as String?, timestamp, &versions, &changed)
                guard changed else { return }
                try database.execute(
                    sql: """
                    UPDATE collections SET
                        name = ?, position_key = ?,
                        field_versions = ?, updated_at = ?, deleted_at = NULL
                    WHERE id = ?
                    """,
                    arguments: [
                        collection.name,
                        position,
                        try Self.encodeVersions(versions),
                        Self.encodeDate(now),
                        id,
                    ]
                )
            } else {
                let timestamp = try self.nextTimestamp(database, now: now)
                let versionedFields = ["name", "position_key", "deleted_at"]
                let versions = Dictionary(uniqueKeysWithValues: versionedFields.map { ($0, timestamp) })
                try database.execute(
                    sql: """
                    INSERT INTO collections (
                        id, name, position_key,
                        field_versions, created_at, updated_at, deleted_at
                    ) VALUES (?, ?, ?, ?, ?, ?, NULL)
                    """,
                    arguments: [
                        id,
                        collection.name,
                        position,
                        try Self.encodeVersions(versions),
                        Self.encodeDate(now),
                        Self.encodeDate(now),
                    ]
                )
            }
            try Self.enqueueOutbox(database, table: "collections", rowID: id, now: now)
        }
    }

    public func reorderCollections(_ orderedIDs: [UUID]) throws {
        let now = Date()
        try pool.write { database in
            let activeIDs = try String.fetchAll(
                database,
                sql: "SELECT id FROM collections WHERE deleted_at IS NULL ORDER BY position_key, id"
            )
            let normalizedIDs = orderedIDs.map { $0.uuidString.lowercased() }
            guard Set(activeIDs) == Set(normalizedIDs), activeIDs.count == normalizedIDs.count else {
                throw ObeliskDatabaseError.invalidRow("collections")
            }
            for (index, id) in normalizedIDs.enumerated() {
                guard let row = try Row.fetchOne(
                    database,
                    sql: "SELECT position_key, field_versions FROM collections WHERE id = ?",
                    arguments: [id]
                ) else { continue }
                let position = Self.collectionPosition(index)
                let currentPosition: String = row["position_key"]
                guard currentPosition != position else { continue }
                var versions = try Self.decodeVersions(row["field_versions"])
                let timestamp = try self.nextTimestamp(database, observing: Array(versions.values), now: now)
                versions["position_key"] = timestamp
                try database.execute(
                    sql: """
                    UPDATE collections
                    SET position_key = ?, field_versions = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [position, try Self.encodeVersions(versions), Self.encodeDate(now), id]
                )
                try Self.enqueueOutbox(database, table: "collections", rowID: id, now: now)
            }
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
            try database.execute(
                sql: """
                UPDATE bookmarks
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

    /// Registers every current row for upload. Used for the initial push and
    /// for recovery; with state-based merge this is always safe to repeat.
    public func enqueueFullPush() throws {
        let now = Date()
        try pool.write { database in
            for table in ["bookmarks", "collections", "usage_events"] {
                let ids = try String.fetchAll(database, sql: "SELECT id FROM \(table)")
                for id in ids {
                    try Self.enqueueOutbox(database, table: table, rowID: id, now: now)
                }
            }
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
                        "collection_id", "title", "url", "title_optimization_state", "is_hidden",
                        "archived_at", "original_title", "position_key", "deleted_at",
                    ]
                )
            case "collections":
                return try Self.versionedPushRow(
                    database,
                    table: "collections",
                    id: entry.rowID,
                    fields: ["name", "position_key", "deleted_at"]
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
        try pool.write { database in
            for row in page.collections {
                try Self.applyRemoteVersionedRow(
                    database,
                    table: "collections",
                    fields: ["name", "position_key", "deleted_at"],
                    row: row
                )
            }
            for row in page.bookmarks {
                try Self.applyRemoteVersionedRow(
                    database,
                    table: "bookmarks",
                    fields: [
                        "collection_id", "title", "url", "title_optimization_state", "is_hidden",
                        "archived_at", "original_title", "position_key", "deleted_at",
                    ],
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
            let versions = row.fieldVersions
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
        let rawOptimizationState: String = row["title_optimization_state"]
        guard let optimizationState = TitleOptimizationState(rawValue: rawOptimizationState) else {
            throw ObeliskDatabaseError.invalidRow("bookmarks")
        }
        return Bookmark(
            id: id,
            title: row["title"],
            url: row["url"],
            createdAt: createdAt,
            titleOptimizationState: optimizationState,
            isHidden: row["is_hidden"],
            archivedAt: rawArchivedAt.flatMap(decodeDate),
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
            sortOrder: Int(position) ?? fallbackOrder
        )
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
