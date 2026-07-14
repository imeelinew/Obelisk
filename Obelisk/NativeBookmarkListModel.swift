import Foundation
import ObeliskCore

struct NativeBookmarkRowSelectionKey: Hashable, Equatable {
    var sectionOccurrence: Int
    var bookmarkId: Bookmark.ID
    var bookmarkOccurrence: Int
}

struct NativeBookmarkSelectionState: Equatable {
    var bookmarkIDs: Set<Bookmark.ID>
    var rowKeys: Set<NativeBookmarkRowSelectionKey>
    var collectionId: UUID?
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
        in items: [NativeBookmarkListItem],
        allowsCollectionSelection: Bool
    ) -> NativeBookmarkSelectionState {
        var bookmarkIDs: Set<Bookmark.ID> = []
        var rowKeys: Set<NativeBookmarkRowSelectionKey> = []
        var collectionId: UUID?

        for row in selectedRows {
            guard row >= 0, row < items.count else { continue }
            let item = items[row]
            if let bookmark = item.bookmark {
                bookmarkIDs.insert(bookmark.id)
                if let selectionKey = item.selectionKey {
                    rowKeys.insert(selectionKey)
                }
            } else if allowsCollectionSelection, selectedRows.count == 1 {
                collectionId = item.collectionId
            }
        }

        return NativeBookmarkSelectionState(
            bookmarkIDs: bookmarkIDs,
            rowKeys: rowKeys,
            collectionId: collectionId
        )
    }

    static func rowIndexes(
        for bookmarkIDs: Set<Bookmark.ID>,
        selectedRowKeys: Set<NativeBookmarkRowSelectionKey>,
        selectedCollectionId: UUID?,
        in items: [NativeBookmarkListItem]
    ) -> IndexSet {
        guard !bookmarkIDs.isEmpty else {
            guard let selectedCollectionId else { return [] }
            return IndexSet(items.enumerated().compactMap { row, item in
                item.collectionId == selectedCollectionId ? row : nil
            })
        }

        let keyedRows = items.enumerated().compactMap { row, item -> (row: Int, bookmarkId: Bookmark.ID)? in
            guard let bookmark = item.bookmark,
                  let selectionKey = item.selectionKey,
                  bookmarkIDs.contains(bookmark.id),
                  selectedRowKeys.contains(selectionKey)
            else { return nil }
            return (row, bookmark.id)
        }

        if Set(keyedRows.map(\.bookmarkId)) == bookmarkIDs {
            return IndexSet(keyedRows.map(\.row))
        }

        var chosenRowsByBookmarkId: [Bookmark.ID: (row: Int, isReference: Bool)] = [:]
        for (row, item) in items.enumerated() {
            guard let bookmark = item.bookmark, bookmarkIDs.contains(bookmark.id) else { continue }
            let candidate = (row: row, isReference: item.isReference)
            if let current = chosenRowsByBookmarkId[bookmark.id] {
                if current.isReference && !candidate.isReference {
                    chosenRowsByBookmarkId[bookmark.id] = candidate
                }
            } else {
                chosenRowsByBookmarkId[bookmark.id] = candidate
            }
        }
        return IndexSet(chosenRowsByBookmarkId.values.map(\.row))
    }
}

enum NativeBookmarkListItem: Equatable {
    case header(
        title: String,
        topSpacing: CGFloat,
        sortMode: BookmarkListSortMode?,
        collectionId: UUID?,
        sortScope: BookmarkListSortScope?
    )
    case bookmark(
        Bookmark,
        referenceIndicatorSystemImage: String?,
        selectionKey: NativeBookmarkRowSelectionKey,
        isReference: Bool
    )

    var bookmark: Bookmark? {
        if case .bookmark(let bookmark, _, _, _) = self { return bookmark }
        return nil
    }

    var selectionKey: NativeBookmarkRowSelectionKey? {
        if case .bookmark(_, _, let selectionKey, _) = self { return selectionKey }
        return nil
    }

    var isReference: Bool {
        if case .bookmark(_, _, _, let isReference) = self { return isReference }
        return false
    }

    var collectionId: UUID? {
        if case .header(_, _, _, let collectionId, _) = self { return collectionId }
        return nil
    }

    var sortScope: BookmarkListSortScope? {
        if case .header(_, _, _, _, let sortScope) = self { return sortScope }
        return nil
    }
}

extension Array where Element == BookmarkListSection {
    var flattenedItems: [NativeBookmarkListItem] {
        var items: [NativeBookmarkListItem] = []
        var hasVisibleHeader = false

        for (sectionIndex, section) in enumerated() {
            if let title = section.title {
                items.append(.header(
                    title: title,
                    topSpacing: hasVisibleHeader ? 12 : 0,
                    sortMode: section.sortMode,
                    collectionId: section.collectionId,
                    sortScope: section.sortScope
                ))
                hasVisibleHeader = true
            }
            let bookmarkOccurrenceById = Dictionary(
                grouping: section.bookmarks.indices,
                by: { section.bookmarks[$0].id }
            ).mapValues { indices in
                Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($0.element, $0.offset) })
            }
            items.append(contentsOf: section.bookmarks.indices.map { bookmarkIndex in
                let bookmark = section.bookmarks[bookmarkIndex]
                return .bookmark(
                    bookmark,
                    referenceIndicatorSystemImage: section.referenceIndicatorSystemImage,
                    selectionKey: NativeBookmarkRowSelectionKey(
                        sectionOccurrence: sectionIndex,
                        bookmarkId: bookmark.id,
                        bookmarkOccurrence: bookmarkOccurrenceById[bookmark.id]?[bookmarkIndex] ?? 0
                    ),
                    isReference: section.referenceIndicatorSystemImage != nil
                )
            })
        }
        return items
    }
}
