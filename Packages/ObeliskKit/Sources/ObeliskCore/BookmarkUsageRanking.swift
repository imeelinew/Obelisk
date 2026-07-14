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

    public static func frecencySorted(
        among bookmarks: [Bookmark],
        usage: [UUID: UsageRecord],
        now: Date = Date()
    ) -> [Bookmark] {
        bookmarks.sorted { lhs, rhs in
            let lhsScore = usage[lhs.id].map { frecencyScore(for: $0, now: now) } ?? 0
            let rhsScore = usage[rhs.id].map { frecencyScore(for: $0, now: now) } ?? 0
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return isOrderedByName(lhs, before: rhs)
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
}
