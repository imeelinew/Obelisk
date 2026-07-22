import Foundation
import ObeliskCore

struct BookmarkGridSection: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let bookmarks: [Bookmark]
    var collectionId: UUID? = nil

    static func dateSections(from bookmarks: [Bookmark], calendar: Calendar = .current) -> [BookmarkGridSection] {
        let sorted = bookmarks.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        let grouped = Dictionary(grouping: sorted) { bookmark -> Date? in
            guard bookmark.createdAt > .distantPast else { return nil }
            return calendar.startOfDay(for: bookmark.createdAt)
        }

        let datedSections = grouped.keys.compactMap { $0 }.sorted(by: >).compactMap { day -> BookmarkGridSection? in
            guard let bookmarks = grouped[day], !bookmarks.isEmpty else { return nil }
            return BookmarkGridSection(
                id: "day-\(day.timeIntervalSinceReferenceDate)",
                title: title(for: day, calendar: calendar),
                subtitle: bookmarkCountSubtitle(bookmarks.count),
                bookmarks: bookmarks
            )
        }

        let unknownBookmarks = grouped[nil] ?? []
        guard !unknownBookmarks.isEmpty else { return datedSections }
        return datedSections + [
            BookmarkGridSection(
                id: "unknown",
                title: "未知日期".obeliskLocalized,
                subtitle: bookmarkCountSubtitle(unknownBookmarks.count),
                bookmarks: unknownBookmarks
            )
        ]
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        let now = Date()
        if calendar.isDateInToday(day) {
            return "今天".obeliskLocalized
        }
        if calendar.isDateInYesterday(day) {
            return "昨天".obeliskLocalized
        }

        let formatter = DateFormatter()
        formatter.locale = .current
        if calendar.component(.year, from: day) == calendar.component(.year, from: now) {
            formatter.setLocalizedDateFormatFromTemplate("MMMdEEE")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("yMMMdEEE")
        }
        return formatter.string(from: day)
    }
}
