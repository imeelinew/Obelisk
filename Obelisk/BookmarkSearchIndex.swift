import Foundation

enum BookmarkSearchMatcher {
    static func matches(bookmark: Bookmark, query: String) -> Bool {
        BookmarkSearchIndex(bookmarks: [bookmark]).matches(bookmarkID: bookmark.id, query: query)
    }

    fileprivate static func searchableStrings(for bookmark: Bookmark) -> [String] {
        var values = [bookmark.title, bookmark.url]
        if let originalTitle = bookmark.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !originalTitle.isEmpty,
           originalTitle != bookmark.title {
            values.append(originalTitle)
        }
        return values
    }

    fileprivate static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    fileprivate static func pinyin(_ value: String) -> String {
        let latin = (value as NSString).applyingTransform(.toLatin, reverse: false) ?? value
        return normalized((latin as NSString).applyingTransform(.stripDiacritics, reverse: false) ?? latin)
    }

    fileprivate static func collapsed(_ value: String) -> String {
        value.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    fileprivate static func initials(from value: String) -> String {
        value
            .split { !$0.isLetter && !$0.isNumber }
            .compactMap(\.first)
            .map(String.init)
            .joined()
    }
}

struct BookmarkSearchIndex {
    private struct PreparedValue {
        let normalized: String
        let pinyin: String
        let collapsedPinyin: String
        let initials: String
    }

    private let valuesByBookmarkID: [Bookmark.ID: [PreparedValue]]

    init(bookmarks: [Bookmark]) {
        valuesByBookmarkID = Dictionary(uniqueKeysWithValues: bookmarks.map { bookmark in
            let values = BookmarkSearchMatcher.searchableStrings(for: bookmark).compactMap { value -> PreparedValue? in
                let normalized = BookmarkSearchMatcher.normalized(value)
                guard !normalized.isEmpty else { return nil }
                let pinyin = BookmarkSearchMatcher.pinyin(normalized)
                return PreparedValue(
                    normalized: normalized,
                    pinyin: pinyin,
                    collapsedPinyin: BookmarkSearchMatcher.collapsed(pinyin),
                    initials: BookmarkSearchMatcher.initials(from: pinyin)
                )
            }
            return (bookmark.id, values)
        })
    }

    func matchingIDs(query: String) -> Set<Bookmark.ID> {
        let preparedQuery = PreparedQuery(query)
        guard !preparedQuery.normalized.isEmpty else {
            return Set(valuesByBookmarkID.keys)
        }
        return Set(valuesByBookmarkID.compactMap { bookmarkID, values in
            values.contains { preparedQuery.matches($0) } ? bookmarkID : nil
        })
    }

    func matches(bookmarkID: Bookmark.ID, query: String) -> Bool {
        let preparedQuery = PreparedQuery(query)
        guard !preparedQuery.normalized.isEmpty else { return true }
        return valuesByBookmarkID[bookmarkID]?.contains { preparedQuery.matches($0) } == true
    }

    private struct PreparedQuery {
        let normalized: String
        let collapsed: String

        init(_ query: String) {
            normalized = BookmarkSearchMatcher.normalized(query)
            collapsed = BookmarkSearchMatcher.collapsed(normalized)
        }

        func matches(_ value: PreparedValue) -> Bool {
            value.normalized.contains(normalized)
                || value.pinyin.contains(normalized)
                || value.collapsedPinyin.contains(collapsed)
                || value.initials.contains(collapsed)
        }
    }
}
