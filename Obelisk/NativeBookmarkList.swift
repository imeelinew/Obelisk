import AppKit
import SwiftUI

struct BookmarkCollectionAssignOption: Equatable {
    var title: String
    var collectionId: UUID?
}

enum BookmarkListSortScope: String, Equatable {
    case pinned
    case ungrouped
}

struct BookmarkListSection: Equatable, Identifiable {
    var title: String?
    var bookmarks: [Bookmark]
    var sortMode: BookmarkListSortMode?
    var referenceIndicatorSystemImage: String? = nil
    /// When set, the section header sort control updates only this scope's preference.
    var sortScope: BookmarkListSortScope? = nil
    /// Set on the collections page so section headers can offer rename/delete.
    var collectionId: UUID?

    var id: String {
        if let collectionId {
            return collectionId.uuidString
        }
        return title ?? bookmarks.map(\.id.uuidString).joined(separator: ",")
    }
}

struct BookmarkListView: View {
    var sections: [BookmarkListSection]
    @Binding var selection: Set<Bookmark.ID>
    var selectedCollectionId: Binding<UUID?>?
    var faviconLoader: FaviconLoader
    var faviconVersion: Int
    var showsURLHostOnly: Bool = false
    var onOpen: ((Bookmark) -> Void)?
    var onCopyURL: ((Bookmark) -> Void)?
    var onRefreshFavicon: ((Bookmark) -> Void)?
    var onEdit: ((Bookmark) -> Void)?
    var onDelete: ((Set<Bookmark.ID>) -> Void)?
    var hiddenStateActionTitle: String?
    var onSetHidden: ((Bookmark) -> Void)?
    var archiveStateActionTitle: String? = nil
    var onSetArchived: ((Bookmark) -> Void)? = nil
    var pinStateActionTitle: ((Bookmark) -> String)? = nil
    var onSetPinned: ((Bookmark) -> Void)? = nil
    var onSortModeChange: ((BookmarkListSortMode, BookmarkListSortScope?) -> Void)? = nil
    var collectionAssignOptions: [BookmarkCollectionAssignOption] = []
    var onAssignCollection: ((Set<Bookmark.ID>, UUID?) -> Void)? = nil
    var onRenameCollection: ((UUID) -> Void)? = nil
    var onDeleteCollection: ((UUID) -> Void)? = nil
    var onRevertTitleOptimization: ((Set<Bookmark.ID>) -> Void)? = nil

    @State private var rowSelection: Set<BookmarkListRowID> = []
    @FocusState private var isListFocused: Bool

    private var items: [BookmarkListItem] {
        sections.flattenedItems
    }

    var body: some View {
        List(selection: $rowSelection) {
            ForEach(items) { item in
                row(for: item)
                    .tag(item.id)
                    .selectionDisabled(!isSelectable(item))
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .focusable()
        .focused($isListFocused)
        .contextMenu(forSelectionType: BookmarkListRowID.self) { rowIDs in
            contextMenu(for: rowIDs)
        } primaryAction: { rowIDs in
            if let bookmark = singleSelectedBookmark(in: rowIDs) {
                onOpen?(bookmark)
            }
        }
        .onDeleteCommand {
            guard isListFocused, !selection.isEmpty else { return }
            onDelete?(selection)
        }
        .background(keyboardShortcuts)
        .onAppear {
            syncRowSelectionFromExternal()
        }
        .onChange(of: items) { _, _ in
            syncRowSelectionFromExternal()
        }
        .onChange(of: selection) { _, _ in
            syncRowSelectionFromExternal()
        }
        .onChange(of: selectedCollectionId?.wrappedValue) { _, _ in
            syncRowSelectionFromExternal()
        }
        .onChange(of: rowSelection) { _, newValue in
            syncExternalSelection(from: newValue)
        }
    }

    @ViewBuilder
    private func row(for item: BookmarkListItem) -> some View {
        switch item {
        case .header(let title, let topSpacing, let sortMode, _, let sortScope, _):
            BookmarkListHeaderRow(
                title: title,
                topSpacing: topSpacing,
                sortMode: sortMode,
                sortScope: sortScope,
                onSortModeChange: onSortModeChange
            )
            .contentShape(Rectangle())
        case .bookmark(let bookmark, let referenceIndicatorSystemImage, _, _, _):
            BookmarkListBookmarkRow(
                bookmark: bookmark,
                faviconLoader: faviconLoader,
                faviconVersion: faviconVersion,
                showsURLHostOnly: showsURLHostOnly,
                referenceIndicatorSystemImage: referenceIndicatorSystemImage
            )
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func contextMenu(for rowIDs: Set<BookmarkListRowID>) -> some View {
        let context = BookmarkListContext(rowIDs: rowIDs, items: items)
        if let collectionId = context.collectionId {
            collectionMenu(for: collectionId)
        } else if let bookmark = context.bookmark {
            bookmarkMenu(for: bookmark, targetBookmarkIDs: context.targetBookmarkIDs)
        }
    }

    @ViewBuilder
    private func collectionMenu(for collectionId: UUID?) -> some View {
        if let collectionId {
            if onRenameCollection != nil {
                Button {
                    onRenameCollection?(collectionId)
                } label: {
                    Label("重命名分组", systemImage: "pencil")
                }
            }

            if onDeleteCollection != nil {
                Divider()
                Button(role: .destructive) {
                    onDeleteCollection?(collectionId)
                } label: {
                    Label("删除分组", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func bookmarkMenu(for bookmark: Bookmark, targetBookmarkIDs: Set<Bookmark.ID>) -> some View {
        let isSingleRow = targetBookmarkIDs.count == 1
        if isSingleRow, onOpen != nil {
            Button {
                onOpen?(bookmark)
            } label: {
                Label("打开", systemImage: "arrow.up.forward.square")
            }
        }

        if isSingleRow, onCopyURL != nil {
            Button {
                onCopyURL?(bookmark)
            } label: {
                Label("复制 URL", systemImage: "doc.on.doc")
            }
        }

        if isSingleRow, onRefreshFavicon != nil {
            Button {
                onRefreshFavicon?(bookmark)
            } label: {
                Label("刷新 favicon", systemImage: "arrow.clockwise")
            }
        }

        if isSingleRow, onEdit != nil {
            Button {
                onEdit?(bookmark)
            } label: {
                Label("编辑", systemImage: "pencil")
            }
        }

        if onRevertTitleOptimization != nil,
           selectionHasRevertableTitleOptimization(targetBookmarkIDs) {
            Button {
                onRevertTitleOptimization?(targetBookmarkIDs)
            } label: {
                Label("恢复原标题", systemImage: "arrow.uturn.backward")
            }
        }

        if isSingleRow,
           let pinStateActionTitle,
           onSetPinned != nil {
            Divider()
            Button {
                onSetPinned?(bookmark)
            } label: {
                Label(pinStateActionTitle(bookmark), systemImage: pinStateSymbolName(for: bookmark))
            }
        }

        if !collectionAssignOptions.isEmpty, onAssignCollection != nil {
            Divider()
            Menu {
                ForEach(collectionAssignOptions) { option in
                    Button(option.title) {
                        onAssignCollection?(targetBookmarkIDs, option.collectionId)
                    }
                }
            } label: {
                Label("移到分组", systemImage: "folder")
            }
        }

        if isSingleRow,
           let hiddenStateActionTitle,
           onSetHidden != nil {
            Divider()
            Button {
                onSetHidden?(bookmark)
            } label: {
                Label(
                    hiddenStateActionTitle,
                    systemImage: restoreBookmarkSymbolName(
                        for: hiddenStateActionTitle,
                        defaultSymbolName: "eye.slash"
                    )
                )
            }
        }

        if isSingleRow,
           let archiveStateActionTitle,
           onSetArchived != nil {
            Divider()
            Button {
                onSetArchived?(bookmark)
            } label: {
                Label(
                    archiveStateActionTitle,
                    systemImage: restoreBookmarkSymbolName(
                        for: archiveStateActionTitle,
                        defaultSymbolName: "archivebox"
                    )
                )
            }
        }

        if onDelete != nil {
            Divider()
            Button(role: .destructive) {
                onDelete?(targetBookmarkIDs)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var keyboardShortcuts: some View {
        Group {
            Button("") {
                if let bookmark = singleSelectedBookmark(in: rowSelection) {
                    onCopyURL?(bookmark)
                }
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(!isListFocused || singleSelectedBookmark(in: rowSelection) == nil || onCopyURL == nil)

            Button("") {
                if let bookmark = singleSelectedBookmark(in: rowSelection) {
                    onEdit?(bookmark)
                }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!isListFocused || singleSelectedBookmark(in: rowSelection) == nil || onEdit == nil)

            Button("") {
                if let bookmark = singleSelectedBookmark(in: rowSelection) {
                    onOpen?(bookmark)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isListFocused || singleSelectedBookmark(in: rowSelection) == nil || onOpen == nil)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func syncExternalSelection(from rowIDs: Set<BookmarkListRowID>) {
        let resolvedSelection = BookmarkListSelectionResolver.selection(
            from: rowIDs,
            in: items,
            allowsCollectionSelection: selectedCollectionId != nil
        )
        if selection != resolvedSelection.bookmarkIDs {
            selection = resolvedSelection.bookmarkIDs
        }
        let nextCollectionId = resolvedSelection.bookmarkIDs.isEmpty
            ? resolvedSelection.collectionId
            : nil
        if selectedCollectionId?.wrappedValue != nextCollectionId {
            selectedCollectionId?.wrappedValue = nextCollectionId
        }
    }

    private func syncRowSelectionFromExternal() {
        let nextSelection = BookmarkListSelectionResolver.rowIDs(
            for: selection,
            selectedRowIDs: rowSelection,
            selectedCollectionId: selectedCollectionId?.wrappedValue,
            in: items
        )
        if rowSelection != nextSelection {
            rowSelection = nextSelection
        }
    }

    private func isSelectable(_ item: BookmarkListItem) -> Bool {
        if item.bookmark != nil {
            return true
        }
        return selectedCollectionId != nil && item.collectionId != nil
    }

    private func singleSelectedBookmark(in rowIDs: Set<BookmarkListRowID>) -> Bookmark? {
        let bookmarks = items.compactMap { item -> Bookmark? in
            guard rowIDs.contains(item.id) else { return nil }
            return item.bookmark
        }
        guard bookmarks.count == 1 else { return nil }
        return bookmarks[0]
    }

    private func selectionHasRevertableTitleOptimization(_ bookmarkIDs: Set<Bookmark.ID>) -> Bool {
        bookmarkIDs.contains { id in
            guard let bookmark = items.compactMap(\.bookmark).first(where: { $0.id == id }) else {
                return false
            }
            guard bookmark.titleOptimized else { return false }
            let original = bookmark.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !original.isEmpty
        }
    }

    private func pinStateSymbolName(for bookmark: Bookmark) -> String {
        bookmark.isPinned ? "pin.slash" : "pin"
    }

    private func restoreBookmarkSymbolName(for title: String, defaultSymbolName: String) -> String {
        title == "恢复到书签" ? "bookmark" : defaultSymbolName
    }
}

private struct BookmarkListHeaderRow: View {
    let title: String
    let topSpacing: CGFloat
    let sortMode: BookmarkListSortMode?
    let sortScope: BookmarkListSortScope?
    let onSortModeChange: ((BookmarkListSortMode, BookmarkListSortScope?) -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            if let sortMode {
                BookmarkListSortPicker(
                    selection: Binding(
                        get: { sortMode },
                        set: { onSortModeChange?($0, sortScope) }
                    )
                )
                .frame(height: 24)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 18)
        .padding(.trailing, 18)
        .padding(.top, topSpacing)
        .padding(.bottom, 10)
        .frame(minHeight: 34 + topSpacing, alignment: .center)
    }
}

private struct BookmarkListSortPicker: View {
    @Binding var selection: BookmarkListSortMode

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(BookmarkListSortMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.regular)
        .frame(width: 108)
    }
}

private struct BookmarkListBookmarkRow: View {
    let bookmark: Bookmark
    let faviconLoader: FaviconLoader
    let faviconVersion: Int
    let showsURLHostOnly: Bool
    let referenceIndicatorSystemImage: String?

    var body: some View {
        let _ = faviconVersion
        let icon = faviconLoader.image(for: bookmark.url)

        HStack(spacing: 12) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(nsImage: AppIcon.faviconPlaceholder(size: NSSize(width: 18, height: 18)))
                        .resizable()
                        .interpolation(.high)
                }
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(displayURL(for: bookmark.url, showsHostOnly: showsURLHostOnly))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            if let referenceIndicatorSystemImage {
                Image(systemName: referenceIndicatorSystemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .padding(.trailing, 18)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, referenceIndicatorSystemImage == nil ? 36 : 0)
        .frame(height: 50)
    }

    private func displayURL(for urlString: String, showsHostOnly: Bool) -> String {
        guard showsHostOnly, let host = URL(string: urlString)?.host(percentEncoded: false) else {
            return urlString
        }
        return host
    }
}

struct BookmarkListRowID: Hashable {
    private enum Storage: Hashable {
        case header(sectionOccurrence: Int)
        case collectionHeader(UUID)
        case bookmark(BookmarkListRowSelectionKey)
    }

    private var storage: Storage

    static func header(sectionOccurrence: Int) -> BookmarkListRowID {
        BookmarkListRowID(storage: .header(sectionOccurrence: sectionOccurrence))
    }

    static func collectionHeader(_ collectionId: UUID) -> BookmarkListRowID {
        BookmarkListRowID(storage: .collectionHeader(collectionId))
    }

    static func bookmark(_ selectionKey: BookmarkListRowSelectionKey) -> BookmarkListRowID {
        BookmarkListRowID(storage: .bookmark(selectionKey))
    }
}

struct BookmarkListRowSelectionKey: Hashable, Equatable {
    var sectionOccurrence: Int
    var bookmarkId: Bookmark.ID
    var bookmarkOccurrence: Int
}

struct BookmarkListSelectionState: Equatable {
    var bookmarkIDs: Set<Bookmark.ID>
    var rowIDs: Set<BookmarkListRowID>
    var collectionId: UUID?
}

enum BookmarkListSelectionResolver {
    static func selection(
        from selectedRowIDs: Set<BookmarkListRowID>,
        in items: [BookmarkListItem],
        allowsCollectionSelection: Bool
    ) -> BookmarkListSelectionState {
        var bookmarkIDs: Set<Bookmark.ID> = []
        var rowIDs: Set<BookmarkListRowID> = []
        var collectionId: UUID?

        for item in items where selectedRowIDs.contains(item.id) {
            if let bookmark = item.bookmark {
                bookmarkIDs.insert(bookmark.id)
                rowIDs.insert(item.id)
            } else if allowsCollectionSelection,
                      selectedRowIDs.count == 1 {
                collectionId = item.collectionId
            }
        }

        return BookmarkListSelectionState(
            bookmarkIDs: bookmarkIDs,
            rowIDs: rowIDs,
            collectionId: collectionId
        )
    }

    static func rowIDs(
        for bookmarkIDs: Set<Bookmark.ID>,
        selectedRowIDs: Set<BookmarkListRowID>,
        selectedCollectionId: UUID?,
        in items: [BookmarkListItem]
    ) -> Set<BookmarkListRowID> {
        guard !bookmarkIDs.isEmpty else {
            guard let selectedCollectionId else { return [] }
            return Set(items.compactMap { item in
                item.collectionId == selectedCollectionId ? item.id : nil
            })
        }

        let keyedRows = items.compactMap { item -> (rowID: BookmarkListRowID, bookmarkId: Bookmark.ID)? in
            guard
                let bookmark = item.bookmark,
                bookmarkIDs.contains(bookmark.id),
                selectedRowIDs.contains(item.id)
            else {
                return nil
            }
            return (item.id, bookmark.id)
        }

        if Set(keyedRows.map(\.bookmarkId)) == bookmarkIDs {
            return Set(keyedRows.map(\.rowID))
        }

        var chosenRowsByBookmarkId: [Bookmark.ID: (rowID: BookmarkListRowID, isReference: Bool)] = [:]
        for item in items {
            guard
                let bookmark = item.bookmark,
                bookmarkIDs.contains(bookmark.id)
            else {
                continue
            }

            let candidate = (rowID: item.id, isReference: item.isReference)
            if let current = chosenRowsByBookmarkId[bookmark.id] {
                if current.isReference && !candidate.isReference {
                    chosenRowsByBookmarkId[bookmark.id] = candidate
                }
            } else {
                chosenRowsByBookmarkId[bookmark.id] = candidate
            }
        }

        return Set(chosenRowsByBookmarkId.values.map(\.rowID))
    }
}

enum BookmarkListItem: Equatable, Identifiable {
    case header(
        title: String,
        topSpacing: CGFloat,
        sortMode: BookmarkListSortMode?,
        collectionId: UUID?,
        sortScope: BookmarkListSortScope?,
        id: BookmarkListRowID
    )
    case bookmark(
        Bookmark,
        referenceIndicatorSystemImage: String?,
        selectionKey: BookmarkListRowSelectionKey,
        isReference: Bool,
        id: BookmarkListRowID
    )

    var id: BookmarkListRowID {
        switch self {
        case .header(_, _, _, _, _, let id):
            return id
        case .bookmark(_, _, _, _, let id):
            return id
        }
    }

    var isHeader: Bool {
        if case .header = self { return true }
        return false
    }

    var bookmark: Bookmark? {
        if case .bookmark(let bookmark, _, _, _, _) = self { return bookmark }
        return nil
    }

    var selectionKey: BookmarkListRowSelectionKey? {
        if case .bookmark(_, _, let selectionKey, _, _) = self { return selectionKey }
        return nil
    }

    var isReference: Bool {
        if case .bookmark(_, _, _, let isReference, _) = self { return isReference }
        return false
    }

    var collectionId: UUID? {
        if case .header(_, _, _, let collectionId, _, _) = self { return collectionId }
        return nil
    }

    var sortScope: BookmarkListSortScope? {
        if case .header(_, _, _, _, let sortScope, _) = self { return sortScope }
        return nil
    }
}

extension Array where Element == BookmarkListSection {
    var flattenedItems: [BookmarkListItem] {
        var items: [BookmarkListItem] = []
        var hasVisibleHeader = false

        for (sectionIndex, section) in enumerated() {
            if let title = section.title {
                let headerID: BookmarkListRowID = if let collectionId = section.collectionId {
                    .collectionHeader(collectionId)
                } else {
                    .header(sectionOccurrence: sectionIndex)
                }
                items.append(
                    .header(
                        title: title,
                        topSpacing: hasVisibleHeader ? 12 : 0,
                        sortMode: section.sortMode,
                        collectionId: section.collectionId,
                        sortScope: section.sortScope,
                        id: headerID
                    )
                )
                hasVisibleHeader = true
            }
            let bookmarkOccurrenceById = Dictionary(
                grouping: section.bookmarks.indices,
                by: { section.bookmarks[$0].id }
            ).mapValues { indices in
                Dictionary(uniqueKeysWithValues: indices.enumerated().map { pair in
                    (pair.element, pair.offset)
                })
            }
            items.append(
                contentsOf: section.bookmarks.indices.map { bookmarkIndex in
                    let bookmark = section.bookmarks[bookmarkIndex]
                    let selectionKey = BookmarkListRowSelectionKey(
                        sectionOccurrence: sectionIndex,
                        bookmarkId: bookmark.id,
                        bookmarkOccurrence: bookmarkOccurrenceById[bookmark.id]?[bookmarkIndex] ?? 0
                    )
                    return BookmarkListItem.bookmark(
                        bookmark,
                        referenceIndicatorSystemImage: section.referenceIndicatorSystemImage,
                        selectionKey: selectionKey,
                        isReference: section.referenceIndicatorSystemImage != nil,
                        id: .bookmark(selectionKey)
                    )
                }
            )
        }

        return items
    }
}

private struct BookmarkListContext {
    var bookmark: Bookmark?
    var targetBookmarkIDs: Set<Bookmark.ID>
    var collectionId: UUID?

    init(rowIDs: Set<BookmarkListRowID>, items: [BookmarkListItem]) {
        let selectedItems = items.filter { rowIDs.contains($0.id) }
        let bookmarkItems = selectedItems.compactMap(\.bookmark)
        let bookmarkIDs = Set(bookmarkItems.map(\.id))

        if let collectionItem = selectedItems.first(where: { $0.collectionId != nil }),
           bookmarkItems.isEmpty,
           selectedItems.count == 1 {
            collectionId = collectionItem.collectionId
        }

        bookmark = bookmarkItems.first
        targetBookmarkIDs = bookmarkIDs
    }
}

extension BookmarkCollectionAssignOption: Identifiable {
    var id: String {
        collectionId?.uuidString ?? "ungrouped"
    }
}
