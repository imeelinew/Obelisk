import Foundation
import os

public struct UsageRecord: Codable, Equatable {
    public var count: Int
    public var lastClickedAt: Date

    public init(count: Int, lastClickedAt: Date) {
        self.count = count
        self.lastClickedAt = lastClickedAt
    }
}

private let usageLog = Logger(subsystem: "local.elidev.Obelisk", category: "UsageStore")

/// Tracks per-bookmark click usage in a sidecar file (`usage.json`).
///
/// Frequency score uses a simple time-decay formula:
/// `score = count * 0.95 ^ daysSinceLastClick`
/// — a bookmark clicked once every ~14 days roughly holds its score.
public final class UsageStore {
    public private(set) var rootDirectory: URL
    public var fileURL: URL {
        ObeliskPrivateStorage.activeFileURL(rootDirectory: rootDirectory, logicalName: "usage.json")
    }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let secureCodec: SecureJSONFileCodec
    private var cachedUsage: [UUID: UsageRecord]?

    public init(rootDirectory: URL = BookmarkStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
        self.secureCodec = SecureJSONFileCodec()

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func updateRootDirectory(_ rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        invalidateCache()
    }

    public func invalidateCache() {
        cachedUsage = nil
    }

    public func load() -> [UUID: UsageRecord] {
        if let cachedUsage {
            return cachedUsage
        }

        let url = ObeliskPrivateStorage.existingReadableFileURL(
            rootDirectory: rootDirectory,
            logicalName: "usage.json"
        )
        guard
            let data = try? secureCodec.readData(
                from: url,
                coordinated: ICloudDocumentSync.shouldCoordinateAccess(for: rootDirectory)
            ),
            let raw = try? decoder.decode([String: UsageRecord].self, from: data)
        else {
            cachedUsage = [:]
            return [:]
        }

        var result: [UUID: UsageRecord] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key) {
                result[id] = value
            }
        }
        cachedUsage = result
        return result
    }

    public func record(id: UUID, at date: Date = Date()) {
        var dict = load()
        let prior = dict[id]
        dict[id] = UsageRecord(
            count: (prior?.count ?? 0) + 1,
            lastClickedAt: date
        )
        save(dict)
    }

    public func record(for id: UUID) -> UsageRecord? {
        load()[id]
    }

    /// Drop entries whose bookmark has been deleted.
    public func cleanup(validIds: Set<UUID>) {
        let dict = load()
        let pruned = dict.filter { validIds.contains($0.key) }
        if pruned.count != dict.count {
            save(pruned)
        }
    }

    /// Top-N most-frecent bookmarks. Bookmarks below `minCount` are excluded
    /// so a brand-new install doesn't show "frequently used" items the user
    /// has only clicked once.
    public func topFrequent(
        among bookmarks: [Bookmark],
        limit: Int,
        minCount: Int = 3,
        now: Date = Date()
    ) -> [Bookmark] {
        topFrequent(among: bookmarks, usage: load(), limit: limit, minCount: minCount, now: now)
    }

    public func topFrequent(
        among bookmarks: [Bookmark],
        usage: [UUID: UsageRecord],
        limit: Int,
        minCount: Int = 3,
        now: Date = Date()
    ) -> [Bookmark] {
        let scored: [(bookmark: Bookmark, score: Double)] = bookmarks.compactMap { bm in
            guard let record = usage[bm.id], record.count >= minCount else {
                return nil
            }
            let days = max(0, now.timeIntervalSince(record.lastClickedAt) / 86_400)
            let score = Double(record.count) * pow(0.95, days)
            return (bm, score)
        }
        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0.bookmark }
    }

    /// Most recently created bookmarks (skip ones with `.distantPast`, which
    /// means they predate the createdAt field).
    public func recent(
        among bookmarks: [Bookmark],
        limit: Int
    ) -> [Bookmark] {
        bookmarks
            .filter { $0.createdAt > .distantPast }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    private func save(_ dict: [UUID: UsageRecord]) {
        saveAll(dict)
    }

    public func saveAll(_ dict: [UUID: UsageRecord]) {
        cachedUsage = dict
        let payload = Dictionary(uniqueKeysWithValues: dict.map { ($0.key.uuidString, $0.value) })
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(payload)
            try secureCodec.writeData(
                data,
                to: fileURL,
                encrypted: LocalJSONEncryption.isEnabled,
                coordinated: ICloudDocumentSync.shouldCoordinateAccess(for: rootDirectory)
            )
            for staleURL in ObeliskPrivateStorage.inactiveFileURLs(rootDirectory: rootDirectory, logicalName: "usage.json") {
                try? CoordinatedFileAccess.removeItem(
                    at: staleURL,
                    coordinated: ICloudDocumentSync.shouldCoordinateAccess(for: rootDirectory)
                )
            }
        } catch {
            usageLog.error("Failed to persist usage data: \(error.localizedDescription)")
        }
    }
}
