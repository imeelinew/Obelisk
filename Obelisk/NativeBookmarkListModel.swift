import Foundation
import ObeliskCore

struct NativeBookmarkSelectionState: Equatable {
    var bookmarkIDs: Set<Bookmark.ID>
}

enum NativeBookmarkSelectionResolver {
    static func firstBookmarkRowIndex(in items: [NativeBookmarkListItem]) -> Int? {
        items.firstIndex { $0.bookmark != nil }
    }

    static func nextBookmarkRowIndex(after row: Int, in items: [NativeBookmarkListItem]) -> Int? {
        let startRow = max(row + 1, 0)
        guard startRow < items.count else { return nil }
        return items.indices[startRow...].first { items[$0].bookmark != nil }
    }

    static func selection(
        from selectedRows: IndexSet,
        in items: [NativeBookmarkListItem]
    ) -> NativeBookmarkSelectionState {
        var bookmarkIDs: Set<Bookmark.ID> = []

        for row in selectedRows {
            guard row >= 0, row < items.count else { continue }
            let item = items[row]
            if let bookmark = item.bookmark {
                bookmarkIDs.insert(bookmark.id)
            }
        }

        return NativeBookmarkSelectionState(bookmarkIDs: bookmarkIDs)
    }

    static func rowIndexes(
        for bookmarkIDs: Set<Bookmark.ID>,
        in items: [NativeBookmarkListItem]
    ) -> IndexSet {
        IndexSet(items.enumerated().compactMap { row, item in
            guard let bookmark = item.bookmark, bookmarkIDs.contains(bookmark.id) else { return nil }
            return row
        })
    }
}

enum NativeBookmarkListItem: Equatable {
    case header(
        title: String,
        topSpacing: CGFloat
    )
    case bookmark(Bookmark)

    var bookmark: Bookmark? {
        if case .bookmark(let bookmark) = self { return bookmark }
        return nil
    }
}

extension Array where Element == BookmarkListSection {
    var flattenedItems: [NativeBookmarkListItem] {
        var items: [NativeBookmarkListItem] = []
        var hasVisibleHeader = false

        for section in self {
            if let title = section.title {
                items.append(.header(
                    title: title,
                    topSpacing: hasVisibleHeader ? 12 : 0
                ))
                hasVisibleHeader = true
            }
            items.append(contentsOf: section.bookmarks.map(NativeBookmarkListItem.bookmark))
        }
        return items
    }
}
