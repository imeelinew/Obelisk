import AppKit
import Carbon.HIToolbox
import ObeliskCore
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

struct NativeBookmarkList: NSViewRepresentable {
    var sections: [BookmarkListSection]
    @Binding var selection: Set<Bookmark.ID>
    var focusFirstBookmarkRequest: Int = 0
    var focusSelectedBookmarkRequest: Int = 0
    var onCancel: (() -> Void)?
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
    var archiveStateActionTitleProvider: ((Bookmark) -> String)? = nil
    var onSetArchived: ((Bookmark) -> Void)? = nil
    var pinStateActionTitle: ((Bookmark) -> String)? = nil
    var onSetPinned: ((Bookmark) -> Void)? = nil
    var onSortModeChange: ((BookmarkListSortMode, BookmarkListSortScope?) -> Void)? = nil
    var collectionAssignOptions: [BookmarkCollectionAssignOption] = []
    var onAssignCollection: ((Set<Bookmark.ID>, UUID?) -> Void)? = nil
    var onRenameCollection: ((UUID) -> Void)? = nil
    var onDeleteCollection: ((UUID) -> Void)? = nil
    var onRevertTitleOptimization: ((Set<Bookmark.ID>) -> Void)? = nil
    fileprivate static let contentInset: CGFloat = 18
    fileprivate static let rowHeight: CGFloat = 50
    fileprivate static let headerHeight: CGFloat = 24
    fileprivate static let historyHeaderHeight: CGFloat = headerHeight + headerBottomSpacing
    fileprivate static let headerBottomSpacing: CGFloat = 10
    fileprivate static let headerSortControlHeight: CGFloat = 24
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let tableView = HoverTableView()
        tableView.frame = scrollView.contentView.bounds
        tableView.autoresizingMask = [.width]
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowSizeStyle = .custom
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.hoverDelegate = context.coordinator
        tableView.menuDelegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        context.coordinator.scrollView = scrollView
        context.coordinator.tableView = tableView
        context.coordinator.installScrollObserver()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let nextItems = sections.flattenedItems
        if context.coordinator.items != nextItems ||
           context.coordinator.cachedShowsURLHostOnly != showsURLHostOnly {
            context.coordinator.cachedFaviconVersion = faviconVersion
            context.coordinator.cachedShowsURLHostOnly = showsURLHostOnly
            context.coordinator.items = nextItems
            context.coordinator.reloadTable()
        } else if context.coordinator.cachedFaviconVersion != faviconVersion {
            // Rows are unchanged; a favicon finished loading. Refresh only the
            // prepared rows instead of rebuilding the whole table so selection,
            // hover, and scroll state stay intact.
            context.coordinator.cachedFaviconVersion = faviconVersion
            context.coordinator.reloadPreparedRows()
        } else {
            context.coordinator.syncSelectionToTable()
        }
        context.coordinator.handleFocusFirstBookmarkRequestIfNeeded()
        context.coordinator.handleFocusSelectedBookmarkRequestIfNeeded()
    }

    private static let columnIdentifier = NSUserInterfaceItemIdentifier("BookmarkColumn")

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, HoverTableViewDelegate, BookmarkMenuTableViewDelegate {
        var parent: NativeBookmarkList
        fileprivate var items: [NativeBookmarkListItem] = []
        weak var scrollView: NSScrollView?
        weak var tableView: HoverTableView?
        private var isSyncingSelection = false
        private var selectedRowKeys: Set<NativeBookmarkRowSelectionKey> = []
        private var hoveredRow: Int = -1
        fileprivate var cachedFaviconVersion: Int = -1
        fileprivate var cachedShowsURLHostOnly = false
        private var handledFocusFirstBookmarkRequest = 0
        private var handledFocusSelectedBookmarkRequest = 0

        init(_ parent: NativeBookmarkList) {
            self.parent = parent
            self.items = parent.sections.flattenedItems
            self.cachedShowsURLHostOnly = parent.showsURLHostOnly
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func reloadTable() {
            guard let tableView else { return }
            syncTableWidth()
            tableView.reloadData()
            syncTableWidth()
            syncSelectionToTable()
            // Row indices may have shifted after reload; clear stale hover and
            // re-derive from the current cursor location.
            applyHoveredRow(-1)
            tableView.updateHoverFromCurrentMouse()
        }

        /// Reloads only rows that have prepared cell views (visible plus
        /// overdraw). Offscreen rows get fresh cells lazily when scrolled in.
        func reloadPreparedRows() {
            guard let tableView, !items.isEmpty else { return }
            let range = tableView.rows(in: tableView.preparedContentRect)
            guard range.length > 0 else { return }
            let rows = IndexSet(integersIn: range.location ..< (range.location + range.length))
            tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        }

        private func syncTableWidth() {
            guard let tableView, let scrollView else { return }
            let width = max(scrollView.contentView.bounds.width, 100)
            if tableView.frame.width != width {
                tableView.frame.size.width = width
            }
            if let column = tableView.tableColumns.first, column.width != width {
                column.width = width
            }

            let clipView = scrollView.contentView
            guard clipView.bounds.origin.x != 0 else { return }
            clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.origin.y))
            scrollView.reflectScrolledClipView(clipView)
        }

        func installScrollObserver() {
            guard let scrollView else { return }
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(contentBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        @objc private func contentBoundsDidChange() {
            syncTableWidth()
            // Content moved under the cursor: even if the mouse hasn't moved,
            // the row beneath it has changed. Recompute from real cursor pos
            // so hovered state has exactly one source of truth.
            tableView?.updateHoverFromCurrentMouse()
        }

        // MARK: HoverTableViewDelegate

        func hoverTableView(_ tableView: HoverTableView, didHoverRow row: Int) {
            let resolved: Int
            if row >= 0,
               row < items.count,
               items[row].bookmark != nil || selectedCollectionId(for: row) != nil {
                resolved = row
            } else {
                resolved = -1
            }
            applyHoveredRow(resolved)
        }

        private func applyHoveredRow(_ row: Int) {
            guard row != hoveredRow else { return }
            let previous = hoveredRow
            hoveredRow = row

            guard let tableView else { return }
            let rowCount = tableView.numberOfRows
            if previous >= 0,
               previous < rowCount,
               let view = tableView.rowView(atRow: previous, makeIfNecessary: false) as? HoverableRowView {
                view.isHovered = false
            }
            if row >= 0,
               row < rowCount,
               let view = tableView.rowView(atRow: row, makeIfNecessary: false) as? HoverableRowView {
                view.isHovered = true
            }
        }

        func isRowHovered(_ row: Int) -> Bool {
            row == hoveredRow
        }

        func bookmarkMenuTableView(_ tableView: BookmarkMenuTableView, shouldSelectContextRow row: Int) -> Bool {
            guard row >= 0, row < items.count else { return false }
            if items[row].collectionId != nil, parent.onRenameCollection != nil || parent.onDeleteCollection != nil {
                return true
            }
            return items[row].bookmark != nil
        }

        func bookmarkMenuTableView(_ tableView: BookmarkMenuTableView, menuForRow row: Int) -> NSMenu? {
            guard row >= 0, row < items.count else { return nil }

            if let collectionId = items[row].collectionId {
                let menu = NSMenu()
                menu.delegate = self
                if parent.onRenameCollection != nil {
                    menu.addItem(collectionMenuItem(
                        "重命名分组",
                        systemSymbolName: "pencil",
                        action: #selector(renameCollectionFromMenu(_:)),
                        collectionId: collectionId
                    ))
                }
                if parent.onDeleteCollection != nil {
                    if !menu.items.isEmpty {
                        menu.addItem(NSMenuItem.separator())
                    }
                    menu.addItem(destructiveCollectionMenuItem(
                        "删除分组",
                        systemSymbolName: "trash",
                        action: #selector(deleteCollectionFromMenu(_:)),
                        collectionId: collectionId
                    ))
                }
                return menu.items.isEmpty ? nil : menu
            }

            guard let bookmark = items[row].bookmark else {
                return nil
            }

            let menu = NSMenu()
            menu.delegate = self

            if parent.onOpen != nil {
                menu.addItem(menuItem(
                    "打开",
                    systemSymbolName: "arrow.up.forward.square",
                    action: #selector(openFromMenu(_:)),
                    bookmark: bookmark
                ))
            }
            if parent.onCopyURL != nil {
                menu.addItem(menuItem(
                    "复制 URL",
                    systemSymbolName: "doc.on.doc",
                    action: #selector(copyURLFromMenu(_:)),
                    bookmark: bookmark
                ))
            }
            if parent.onRefreshFavicon != nil {
                menu.addItem(menuItem(
                    "刷新 favicon",
                    systemSymbolName: "arrow.clockwise",
                    action: #selector(refreshFaviconFromMenu(_:)),
                    bookmark: bookmark
                ))
            }
            if parent.onEdit != nil {
                menu.addItem(menuItem(
                    "编辑",
                    systemSymbolName: "pencil",
                    action: #selector(editFromMenu(_:)),
                    bookmark: bookmark
                ))
            }
            if parent.onRevertTitleOptimization != nil,
               selectionHasRevertableTitleOptimization(contextBookmark: bookmark) {
                menu.addItem(menuItem(
                    "恢复原标题",
                    systemSymbolName: "arrow.uturn.backward",
                    action: #selector(revertTitleFromMenu(_:)),
                    bookmark: bookmark
                ))
            }
            if let pinStateActionTitle = parent.pinStateActionTitle, parent.onSetPinned != nil {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(menuItem(
                    pinStateActionTitle(bookmark),
                    systemSymbolName: pinStateSymbolName(for: bookmark),
                    action: #selector(setPinnedFromMenu(_:)),
                    bookmark: bookmark
                ))
            }
            if !parent.collectionAssignOptions.isEmpty, parent.onAssignCollection != nil {
                menu.addItem(NSMenuItem.separator())
                let submenu = NSMenu(title: "移到分组")
                for option in parent.collectionAssignOptions {
                    let item = NSMenuItem(title: option.title, action: #selector(assignCollectionFromMenu(_:)), keyEquivalent: "")
                    item.representedObject = CollectionAssignTarget(
                        contextBookmarkId: bookmark.id,
                        collectionId: option.collectionId
                    )
                    item.target = self
                    submenu.addItem(item)
                }
                let moveItem = NSMenuItem(title: "移到分组", action: nil, keyEquivalent: "")
                moveItem.image = Self.menuSymbolImage("folder")
                moveItem.submenu = submenu
                menu.addItem(moveItem)
            }
            if let hiddenStateActionTitle = parent.hiddenStateActionTitle, parent.onSetHidden != nil {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(menuItem(
                    hiddenStateActionTitle,
                    systemSymbolName: restoreBookmarkSymbolName(for: hiddenStateActionTitle, defaultSymbolName: "eye.slash"),
                    action: #selector(setHiddenFromMenu(_:)),
                    bookmark: bookmark
                ))
            }
            if let archiveStateActionTitle = parent.archiveStateActionTitleProvider?(bookmark) ?? parent.archiveStateActionTitle,
               parent.onSetArchived != nil {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(menuItem(
                    archiveStateActionTitle,
                    systemSymbolName: restoreBookmarkSymbolName(for: archiveStateActionTitle, defaultSymbolName: "archivebox"),
                    action: #selector(setArchivedFromMenu(_:)),
                    bookmark: bookmark
                ))
            }
            if parent.onDelete != nil {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(destructiveMenuItem(
                    "删除",
                    systemSymbolName: "trash",
                    action: #selector(deleteFromMenu(_:)),
                    bookmark: bookmark
                ))
            }

            return menu.items.isEmpty ? nil : menu
        }

        func bookmarkMenuTableViewCopySelection(_ tableView: BookmarkMenuTableView) {
            guard let bookmark = singleSelectedBookmark(in: tableView) else { return }
            parent.onCopyURL?(bookmark)
        }

        func bookmarkMenuTableViewEditSelection(_ tableView: BookmarkMenuTableView) {
            guard let bookmark = singleSelectedBookmark(in: tableView) else { return }
            parent.onEdit?(bookmark)
        }

        func bookmarkMenuTableViewDeleteSelection(_ tableView: BookmarkMenuTableView) {
            guard !parent.selection.isEmpty else { return }
            parent.onDelete?(parent.selection)
        }

        func bookmarkMenuTableViewOpenSelection(_ tableView: BookmarkMenuTableView) {
            guard let bookmark = singleSelectedBookmark(in: tableView) else { return }
            parent.onOpen?(bookmark)
        }

        func bookmarkMenuTableViewCancel(_ tableView: BookmarkMenuTableView) -> Bool {
            guard let onCancel = parent.onCancel else { return false }
            onCancel()
            return true
        }

        func bookmarkMenuTableView(
            _ tableView: BookmarkMenuTableView,
            nextSelectableRowAfter row: Int
        ) -> Int? {
            let startRow = max(row + 1, 0)
            guard startRow < items.count else { return nil }

            return items.indices[startRow...].first { candidate in
                items[candidate].bookmark != nil || selectedCollectionId(for: candidate) != nil
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            false
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard row >= 0, row < items.count else { return false }
            if items[row].bookmark != nil {
                return true
            }
            return selectedCollectionId(for: row) != nil
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard row >= 0,
                  row < items.count,
                  items[row].bookmark != nil || selectedCollectionId(for: row) != nil
            else {
                return nil
            }
            let view = HoverableRowView()
            view.isHovered = isRowHovered(row)
            return view
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row >= 0, row < items.count else { return Self.parentRowHeight }
            switch items[row] {
            case .header(_, let topSpacing, _, _, _):
                return NativeBookmarkList.headerHeight + topSpacing + NativeBookmarkList.headerBottomSpacing
            case .bookmark(_, _, _, _):
                return NativeBookmarkList.rowHeight
            }
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard row >= 0, row < items.count else { return nil }

            switch items[row] {
            case .header(let title, let topSpacing, let sortMode, _, let sortScope):
                let view = tableView.makeView(
                    withIdentifier: BookmarkHeaderCellView.identifier,
                    owner: self
                ) as? BookmarkHeaderCellView ?? BookmarkHeaderCellView()
                view.configure(
                    title: title,
                    topSpacing: topSpacing,
                    sortMode: sortMode,
                    sortScope: sortScope,
                    target: self,
                    action: #selector(changeSortModeFromHeader(_:))
                )
                return view

            case .bookmark(let bookmark, let referenceIndicatorSystemImage, _, _):
                let view = tableView.makeView(
                    withIdentifier: BookmarkTableCellView.identifier,
                    owner: self
                ) as? BookmarkTableCellView ?? BookmarkTableCellView()
                view.configure(
                    bookmark: bookmark,
                    showsURLHostOnly: parent.showsURLHostOnly,
                    favicon: parent.faviconLoader.image(for: bookmark.url),
                    referenceIndicatorSystemImage: referenceIndicatorSystemImage
                )
                return view
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let tableView else { return }
            let resolvedSelection = NativeBookmarkSelectionResolver.selection(
                from: tableView.selectedRowIndexes,
                in: items,
                allowsCollectionSelection: parent.selectedCollectionId != nil
            )

            selectedRowKeys = resolvedSelection.rowKeys
            parent.selection = resolvedSelection.bookmarkIDs
            parent.selectedCollectionId?.wrappedValue = resolvedSelection.bookmarkIDs.isEmpty
                ? resolvedSelection.collectionId
                : nil
        }

        @objc func handleDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < items.count, let bookmark = items[row].bookmark else {
                return
            }
            parent.onOpen?(bookmark)
        }

        @objc private func openFromMenu(_ sender: NSMenuItem) {
            guard let bookmark = sender.representedObject as? Bookmark else { return }
            parent.onOpen?(bookmark)
        }

        @objc private func copyURLFromMenu(_ sender: NSMenuItem) {
            guard let bookmark = sender.representedObject as? Bookmark else { return }
            parent.onCopyURL?(bookmark)
        }

        @objc private func refreshFaviconFromMenu(_ sender: NSMenuItem) {
            guard let bookmark = sender.representedObject as? Bookmark else { return }
            parent.onRefreshFavicon?(bookmark)
        }

        @objc private func editFromMenu(_ sender: NSMenuItem) {
            guard let bookmark = sender.representedObject as? Bookmark else { return }
            parent.onEdit?(bookmark)
        }

        @objc private func revertTitleFromMenu(_ sender: NSMenuItem) {
            guard let bookmark = sender.representedObject as? Bookmark else { return }
            let bookmarkIds = parent.selection.isEmpty ? Set([bookmark.id]) : parent.selection
            parent.onRevertTitleOptimization?(bookmarkIds)
        }

        private func selectionHasRevertableTitleOptimization(contextBookmark: Bookmark) -> Bool {
            let targetIds = parent.selection.isEmpty ? Set([contextBookmark.id]) : parent.selection
            return targetIds.contains { id in
                guard let bookmark = bookmark(for: id) else { return false }
                guard bookmark.titleOptimized else { return false }
                let original = bookmark.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !original.isEmpty
            }
        }

        private func bookmark(for id: Bookmark.ID) -> Bookmark? {
            items.compactMap(\.bookmark).first { $0.id == id }
        }

        @objc private func deleteFromMenu(_ sender: NSMenuItem) {
            guard let bookmark = sender.representedObject as? Bookmark else { return }
            let selectedIDs = parent.selection.isEmpty ? [bookmark.id] : parent.selection
            parent.onDelete?(selectedIDs)
        }

        @objc private func renameCollectionFromMenu(_ sender: NSMenuItem) {
            guard let collectionId = sender.representedObject as? UUID else { return }
            parent.onRenameCollection?(collectionId)
        }

        @objc private func deleteCollectionFromMenu(_ sender: NSMenuItem) {
            guard let collectionId = sender.representedObject as? UUID else { return }
            parent.onDeleteCollection?(collectionId)
        }

        @objc private func assignCollectionFromMenu(_ sender: NSMenuItem) {
            guard
                let target = sender.representedObject as? CollectionAssignTarget,
                let onAssignCollection = parent.onAssignCollection
            else {
                return
            }
            let bookmarkIds = parent.selection.isEmpty
                ? Set([target.contextBookmarkId])
                : parent.selection
            onAssignCollection(bookmarkIds, target.collectionId)
        }

        @objc private func setHiddenFromMenu(_ sender: NSMenuItem) {
            guard let bookmark = sender.representedObject as? Bookmark else { return }
            parent.onSetHidden?(bookmark)
        }

        @objc private func setArchivedFromMenu(_ sender: NSMenuItem) {
            guard let bookmark = sender.representedObject as? Bookmark else { return }
            parent.onSetArchived?(bookmark)
        }

        @objc private func setPinnedFromMenu(_ sender: NSMenuItem) {
            guard let bookmark = sender.representedObject as? Bookmark else { return }
            parent.onSetPinned?(bookmark)
        }

        @objc private func changeSortModeFromHeader(_ sender: NSPopUpButton) {
            guard
                let rawValue = sender.selectedItem?.representedObject as? String,
                let sortMode = BookmarkListSortMode(rawValue: rawValue)
            else {
                return
            }
            let sortScope = (sender.superview as? BookmarkHeaderCellView)?.sortScope
            parent.onSortModeChange?(sortMode, sortScope)
        }

        func syncSelectionToTable() {
            guard let tableView else { return }
            let rowIndexes = NativeBookmarkSelectionResolver.rowIndexes(
                for: parent.selection,
                selectedRowKeys: selectedRowKeys,
                selectedCollectionId: parent.selectedCollectionId?.wrappedValue,
                in: items
            )
            selectedRowKeys = Set(rowIndexes.compactMap { row in
                guard row >= 0, row < items.count else { return nil }
                return items[row].selectionKey
            })

            isSyncingSelection = true
            tableView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
            isSyncingSelection = false
        }

        func handleFocusFirstBookmarkRequestIfNeeded() {
            guard parent.focusFirstBookmarkRequest > 0,
                  parent.focusFirstBookmarkRequest != handledFocusFirstBookmarkRequest,
                  let tableView,
                  let row = NativeBookmarkSelectionResolver.firstBookmarkRowIndex(in: items)
            else {
                return
            }

            handledFocusFirstBookmarkRequest = parent.focusFirstBookmarkRequest
            tableView.window?.makeFirstResponder(tableView)
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }

        func handleFocusSelectedBookmarkRequestIfNeeded() {
            guard parent.focusSelectedBookmarkRequest > 0,
                  parent.focusSelectedBookmarkRequest != handledFocusSelectedBookmarkRequest,
                  let tableView
            else {
                return
            }

            let rowIndexes = NativeBookmarkSelectionResolver.rowIndexes(
                for: parent.selection,
                selectedRowKeys: selectedRowKeys,
                selectedCollectionId: parent.selectedCollectionId?.wrappedValue,
                in: items
            )
            guard !rowIndexes.isEmpty else { return }

            handledFocusSelectedBookmarkRequest = parent.focusSelectedBookmarkRequest
            tableView.window?.makeFirstResponder(tableView)
            tableView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
            if let row = rowIndexes.first {
                tableView.scrollRowToVisible(row)
            }
        }

        private static let destructiveMenuItemIdentifier = NSUserInterfaceItemIdentifier("ObeliskDestructiveMenuItem")

        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            for menuItem in menu.items where menuItem.identifier == Self.destructiveMenuItemIdentifier {
                applyDestructiveMenuItemStyle(to: menuItem, highlighted: menuItem === item)
            }
        }

        private static func menuSymbolImage(_ symbolName: String, color: NSColor? = nil) -> NSImage? {
            guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
                return nil
            }

            var configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            if let color {
                configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            }

            return image.withSymbolConfiguration(configuration)
        }

        private func pinStateSymbolName(for bookmark: Bookmark) -> String {
            bookmark.isPinned ? "pin.slash" : "pin"
        }

        private func restoreBookmarkSymbolName(for title: String, defaultSymbolName: String) -> String {
            title == "恢复到书签" ? "bookmark" : defaultSymbolName
        }

        private func menuItem(
            _ title: String,
            systemSymbolName: String,
            action: Selector,
            bookmark: Bookmark
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = bookmark
            item.image = Self.menuSymbolImage(systemSymbolName)
            return item
        }

        private final class CollectionAssignTarget: NSObject {
            let contextBookmarkId: Bookmark.ID
            let collectionId: UUID?

            init(contextBookmarkId: Bookmark.ID, collectionId: UUID?) {
                self.contextBookmarkId = contextBookmarkId
                self.collectionId = collectionId
            }
        }

        private func collectionMenuItem(
            _ title: String,
            systemSymbolName: String,
            action: Selector,
            collectionId: UUID
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = collectionId
            item.image = Self.menuSymbolImage(systemSymbolName)
            return item
        }

        private func selectedCollectionId(for row: Int) -> UUID? {
            guard parent.selectedCollectionId != nil,
                  row >= 0,
                  row < items.count
            else {
                return nil
            }
            return items[row].collectionId
        }

        private func destructiveCollectionMenuItem(
            _ title: String,
            systemSymbolName: String,
            action: Selector,
            collectionId: UUID
        ) -> NSMenuItem {
            destructiveMenuItem(
                title,
                systemSymbolName: systemSymbolName,
                action: action,
                representedObject: collectionId
            )
        }

        private func destructiveMenuItem(
            _ title: String,
            systemSymbolName: String,
            action: Selector,
            bookmark: Bookmark
        ) -> NSMenuItem {
            destructiveMenuItem(
                title,
                systemSymbolName: systemSymbolName,
                action: action,
                representedObject: bookmark
            )
        }

        private func destructiveMenuItem(
            _ title: String,
            systemSymbolName: String,
            action: Selector,
            representedObject: Any
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = representedObject
            item.identifier = Self.destructiveMenuItemIdentifier
            applyDestructiveMenuItemStyle(to: item, systemSymbolName: systemSymbolName, highlighted: false)
            return item
        }

        private func applyDestructiveMenuItemStyle(
            to item: NSMenuItem,
            systemSymbolName: String = "trash",
            highlighted: Bool
        ) {
            let color: NSColor = highlighted ? .white : .systemRed
            item.attributedTitle = NSAttributedString(
                string: item.title,
                attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .foregroundColor: color
                ]
            )
            item.image = Self.menuSymbolImage(systemSymbolName, color: color)
        }

        private func singleSelectedBookmark(in tableView: NSTableView) -> Bookmark? {
            guard tableView.selectedRowIndexes.count == 1,
                  let row = tableView.selectedRowIndexes.first,
                  row >= 0,
                  row < items.count
            else {
                return nil
            }
            return items[row].bookmark
        }

        private static let parentRowHeight = NativeBookmarkList.rowHeight
    }
}

struct NativeBrowserHistoryList: NSViewRepresentable {
    var sections: [BrowserHistorySection]
    @Binding var selection: Set<UUID>
    var faviconLoader: FaviconLoader
    var faviconVersion: Int
    var showsURLHostOnly: Bool = false
    var onOpen: ((BrowserHistoryRecord) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none

        let tableView = HoverTableView()
        tableView.frame = scrollView.contentView.bounds
        tableView.autoresizingMask = [.width]
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowSizeStyle = .custom
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.hoverDelegate = context.coordinator
        tableView.menuDelegate = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.handleClick(_:))
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        context.coordinator.scrollView = scrollView
        context.coordinator.tableView = tableView
        context.coordinator.installScrollObserver()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.sections != sections ||
           context.coordinator.cachedShowsURLHostOnly != showsURLHostOnly {
            context.coordinator.sections = sections
            context.coordinator.cachedShowsURLHostOnly = showsURLHostOnly
            context.coordinator.cachedFaviconVersion = faviconVersion
            context.coordinator.resetCache()
            context.coordinator.reloadTable()
        } else if context.coordinator.cachedFaviconVersion != faviconVersion {
            context.coordinator.cachedFaviconVersion = faviconVersion
            context.coordinator.reloadPreparedRows()
        } else {
            context.coordinator.syncSelectionToTable()
        }
    }

    private static let columnIdentifier = NSUserInterfaceItemIdentifier("BrowserHistoryColumn")

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, HoverTableViewDelegate, BookmarkMenuTableViewDelegate {
        var parent: NativeBrowserHistoryList
        fileprivate var sections: [BrowserHistorySection]
        weak var scrollView: NSScrollView?
        weak var tableView: HoverTableView?
        fileprivate var cachedFaviconVersion = -1
        fileprivate var cachedShowsURLHostOnly = false
        private var hoveredRow = -1
        private var selectedRecordIDs: Set<UUID> = []
        private var selectedSectionID: String?
        private var expandedSectionIDs: Set<String> = []
        private var isSyncingSelection = false

        init(_ parent: NativeBrowserHistoryList) {
            self.parent = parent
            self.sections = parent.sections
            self.cachedShowsURLHostOnly = parent.showsURLHostOnly
            self.expandedSectionIDs = Self.defaultExpandedSectionIDs(for: parent.sections)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func resetCache() {
            selectedRecordIDs = []
            selectedSectionID = nil
            expandedSectionIDs = Self.defaultExpandedSectionIDs(for: sections)
        }

        func reloadTable() {
            guard let tableView else { return }
            syncTableWidth()
            tableView.reloadData()
            syncTableWidth()
            syncSelectionToTable()
            applyHoveredRow(-1)
            tableView.updateHoverFromCurrentMouse()
        }

        func reloadPreparedRows() {
            guard let tableView, tableView.numberOfRows > 0 else { return }
            let range = tableView.rows(in: tableView.preparedContentRect)
            guard range.length > 0 else { return }
            let rows = IndexSet(integersIn: range.location ..< (range.location + range.length))
            tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        }

        func installScrollObserver() {
            guard let scrollView else { return }
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(contentBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        @objc private func contentBoundsDidChange() {
            syncTableWidth()
            tableView?.updateHoverFromCurrentMouse()
        }

        private func syncTableWidth() {
            guard let tableView, let scrollView else { return }
            let width = max(scrollView.contentView.bounds.width, 100)
            if tableView.frame.width != width {
                tableView.frame.size.width = width
            }
            if let column = tableView.tableColumns.first, column.width != width {
                column.width = width
            }
            let clipView = scrollView.contentView
            guard clipView.bounds.origin.x != 0 else { return }
            clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.origin.y))
            scrollView.reflectScrolledClipView(clipView)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            sections.reduce(0) { total, section in
                total + 1 + (expandedSectionIDs.contains(section.id) ? section.count : 0)
            }
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            switch rowInfo(for: row) {
            case .header, .record:
                return true
            case .none:
                return false
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            switch rowInfo(for: row) {
            case .header, .record:
                let view = HoverableRowView()
                view.isHovered = isRowHovered(row)
                return view
            case .none:
                return nil
            }
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            switch rowInfo(for: row) {
            case .header:
                return NativeBookmarkList.historyHeaderHeight
            case .record:
                return NativeBookmarkList.rowHeight
            case .none:
                return NativeBookmarkList.rowHeight
            }
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            switch rowInfo(for: row) {
            case .header(let section, _):
                let view = tableView.makeView(
                    withIdentifier: BrowserHistoryHeaderCellView.identifier,
                    owner: self
                ) as? BrowserHistoryHeaderCellView ?? BrowserHistoryHeaderCellView()
                view.configure(
                    title: section.title,
                    isExpanded: expandedSectionIDs.contains(section.id),
                    target: nil,
                    action: #selector(noopHeaderAction(_:))
                )
                return view

            case .record(let section, let offset):
                let view = tableView.makeView(
                    withIdentifier: BookmarkTableCellView.identifier,
                    owner: self
                ) as? BookmarkTableCellView ?? BookmarkTableCellView()

                guard let record = record(in: section, offset: offset) else { return nil }
                let bookmark = bookmark(from: record)
                view.configure(
                    bookmark: bookmark,
                    showsURLHostOnly: parent.showsURLHostOnly,
                    favicon: parent.faviconLoader.image(for: record.url),
                    referenceIndicatorSystemImage: nil,
                    sourceIcon: BrowserHistoryBrowserIcon.image(for: record.browser)
                )
                return view

            case .none:
                return nil
            }
        }

        @objc private func noopHeaderAction(_ sender: Any?) {}

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection else { return }
            guard let tableView else { return }
            var ids = Set<UUID>()
            var sectionID: String?
            for row in tableView.selectedRowIndexes {
                switch rowInfo(for: row) {
                case .header(let section, _):
                    if tableView.selectedRowIndexes.count == 1 {
                        sectionID = section.id
                    }
                case .record(let section, let offset):
                    if let id = record(in: section, offset: offset)?.id {
                        ids.insert(id)
                    }
                case .none:
                    continue
                }
            }
            selectedRecordIDs = ids
            selectedSectionID = ids.isEmpty ? sectionID : nil
            parent.selection = selectedRecordIDs
        }

        func syncSelectionToTable() {
            guard let tableView else { return }
            let targetIDs = parent.selection
            var rows = IndexSet()
            for row in 0 ..< tableView.numberOfRows {
                switch rowInfo(for: row) {
                case .header(let section, _):
                    if targetIDs.isEmpty, selectedSectionID == section.id {
                        rows.insert(row)
                    }
                case .record(let section, let offset):
                    if let record = record(in: section, offset: offset), targetIDs.contains(record.id) {
                        rows.insert(row)
                    }
                case .none:
                    continue
                }
            }
            isSyncingSelection = true
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            isSyncingSelection = false
        }

        func hoverTableView(_ tableView: HoverTableView, didHoverRow row: Int) {
            if row >= 0, rowInfo(for: row) != nil {
                applyHoveredRow(row)
            } else {
                applyHoveredRow(-1)
            }
        }

        @objc func handleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0,
                  case .header(let section, _) = rowInfo(for: row)
            else {
                return
            }
            toggleSection(section)
        }

        @objc func handleDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0,
                  case .record(let section, let offset) = rowInfo(for: row),
                  let record = record(in: section, offset: offset)
            else {
                return
            }
            parent.onOpen?(record)
        }

        private func applyHoveredRow(_ row: Int) {
            guard row != hoveredRow else { return }
            let previous = hoveredRow
            hoveredRow = row
            guard let tableView else { return }
            let rowCount = tableView.numberOfRows
            if previous >= 0,
               previous < rowCount,
               let view = tableView.rowView(atRow: previous, makeIfNecessary: false) as? HoverableRowView {
                view.isHovered = false
            }
            if row >= 0,
               row < rowCount,
               let view = tableView.rowView(atRow: row, makeIfNecessary: false) as? HoverableRowView {
                view.isHovered = true
            }
        }

        private func isRowHovered(_ row: Int) -> Bool {
            row == hoveredRow
        }

        func bookmarkMenuTableView(_ tableView: BookmarkMenuTableView, shouldSelectContextRow row: Int) -> Bool {
            if rowInfo(for: row) != nil {
                return true
            }
            return false
        }

        func bookmarkMenuTableView(_ tableView: BookmarkMenuTableView, menuForRow row: Int) -> NSMenu? {
            nil
        }

        func bookmarkMenuTableViewCopySelection(_ tableView: BookmarkMenuTableView) {}
        func bookmarkMenuTableViewEditSelection(_ tableView: BookmarkMenuTableView) {}
        func bookmarkMenuTableViewDeleteSelection(_ tableView: BookmarkMenuTableView) {}
        func bookmarkMenuTableViewOpenSelection(_ tableView: BookmarkMenuTableView) {
            guard tableView.selectedRowIndexes.count == 1,
                  let row = tableView.selectedRowIndexes.first,
                  case .record(let section, let offset) = rowInfo(for: row),
                  let record = record(in: section, offset: offset)
            else {
                return
            }
            parent.onOpen?(record)
        }
        func bookmarkMenuTableViewCancel(_ tableView: BookmarkMenuTableView) -> Bool { false }

        func bookmarkMenuTableView(
            _ tableView: BookmarkMenuTableView,
            nextSelectableRowAfter row: Int
        ) -> Int? {
            let start = max(row + 1, 0)
            guard start < tableView.numberOfRows else { return nil }
            return (start ..< tableView.numberOfRows).first { candidate in
                rowInfo(for: candidate) != nil
            }
        }

        private func rowInfo(for row: Int) -> RowInfo? {
            guard row >= 0 else { return nil }
            var cursor = 0
            for (sectionIndex, section) in sections.enumerated() {
                if row == cursor {
                    return .header(section, sectionIndex)
                }
                guard expandedSectionIDs.contains(section.id) else {
                    cursor += 1
                    continue
                }
                let firstRecordRow = cursor + 1
                let lastRecordRow = firstRecordRow + section.count
                if row >= firstRecordRow, row < lastRecordRow {
                    return .record(section, offset: row - firstRecordRow)
                }
                cursor = lastRecordRow
            }
            return nil
        }

        private func toggleSection(_ section: BrowserHistorySection) {
            if expandedSectionIDs.contains(section.id) {
                expandedSectionIDs.remove(section.id)
            } else {
                expandedSectionIDs.insert(section.id)
            }
            selectedSectionID = section.id
            selectedRecordIDs = []
            parent.selection = []
            reloadTable()
        }

        private func record(in section: BrowserHistorySection, offset: Int) -> BrowserHistoryRecord? {
            guard section.records.indices.contains(offset) else { return nil }
            return section.records[offset]
        }

        private func bookmark(from record: BrowserHistoryRecord) -> Bookmark {
            Bookmark(
                id: record.id,
                title: record.title,
                url: record.url,
                createdAt: record.visitedAt,
                originalTitle: record.title
            )
        }

        private enum RowInfo {
            case header(BrowserHistorySection, Int)
            case record(BrowserHistorySection, offset: Int)
        }

        private static func defaultExpandedSectionIDs(for sections: [BrowserHistorySection]) -> Set<String> {
            guard let first = sections.first else { return [] }
            return [first.id]
        }
    }
}

@MainActor
protocol HoverTableViewDelegate: AnyObject {
    func hoverTableView(_ tableView: HoverTableView, didHoverRow row: Int)
}

@MainActor
protocol BookmarkMenuTableViewDelegate: AnyObject {
    func bookmarkMenuTableView(_ tableView: BookmarkMenuTableView, shouldSelectContextRow row: Int) -> Bool
    func bookmarkMenuTableView(_ tableView: BookmarkMenuTableView, menuForRow row: Int) -> NSMenu?
    func bookmarkMenuTableViewCopySelection(_ tableView: BookmarkMenuTableView)
    func bookmarkMenuTableViewEditSelection(_ tableView: BookmarkMenuTableView)
    func bookmarkMenuTableViewDeleteSelection(_ tableView: BookmarkMenuTableView)
    func bookmarkMenuTableViewOpenSelection(_ tableView: BookmarkMenuTableView)
    func bookmarkMenuTableViewCancel(_ tableView: BookmarkMenuTableView) -> Bool
    func bookmarkMenuTableView(
        _ tableView: BookmarkMenuTableView,
        nextSelectableRowAfter row: Int
    ) -> Int?
}

extension BookmarkMenuTableViewDelegate {
    func bookmarkMenuTableViewCancel(_ tableView: BookmarkMenuTableView) -> Bool {
        false
    }

    func bookmarkMenuTableView(
        _ tableView: BookmarkMenuTableView,
        nextSelectableRowAfter row: Int
    ) -> Int? {
        nil
    }
}

/// Centralized hover tracking. Per-row NSTrackingAreas are unreliable inside
/// scroll views — during inertial scroll, mouseEntered fires for rows passing
/// under the cursor while paired mouseExited events are frequently dropped,
/// leaving multiple rows stuck in the hovered state. We instead derive hover
/// from a single source: the actual cursor position, computed via
/// `row(at:)`. Cursor-driven recomputation runs on mouseMoved events and on
/// scroll-driven content bounds changes (see Coordinator). One row at a time;
/// no enter/exit pairing to lose.
final class HoverTableView: BookmarkMenuTableView {
    weak var hoverDelegate: HoverTableViewDelegate?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        hoverDelegate?.hoverTableView(self, didHoverRow: row(at: point))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverDelegate?.hoverTableView(self, didHoverRow: -1)
    }

    func updateHoverFromCurrentMouse() {
        guard let window else { return }
        let mouse = window.mouseLocationOutsideOfEventStream
        let point = convert(mouse, from: nil)
        let inside = bounds.contains(point) && visibleRect.contains(point)
        hoverDelegate?.hoverTableView(self, didHoverRow: inside ? row(at: point) : -1)
    }
}

class BookmarkMenuTableView: NSTableView {
    weak var menuDelegate: BookmarkMenuTableViewDelegate?

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.numericPad)

        if modifiers == .command, characters == "c" {
            menuDelegate?.bookmarkMenuTableViewCopySelection(self)
            return
        }

        if modifiers == .command, characters == "e" {
            menuDelegate?.bookmarkMenuTableViewEditSelection(self)
            return
        }

        if modifiers.isEmpty,
           event.keyCode == UInt16(kVK_Escape),
           menuDelegate?.bookmarkMenuTableViewCancel(self) == true {
            return
        }

        if modifiers.isEmpty, event.keyCode == UInt16(kVK_Tab) {
            moveSelectionDownLikeArrow()
            return
        }

        if modifiers.isEmpty, event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            menuDelegate?.bookmarkMenuTableViewDeleteSelection(self)
            return
        }

        if modifiers.isEmpty, event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            menuDelegate?.bookmarkMenuTableViewOpenSelection(self)
            return
        }

        super.keyDown(with: event)
    }

    override func insertTab(_ sender: Any?) {
        moveSelectionDownLikeArrow()
    }

    override func insertTabIgnoringFieldEditor(_ sender: Any?) {
        moveSelectionDownLikeArrow()
    }

    private func moveSelectionDownLikeArrow() {
        let currentRow = selectedRowIndexes.max() ?? -1
        guard let nextRow = menuDelegate?.bookmarkMenuTableView(self, nextSelectableRowAfter: currentRow) else {
            return
        }
        selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
        scrollRowToVisible(nextRow)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0, menuDelegate?.bookmarkMenuTableView(self, shouldSelectContextRow: row) == true else {
            return nil
        }

        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        return menuDelegate?.bookmarkMenuTableView(self, menuForRow: row)
    }
}

private final class HoverableRowView: NSTableRowView {
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isEmphasized: Bool {
        didSet {
            guard isEmphasized != oldValue, isSelected else { return }
            needsDisplay = true
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isHovered, !isSelected else { return }
        drawRoundedBackground(color: NSColor.labelColor.withAlphaComponent(0.08))
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let color: NSColor = isEmphasized
            ? .selectedContentBackgroundColor
            : .unemphasizedSelectedContentBackgroundColor
        drawRoundedBackground(color: color)
    }

    private func drawRoundedBackground(color: NSColor) {
        let inset = bounds.insetBy(dx: 10, dy: 2)
        let path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
        color.setFill()
        path.fill()
    }
}

private final class BookmarkHeaderCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("BookmarkHeaderCell")
    private let titleField = NSTextField(labelWithString: "")
    private let sortButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private var titleCenterYConstraint: NSLayoutConstraint?
    fileprivate var sortScope: BookmarkListSortScope?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentHuggingPriority(.required, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleField)

        sortButton.translatesAutoresizingMaskIntoConstraints = false
        sortButton.bezelStyle = .rounded
        sortButton.controlSize = .regular
        sortButton.font = .systemFont(ofSize: 12, weight: .medium)
        sortButton.setContentHuggingPriority(.required, for: .horizontal)
        sortButton.heightAnchor.constraint(equalToConstant: NativeBookmarkList.headerSortControlHeight).isActive = true
        if let cell = sortButton.cell as? NSPopUpButtonCell {
            cell.alignment = .left
        }
        sortButton.menu = Self.makeSortMenu()
        addSubview(sortButton)

        titleCenterYConstraint = titleField.centerYAnchor.constraint(
            equalTo: topAnchor,
            constant: NativeBookmarkList.headerHeight / 2
        )
        NSLayoutConstraint.activate([
            titleCenterYConstraint!,
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: NativeBookmarkList.contentInset),
            sortButton.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 8),
            sortButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -NativeBookmarkList.contentInset),
            sortButton.centerYAnchor.constraint(equalTo: titleField.centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        topSpacing: CGFloat,
        sortMode: BookmarkListSortMode?,
        sortScope: BookmarkListSortScope?,
        target: AnyObject?,
        action: Selector
    ) {
        titleField.stringValue = title
        let rowHeight = topSpacing + NativeBookmarkList.headerHeight + NativeBookmarkList.headerBottomSpacing
        titleCenterYConstraint?.constant = rowHeight / 2
        sortButton.isHidden = sortMode == nil
        self.sortScope = sortScope
        sortButton.target = target
        sortButton.action = action
        if let sortMode {
            let item = sortButton.menu?.items.first {
                ($0.representedObject as? String) == sortMode.rawValue
            }
            sortButton.select(item)
        }
    }

    private static func makeSortMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in BookmarkListSortMode.allCases {
            let item = NSMenuItem(title: mode.title, action: nil, keyEquivalent: "")
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }
        return menu
    }
}

private final class BrowserHistoryHeaderCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("BrowserHistoryHeaderCell")

    private let disclosureView = DisclosureChevronView()
    private let titleField = NSTextField(labelWithString: "")

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            applyNativeTextColor()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier

        disclosureView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(disclosureView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentHuggingPriority(.required, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleField)

        NSLayoutConstraint.activate([
            disclosureView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: NativeBookmarkList.contentInset),
            disclosureView.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureView.widthAnchor.constraint(equalToConstant: 12),
            disclosureView.heightAnchor.constraint(equalToConstant: 12),
            titleField.leadingAnchor.constraint(equalTo: disclosureView.trailingAnchor, constant: 6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -NativeBookmarkList.contentInset)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        isExpanded: Bool,
        target: AnyObject?,
        action: Selector
    ) {
        titleField.stringValue = title
        disclosureView.isExpanded = isExpanded
        applyNativeTextColor()
    }

    private func applyNativeTextColor() {
        let selected = backgroundStyle == .emphasized
        let color: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        titleField.textColor = color
        disclosureView.strokeColor = color
    }
}

private final class DisclosureChevronView: NSView {
    var strokeColor = NSColor.labelColor {
        didSet {
            needsDisplay = true
        }
    }

    var isExpanded = false {
        didSet {
            guard oldValue != isExpanded else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let horizontal: CGFloat = 3.4
        let vertical: CGFloat = 2.85
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        if isExpanded {
            path.move(to: NSPoint(x: center.x - horizontal, y: center.y - vertical / 2))
            path.line(to: NSPoint(x: center.x, y: center.y + vertical))
            path.line(to: NSPoint(x: center.x + horizontal, y: center.y - vertical / 2))
        } else {
            path.move(to: NSPoint(x: center.x - vertical / 2, y: center.y - horizontal))
            path.line(to: NSPoint(x: center.x + vertical, y: center.y))
            path.line(to: NSPoint(x: center.x - vertical / 2, y: center.y + horizontal))
        }

        strokeColor.setStroke()
        path.stroke()
    }
}

private final class BookmarkTableCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("BookmarkTableCell")

    private static let faviconEdge: CGFloat = 18
    private static let referenceBadgeDiameter = FaviconReferenceBadge.badgeDiameter(forFaviconEdge: faviconEdge)
    private static let faviconLayoutSize = FaviconReferenceBadge.layoutCanvasSize(forFaviconEdge: faviconEdge)

    private let faviconContainer = NSView()
    private let sourceIconView = NSImageView()
    private let faviconView = NSImageView()
    private let referenceBadgeView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let urlField = NSTextField(labelWithString: "")
    private var textTrailingConstraint: NSLayoutConstraint?
    private var faviconLeadingConstraint: NSLayoutConstraint?
    private var faviconLeadingWithSourceConstraint: NSLayoutConstraint?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            applyNativeTextColors()
        }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        clipsToBounds = false
        faviconContainer.translatesAutoresizingMaskIntoConstraints = false
        faviconContainer.clipsToBounds = false

        sourceIconView.translatesAutoresizingMaskIntoConstraints = false
        sourceIconView.imageScaling = .scaleProportionallyUpOrDown
        sourceIconView.isHidden = true

        faviconView.translatesAutoresizingMaskIntoConstraints = false
        faviconView.imageScaling = .scaleProportionallyUpOrDown

        referenceBadgeView.translatesAutoresizingMaskIntoConstraints = false
        referenceBadgeView.imageScaling = .scaleProportionallyUpOrDown
        referenceBadgeView.isHidden = true

        faviconContainer.addSubview(faviconView)
        faviconContainer.addSubview(referenceBadgeView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.usesSingleLineMode = true
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = titleField

        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.font = .systemFont(ofSize: 11)
        urlField.textColor = .secondaryLabelColor
        urlField.lineBreakMode = .byTruncatingMiddle
        urlField.usesSingleLineMode = true
        urlField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        [sourceIconView, faviconContainer, titleField, urlField].forEach(addSubview)

        textTrailingConstraint = titleField.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -NativeBookmarkList.contentInset
        )

        let badgeDiameter = Self.referenceBadgeDiameter
        let badgeOffset = FaviconReferenceBadge.badgeCenterOffset(forFaviconEdge: Self.faviconEdge)
        faviconLeadingConstraint = faviconContainer.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: NativeBookmarkList.contentInset
        )
        faviconLeadingWithSourceConstraint = faviconContainer.leadingAnchor.constraint(
            equalTo: sourceIconView.trailingAnchor,
            constant: 8
        )

        NSLayoutConstraint.activate([
            sourceIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: NativeBookmarkList.contentInset),
            sourceIconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            sourceIconView.widthAnchor.constraint(equalToConstant: 16),
            sourceIconView.heightAnchor.constraint(equalToConstant: 16),

            faviconLeadingConstraint!,
            faviconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            faviconContainer.widthAnchor.constraint(equalToConstant: Self.faviconLayoutSize.width),
            faviconContainer.heightAnchor.constraint(equalToConstant: Self.faviconLayoutSize.height),

            faviconView.leadingAnchor.constraint(equalTo: faviconContainer.leadingAnchor),
            faviconView.centerYAnchor.constraint(equalTo: sourceIconView.centerYAnchor),
            faviconView.widthAnchor.constraint(equalToConstant: Self.faviconEdge),
            faviconView.heightAnchor.constraint(equalToConstant: Self.faviconEdge),

            referenceBadgeView.widthAnchor.constraint(equalToConstant: badgeDiameter),
            referenceBadgeView.heightAnchor.constraint(equalToConstant: badgeDiameter),
            referenceBadgeView.centerXAnchor.constraint(equalTo: faviconView.trailingAnchor, constant: badgeOffset.width),
            referenceBadgeView.centerYAnchor.constraint(equalTo: faviconView.bottomAnchor, constant: -badgeOffset.height),

            titleField.leadingAnchor.constraint(equalTo: faviconContainer.trailingAnchor, constant: 12),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textTrailingConstraint!,

            urlField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            urlField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            urlField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        bookmark: Bookmark,
        showsURLHostOnly: Bool,
        favicon: NSImage?,
        referenceIndicatorSystemImage: String?,
        sourceIcon: NSImage? = nil
    ) {
        sourceIconView.image = sourceIcon
        sourceIconView.isHidden = sourceIcon == nil
        faviconLeadingConstraint?.isActive = false
        faviconLeadingWithSourceConstraint?.isActive = false
        if sourceIcon == nil {
            faviconLeadingConstraint?.isActive = true
        } else {
            faviconLeadingWithSourceConstraint?.isActive = true
        }

        let canvasSize = NSSize(width: Self.faviconEdge, height: Self.faviconEdge)
        faviconView.image = favicon ?? AppIcon.faviconPlaceholder(size: canvasSize)
        faviconView.contentTintColor = nil

        if let referenceIndicatorSystemImage {
            referenceBadgeView.image = FaviconReferenceBadge.badgeImage(
                diameter: Self.referenceBadgeDiameter,
                systemImageName: referenceIndicatorSystemImage
            )
            referenceBadgeView.isHidden = false
        } else {
            referenceBadgeView.image = nil
            referenceBadgeView.isHidden = true
        }
        titleField.stringValue = bookmark.title
        urlField.stringValue = displayURL(for: bookmark.url, showsHostOnly: showsURLHostOnly)
        applyNativeTextColors()
    }

    private func displayURL(for urlString: String, showsHostOnly: Bool) -> String {
        guard showsHostOnly, let host = URL(string: urlString)?.host(percentEncoded: false) else {
            return urlString
        }
        return host
    }

    private func applyNativeTextColors() {
        let selected = backgroundStyle == .emphasized
        titleField.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        urlField.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
}
