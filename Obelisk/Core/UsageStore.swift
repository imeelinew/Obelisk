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

private let usageLog = Logger(subsystem: "com.eli.Obelisk", category: "UsageStore")

/// Tracks per-bookmark click usage inside the encrypted vault payload.
///
/// Frequency score uses a simple time-decay formula:
/// `score = count * 0.95 ^ daysSinceLastClick`
/// — a bookmark clicked once every ~14 days roughly holds its score.
public final class UsageStore {
    public private(set) var rootDirectory: URL
    public var fileURL: URL {
        ObeliskVaultStore(rootDirectory: rootDirectory).payloadURL
    }

    private var vaultStore: ObeliskVaultStore
    private var cachedUsage: [UUID: UsageRecord]?

    public init(rootDirectory: URL = BookmarkStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
        self.vaultStore = ObeliskVaultStore(rootDirectory: rootDirectory)
    }

    public func updateRootDirectory(_ rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        vaultStore = ObeliskVaultStore(rootDirectory: rootDirectory)
        invalidateCache()
    }

    public func invalidateCache() {
        cachedUsage = nil
    }

    public func load() -> [UUID: UsageRecord] {
        if let cachedUsage {
            return cachedUsage
        }

        guard let payload = try? vaultStore.loadPayload() else {
            cachedUsage = [:]
            return [:]
        }
        let result = Self.usage(from: payload)
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

    public static func frecencyScore(for record: UsageRecord, now: Date = Date()) -> Double {
        let days = max(0, now.timeIntervalSince(record.lastClickedAt) / 86_400)
        return Double(record.count) * pow(0.95, days)
    }

    public func frecencySorted(among bookmarks: [Bookmark], now: Date = Date()) -> [Bookmark] {
        Self.frecencySorted(among: bookmarks, usage: load(), now: now)
    }

    public static func frecencySorted(
        among bookmarks: [Bookmark],
        usage: [UUID: UsageRecord],
        now: Date = Date()
    ) -> [Bookmark] {
        bookmarks.sorted { lhs, rhs in
            let lhsScore = usage[lhs.id].map { frecencyScore(for: $0, now: now) } ?? 0
            let rhsScore = usage[rhs.id].map { frecencyScore(for: $0, now: now) } ?? 0

            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }

            return isOrderedByName(lhs, before: rhs)
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
            return (bm, Self.frecencyScore(for: record, now: now))
        }
        return scored
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return Self.isOrderedByName($0.bookmark, before: $1.bookmark)
            }
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
        do {
            try ObeliskRootDirectoryLock.withExclusiveAccess(rootDirectory: rootDirectory) {
                var payload = try vaultStore.loadPayload()
                payload.bookmarks = payload.bookmarks.map { bookmark in
                    var bookmark = bookmark
                    bookmark.usage = dict[bookmark.id]
                    return bookmark
                }
                try vaultStore.savePayload(payload)
                cachedUsage = Self.usage(from: payload)
            }
        } catch {
            usageLog.error("Failed to persist usage data: \(error.localizedDescription)")
        }
    }

    private static func usage(from payload: ObeliskVaultPayload) -> [UUID: UsageRecord] {
        Dictionary(
            uniqueKeysWithValues: payload.bookmarks.compactMap { bookmark in
                guard let usage = bookmark.usage else { return nil }
                return (bookmark.id, usage)
            }
        )
    }

    private static func isOrderedByName(_ lhs: Bookmark, before rhs: Bookmark) -> Bool {
        let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }

        let urlComparison = lhs.url.localizedStandardCompare(rhs.url)
        if urlComparison != .orderedSame {
            return urlComparison == .orderedAscending
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }
}
