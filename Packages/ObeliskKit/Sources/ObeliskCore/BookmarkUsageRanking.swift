import Foundation

public enum BookmarkUsageRanking {
    public static func frecencyScore(for record: UsageRecord, now: Date = Date()) -> Double {
        let days = max(0, now.timeIntervalSince(record.lastClickedAt) / 86_400)
        return Double(record.count) * pow(0.95, days)
    }

    public static func topFrequent(
        among bookmarks: [Bookmark],
        usage: [UUID: UsageRecord],
        limit: Int,
        minCount: Int = 3,
        now: Date = Date()
    ) -> [Bookmark] {
        bookmarks.compactMap { bookmark -> (Bookmark, Double)? in
            guard let record = usage[bookmark.id], record.count >= minCount else { return nil }
            return (bookmark, frecencyScore(for: record, now: now))
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return isOrderedByName($0.0, before: $1.0)
        }
        .prefix(limit)
        .map(\.0)
    }

    public static func recentlyUsedSorted(
        among bookmarks: [Bookmark],
        usage: [UUID: UsageRecord]
    ) -> [Bookmark] {
        bookmarks.sorted { lhs, rhs in
            let lhsUsage = usage[lhs.id]
            let rhsUsage = usage[rhs.id]
            if lhsUsage?.lastClickedAt != rhsUsage?.lastClickedAt {
                return (lhsUsage?.lastClickedAt ?? .distantPast) > (rhsUsage?.lastClickedAt ?? .distantPast)
            }
            if lhsUsage?.count != rhsUsage?.count {
                return (lhsUsage?.count ?? 0) > (rhsUsage?.count ?? 0)
            }
            return isOrderedByCreation(lhs, before: rhs)
        }
    }

    public static func mostFrequentlyUsedSorted(
        among bookmarks: [Bookmark],
        usage: [UUID: UsageRecord]
    ) -> [Bookmark] {
        bookmarks.sorted { lhs, rhs in
            let lhsUsage = usage[lhs.id]
            let rhsUsage = usage[rhs.id]
            if lhsUsage?.count != rhsUsage?.count {
                return (lhsUsage?.count ?? 0) > (rhsUsage?.count ?? 0)
            }
            if lhsUsage?.lastClickedAt != rhsUsage?.lastClickedAt {
                return (lhsUsage?.lastClickedAt ?? .distantPast) > (rhsUsage?.lastClickedAt ?? .distantPast)
            }
            return isOrderedByCreation(lhs, before: rhs)
        }
    }

    public static func recent(among bookmarks: [Bookmark], limit: Int) -> [Bookmark] {
        bookmarks
            .filter { $0.createdAt > .distantPast }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
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

    private static func isOrderedByCreation(_ lhs: Bookmark, before rhs: Bookmark) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return isOrderedByName(lhs, before: rhs)
    }
}
