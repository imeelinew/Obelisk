import AppKit
import Carbon.HIToolbox
import SwiftUI
import ObeliskCore

struct BookmarkCollectionAssignOption: Equatable {
    var title: String
    var collectionId: UUID?
}

struct BookmarkListSection: Equatable, Identifiable {
    var title: String?
    var bookmarks: [Bookmark]
    var sortMode: BookmarkListSortMode?
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
    var onSortModeChange: ((BookmarkListSortMode) -> Void)? = nil
    var collectionAssignOptions: [BookmarkCollectionAssignOption] = []
    var onAssignCollection: ((Set<Bookmark.ID>, UUID?) -> Void)? = nil
    var onRenameCollection: ((UUID) -> Void)? = nil
    var onDeleteCollection: ((UUID) -> Void)? = nil
    fileprivate static let contentInset: CGFloat = 18
    fileprivate static let rowHeight: CGFloat = 50
    fileprivate static let headerHeight: CGFloat = 24

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
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let tableView = HoverTableView()
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
           context.coordinator.cachedFaviconVersion != faviconVersion {
            context.coordinator.cachedFaviconVersion = faviconVersion
            context.coordinator.items = nextItems
            context.coordinator.reloadTable()
        } else {
            context.coordinator.syncSelectionToTable()
        }
    }

    private static let columnIdentifier = NSUserInterfaceItemIdentifier("BookmarkColumn")

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, HoverTableViewDelegate, BookmarkMenuTableViewDelegate {
        var parent: NativeBookmarkList
        fileprivate var items: [NativeBookmarkListItem] = []
        weak var scrollView: NSScrollView?
        weak var tableView: HoverTableView?
        private var isSyncingSelection = false
        private var hoveredRow: Int = -1
        fileprivate var cachedFaviconVersion: Int = -1

        init(_ parent: NativeBookmarkList) {
            self.parent = parent
            self.items = parent.sections.flattenedItems
        }

        func reloadTable() {
            guard let tableView, let scrollView else { return }
            if let column = tableView.tableColumns.first {
                column.width = max(scrollView.contentView.bounds.width, 100)
            }
            tableView.reloadData()
            syncSelectionToTable()
            // Row indices may have shifted after reload; clear stale hover and
            // re-derive from the current cursor location.
            applyHoveredRow(-1)
            tableView.updateHoverFromCurrentMouse()
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
            // Content moved under the cursor: even if the mouse hasn't moved,
            // the row beneath it has changed. Recompute from real cursor pos
            // so hovered state has exactly one source of truth.
            tableView?.updateHoverFromCurrentMouse()
        }

        // MARK: HoverTableViewDelegate

        func hoverTableView(_ tableView: HoverTableView, didHoverRow row: Int) {
            // Skip headers and out-of-range; treat them as "no hover".
            let resolved: Int
            if row >= 0, row < items.count, items[row].bookmark != nil {
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
            if previous >= 0,
               let view = tableView?.rowView(atRow: previous, makeIfNecessary: false) as? HoverableRowView {
                view.isHovered = false
            }
            if row >= 0,
               let view = tableView?.rowView(atRow: row, makeIfNecessary: false) as? HoverableRowView {
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
                if parent.onRenameCollection != nil {
                    menu.addItem(collectionMenuItem("重命名分组", action: #selector(renameCollectionFromMenu(_:)), collectionId: collectionId))
                }
                if parent.onDeleteCollection != nil {
                    if !menu.items.isEmpty {
                        menu.addItem(NSMenuItem.separator())
                    }
                    menu.addItem(destructiveCollectionMenuItem("删除分组", action: #selector(deleteCollectionFromMenu(_:)), collectionId: collectionId))
                }
                return menu.items.isEmpty ? nil : menu
            }

            guard let bookmark = items[row].bookmark else {
                return nil
            }

            let menu = NSMenu()

            if parent.onOpen != nil {
                menu.addItem(menuItem("打开", action: #selector(openFromMenu(_:)), bookmark: bookmark))
            }
            if parent.onCopyURL != nil {
                menu.addItem(menuItem("复制 URL", action: #selector(copyURLFromMenu(_:)), bookmark: bookmark))
            }
            if parent.onRefreshFavicon != nil {
                menu.addItem(menuItem("刷新 favicon", action: #selector(refreshFaviconFromMenu(_:)), bookmark: bookmark))
            }
            if parent.onEdit != nil {
                menu.addItem(menuItem("编辑", action: #selector(editFromMenu(_:)), bookmark: bookmark))
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
                moveItem.submenu = submenu
                menu.addItem(moveItem)
            }
            if let hiddenStateActionTitle = parent.hiddenStateActionTitle, parent.onSetHidden != nil {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(menuItem(hiddenStateActionTitle, action: #selector(setHiddenFromMenu(_:)), bookmark: bookmark))
            }
            if let archiveStateActionTitle = parent.archiveStateActionTitle, parent.onSetArchived != nil {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(menuItem(archiveStateActionTitle, action: #selector(setArchivedFromMenu(_:)), bookmark: bookmark))
            }
            if parent.onDelete != nil {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(destructiveMenuItem("删除", action: #selector(deleteFromMenu(_:)), bookmark: bookmark))
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

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            false
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard row >= 0, row < items.count else { return false }
            return items[row].bookmark != nil
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard row >= 0, row < items.count, items[row].bookmark != nil else {
                return nil
            }
            let view = HoverableRowView()
            view.isHovered = isRowHovered(row)
            return view
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row >= 0, row < items.count else { return Self.parentRowHeight }
            switch items[row] {
            case .header(_, let topSpacing, _, _):
                return NativeBookmarkList.headerHeight + topSpacing
            case .bookmark:
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
            case .header(let title, let topSpacing, let sortMode, _):
                let view = tableView.makeView(
                    withIdentifier: BookmarkHeaderCellView.identifier,
                    owner: self
                ) as? BookmarkHeaderCellView ?? BookmarkHeaderCellView()
                view.configure(
                    title: title,
                    topSpacing: topSpacing,
                    sortMode: sortMode,
                    target: self,
                    action: #selector(changeSortModeFromHeader(_:))
                )
                return view

            case .bookmark(let bookmark):
                let view = tableView.makeView(
                    withIdentifier: BookmarkTableCellView.identifier,
                    owner: self
                ) as? BookmarkTableCellView ?? BookmarkTableCellView()
                view.configure(
                    bookmark: bookmark,
                    showsURLHostOnly: parent.showsURLHostOnly,
                    favicon: parent.faviconLoader.image(for: bookmark.url)
                )
                return view
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let tableView else { return }
            var selectedIDs: Set<Bookmark.ID> = []

            for row in tableView.selectedRowIndexes {
                guard row >= 0, row < items.count, let bookmark = items[row].bookmark else {
                    continue
                }
                selectedIDs.insert(bookmark.id)
            }

            parent.selection = selectedIDs
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

        @objc private func changeSortModeFromHeader(_ sender: NSPopUpButton) {
            guard let rawValue = sender.selectedItem?.representedObject as? String,
                  let sortMode = BookmarkListSortMode(rawValue: rawValue)
            else {
                return
            }
            parent.onSortModeChange?(sortMode)
        }

        func syncSelectionToTable() {
            guard let tableView else { return }
            var rowIndexes = IndexSet()
            for (row, item) in items.enumerated() {
                if let bookmark = item.bookmark, parent.selection.contains(bookmark.id) {
                    rowIndexes.insert(row)
                }
            }

            isSyncingSelection = true
            tableView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
            isSyncingSelection = false
        }

        private func menuItem(_ title: String, action: Selector, bookmark: Bookmark) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = bookmark
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

        private func collectionMenuItem(_ title: String, action: Selector, collectionId: UUID) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = collectionId
            return item
        }

        private func destructiveCollectionMenuItem(_ title: String, action: Selector, collectionId: UUID) -> NSMenuItem {
            let item = collectionMenuItem(title, action: action, collectionId: collectionId)
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
            return item
        }

        private func destructiveMenuItem(_ title: String, action: Selector, bookmark: Bookmark) -> NSMenuItem {
            let item = menuItem(title, action: action, bookmark: bookmark)
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .foregroundColor: NSColor.systemRed
                ]
            )
            return item
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

fileprivate enum NativeBookmarkListItem: Equatable {
    case header(title: String, topSpacing: CGFloat, sortMode: BookmarkListSortMode?, collectionId: UUID?)
    case bookmark(Bookmark)

    var isHeader: Bool {
        if case .header = self { return true }
        return false
    }

    var bookmark: Bookmark? {
        if case .bookmark(let bookmark) = self { return bookmark }
        return nil
    }

    var collectionId: UUID? {
        if case .header(_, _, _, let collectionId) = self { return collectionId }
        return nil
    }
}

private extension Array where Element == BookmarkListSection {
    var flattenedItems: [NativeBookmarkListItem] {
        var items: [NativeBookmarkListItem] = []
        var hasVisibleHeader = false

        for section in self {
            if let title = section.title {
                items.append(
                    .header(
                        title: title,
                        topSpacing: hasVisibleHeader ? 12 : 0,
                        sortMode: section.sortMode,
                        collectionId: section.collectionId
                    )
                )
                hasVisibleHeader = true
            }
            items.append(contentsOf: section.bookmarks.map(NativeBookmarkListItem.bookmark))
        }

        return items
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
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers == .command, characters == "c" {
            menuDelegate?.bookmarkMenuTableViewCopySelection(self)
            return
        }

        if modifiers == .command, characters == "e" {
            menuDelegate?.bookmarkMenuTableViewEditSelection(self)
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

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isHovered, !isSelected else { return }
        let inset = bounds.insetBy(dx: 10, dy: 2)
        let path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        path.fill()
    }
}

private final class BookmarkHeaderCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("BookmarkHeaderCell")
    private let titleField = NSTextField(labelWithString: "")
    private let sortButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private var topConstraint: NSLayoutConstraint?
    private var sortButtonTopConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(titleField)

        sortButton.translatesAutoresizingMaskIntoConstraints = false
        sortButton.controlSize = .small
        sortButton.font = .systemFont(ofSize: 12)
        sortButton.setContentHuggingPriority(.required, for: .horizontal)
        sortButton.addItem(withTitle: BookmarkListSortMode.name.title)
        sortButton.addItem(withTitle: BookmarkListSortMode.recentlyAdded.title)
        sortButton.item(at: 0)?.representedObject = BookmarkListSortMode.name.rawValue
        sortButton.item(at: 1)?.representedObject = BookmarkListSortMode.recentlyAdded.rawValue
        addSubview(sortButton)

        topConstraint = titleField.topAnchor.constraint(equalTo: topAnchor)
        sortButtonTopConstraint = sortButton.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            topConstraint!,
            sortButtonTopConstraint!,
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
        target: AnyObject?,
        action: Selector
    ) {
        titleField.stringValue = title
        topConstraint?.constant = topSpacing
        sortButtonTopConstraint?.constant = topSpacing
        sortButton.isHidden = sortMode == nil
        sortButton.target = target
        sortButton.action = action
        if let sortMode {
            sortButton.selectItem(withTitle: sortMode.title)
        }
    }
}

private final class BookmarkTableCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("BookmarkTableCell")

    private let faviconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let urlField = NSTextField(labelWithString: "")

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            applyNativeTextColors()
        }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        faviconView.translatesAutoresizingMaskIntoConstraints = false
        faviconView.imageScaling = .scaleProportionallyUpOrDown

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13)
        titleField.lineBreakMode = .byTruncatingTail
        textField = titleField

        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.font = .systemFont(ofSize: 11)
        urlField.textColor = .secondaryLabelColor
        urlField.lineBreakMode = .byTruncatingMiddle

        [faviconView, titleField, urlField].forEach(addSubview)

        NSLayoutConstraint.activate([
            faviconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: NativeBookmarkList.contentInset),
            faviconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            faviconView.widthAnchor.constraint(equalToConstant: 18),
            faviconView.heightAnchor.constraint(equalToConstant: 18),

            titleField.leadingAnchor.constraint(equalTo: faviconView.trailingAnchor, constant: 12),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -NativeBookmarkList.contentInset),

            urlField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            urlField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            urlField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(bookmark: Bookmark, showsURLHostOnly: Bool, favicon: NSImage?) {
        if let favicon {
            faviconView.image = favicon
            faviconView.contentTintColor = nil
        } else {
            faviconView.image = AppIcon.faviconPlaceholder(size: NSSize(width: 18, height: 18))
            faviconView.contentTintColor = nil
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
