import AppKit
import Carbon.HIToolbox
import ObeliskCore
import SwiftUI

struct BookmarkCollectionAssignOption: Equatable {
    var title: String
    var collectionId: UUID?
}

struct BookmarkListSection: Equatable, Identifiable {
    var title: String?
    var bookmarks: [Bookmark]

    var id: String {
        return title ?? bookmarks.map(\.id.uuidString).joined(separator: ",")
    }
}

struct NativeBookmarkList: NSViewRepresentable {
    var sections: [BookmarkListSection]
    @Binding var selection: Set<Bookmark.ID>
    var focusSelectedBookmarkRequest: Int = 0
    var onCancel: (() -> Void)?
    var faviconLoader: FaviconLoader
    var faviconVersion: Int
    var showsURLHostOnly: Bool = false

    var onOpen: (([Bookmark]) -> Void)?
    var onCopyURL: (([Bookmark]) -> Void)?
    var onEdit: ((Bookmark) -> Void)?
    var onDelete: ((Set<Bookmark.ID>) -> Void)?
    var hiddenStateActionTitle: String?
    var onSetHidden: ((Set<Bookmark.ID>) -> Void)?
    var archiveStateActionTitle: String? = nil
    var archiveStateActionTitleProvider: (([Bookmark]) -> String)? = nil
    var onSetArchived: ((Set<Bookmark.ID>) -> Void)? = nil
    var collectionAssignOptions: [BookmarkCollectionAssignOption] = []
    var onAssignCollection: ((Set<Bookmark.ID>, UUID?) -> Void)? = nil
    var onRevertTitleOptimization: ((Set<Bookmark.ID>) -> Void)? = nil
    var onRetryTitleOptimization: ((Set<Bookmark.ID>) -> Void)? = nil
    static let contentInset: CGFloat = 18
    static let rowHeight: CGFloat = 50
    static let headerHeight: CGFloat = 24
    static let headerBottomSpacing: CGFloat = 10
    static let headerSortControlHeight: CGFloat = 24
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
        tableView.menuDelegate = context.coordinator
        tableView.hoverDelegate = context.coordinator
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
            // prepared rows instead of rebuilding the whole table so selection
            // and scroll state stay intact.
            context.coordinator.cachedFaviconVersion = faviconVersion
            context.coordinator.reloadPreparedRows()
        } else {
            context.coordinator.syncSelectionToTable()
        }
        context.coordinator.handleFocusSelectedBookmarkRequestIfNeeded()
    }

    private static let columnIdentifier = NSUserInterfaceItemIdentifier("BookmarkColumn")

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, HoverTableViewDelegate, BookmarkMenuTableViewDelegate {
        var parent: NativeBookmarkList
        fileprivate var items: [NativeBookmarkListItem] = []
        weak var scrollView: NSScrollView?
        weak var tableView: HoverTableView?
        private var isSyncingSelection = false
        private var hoveredRow = -1
        fileprivate var cachedFaviconVersion: Int = -1
        fileprivate var cachedShowsURLHostOnly = false
        private var handledFocusSelectedBookmarkRequest = 0
        private var bookmarkContextMenuController: NativeBookmarkContextMenuController?

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
            tableView?.updateHoverFromCurrentMouse()
        }

        func hoverTableView(_ tableView: HoverTableView, didHoverRow row: Int) {
            let resolved = row >= 0 && row < items.count && items[row].bookmark != nil ? row : -1
            applyHoveredRow(resolved)
        }

        private func applyHoveredRow(_ row: Int) {
            guard row != hoveredRow else { return }
            let previous = hoveredRow
            hoveredRow = row

            guard let tableView else { return }
            if previous >= 0,
               previous < tableView.numberOfRows,
               let view = tableView.rowView(atRow: previous, makeIfNecessary: false) as? HoverableRowView {
                view.isHovered = false
            }
            if row >= 0,
               row < tableView.numberOfRows,
               let view = tableView.rowView(atRow: row, makeIfNecessary: false) as? HoverableRowView {
                view.isHovered = true
            }
        }

        func bookmarkMenuTableView(_ tableView: BookmarkMenuTableView, shouldSelectContextRow row: Int) -> Bool {
            guard row >= 0, row < items.count else { return false }
            return items[row].bookmark != nil
        }

        func bookmarkMenuTableView(_ tableView: BookmarkMenuTableView, menuForRow row: Int) -> NSMenu? {
            guard row >= 0, row < items.count else { return nil }

            guard let bookmark = items[row].bookmark else {
                return nil
            }

            let targets = targetBookmarks(contextBookmark: bookmark)
            var configuration = NativeBookmarkContextMenuConfiguration()

            if parent.onOpen != nil {
                configuration.onOpen = { [weak self] in
                    guard let self else { return }
                    parent.onOpen?(targetBookmarks(contextBookmark: bookmark))
                }
            }
            if parent.onCopyURL != nil {
                configuration.onCopyURL = { [weak self] in
                    guard let self else { return }
                    parent.onCopyURL?(targetBookmarks(contextBookmark: bookmark))
                }
            }
            if parent.onEdit != nil, targets.count == 1 {
                configuration.onEdit = { [weak self] in
                    guard let self else { return }
                    let currentTargets = targetBookmarks(contextBookmark: bookmark)
                    guard currentTargets.count == 1, let target = currentTargets.first else { return }
                    parent.onEdit?(target)
                }
            }
            if parent.onRevertTitleOptimization != nil,
               selectionHasRevertableTitleOptimization(contextBookmark: bookmark) {
                configuration.onRevertTitleOptimization = { [weak self] in
                    guard let self else { return }
                    parent.onRevertTitleOptimization?(targetBookmarkIDs(contextBookmark: bookmark))
                }
            }
            if parent.onRetryTitleOptimization != nil,
               targets.contains(where: { $0.titleOptimizationState == .failed }) {
                configuration.onRetryTitleOptimization = { [weak self] in
                    guard let self else { return }
                    parent.onRetryTitleOptimization?(targetBookmarkIDs(contextBookmark: bookmark))
                }
            }
            if !parent.collectionAssignOptions.isEmpty, parent.onAssignCollection != nil {
                configuration.collectionAssignOptions = parent.collectionAssignOptions
                configuration.onAssignCollection = { [weak self] collectionId in
                    guard let self else { return }
                    parent.onAssignCollection?(targetBookmarkIDs(contextBookmark: bookmark), collectionId)
                }
            }
            if let title = parent.hiddenStateActionTitle, parent.onSetHidden != nil {
                configuration.hiddenStateActionTitle = title
                configuration.hiddenStateSystemSymbolName = restoreBookmarkSymbolName(
                    for: title,
                    defaultSymbolName: "eye.slash"
                )
                configuration.onSetHidden = { [weak self] in
                    guard let self else { return }
                    parent.onSetHidden?(targetBookmarkIDs(contextBookmark: bookmark))
                }
            }
            if let title = archiveActionTitle(contextBookmark: bookmark), parent.onSetArchived != nil {
                configuration.archiveStateActionTitle = title
                configuration.archiveStateSystemSymbolName = restoreBookmarkSymbolName(
                    for: title,
                    defaultSymbolName: "archivebox"
                )
                configuration.onSetArchived = { [weak self] in
                    guard let self else { return }
                    parent.onSetArchived?(targetBookmarkIDs(contextBookmark: bookmark))
                }
            }
            if parent.onDelete != nil {
                configuration.onDelete = { [weak self] in
                    guard let self else { return }
                    parent.onDelete?(targetBookmarkIDs(contextBookmark: bookmark))
                }
            }

            let controller = NativeBookmarkContextMenuController()
            guard let menu = controller.makeMenu(configuration: configuration) else { return nil }
            bookmarkContextMenuController = controller
            return menu
        }

        func bookmarkMenuTableViewCopySelection(_ tableView: BookmarkMenuTableView) {
            let bookmarks = selectedBookmarks()
            guard !bookmarks.isEmpty else { return }
            parent.onCopyURL?(bookmarks)
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
            let bookmarks = selectedBookmarks()
            guard !bookmarks.isEmpty else { return }
            parent.onOpen?(bookmarks)
        }

        func bookmarkMenuTableViewCancel(_ tableView: BookmarkMenuTableView) -> Bool {
            let hasBookmarkSelection = !parent.selection.isEmpty
            if hasBookmarkSelection {
                parent.selection = []
                isSyncingSelection = true
                tableView.deselectAll(nil)
                isSyncingSelection = false
                return true
            }
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
                items[candidate].bookmark != nil
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
            return false
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard row >= 0,
                  row < items.count,
                  items[row].bookmark != nil
            else {
                return nil
            }
            let view = HoverableRowView()
            view.isHovered = row == hoveredRow
            return view
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row >= 0, row < items.count else { return Self.parentRowHeight }
            switch items[row] {
            case .header(_, let topSpacing):
                return NativeBookmarkList.headerHeight + topSpacing + NativeBookmarkList.headerBottomSpacing
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
            case .header(let title, let topSpacing):
                let view = tableView.makeView(
                    withIdentifier: BookmarkHeaderCellView.identifier,
                    owner: self
                ) as? BookmarkHeaderCellView ?? BookmarkHeaderCellView()
                view.configure(
                    title: title,
                    topSpacing: topSpacing
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
            let resolvedSelection = NativeBookmarkSelectionResolver.selection(
                from: tableView.selectedRowIndexes,
                in: items
            )

            parent.selection = resolvedSelection.bookmarkIDs
        }

        @objc func handleDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < items.count, let bookmark = items[row].bookmark else {
                return
            }
            parent.onOpen?([bookmark])
        }

        private func selectionHasRevertableTitleOptimization(contextBookmark: Bookmark) -> Bool {
            targetBookmarkIDs(contextBookmark: contextBookmark).contains { id in
                guard let bookmark = bookmark(for: id) else { return false }
                guard bookmark.titleOptimizationState == .succeeded else { return false }
                let original = bookmark.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !original.isEmpty
            }
        }

        private func bookmark(for id: Bookmark.ID) -> Bookmark? {
            items.compactMap(\.bookmark).first { $0.id == id }
        }

        private func targetBookmarkIDs(contextBookmark: Bookmark) -> Set<Bookmark.ID> {
            parent.selection.isEmpty ? [contextBookmark.id] : parent.selection
        }

        private func targetBookmarks(contextBookmark: Bookmark) -> [Bookmark] {
            let ids = targetBookmarkIDs(contextBookmark: contextBookmark)
            return items.compactMap(\.bookmark).filter { ids.contains($0.id) }
        }

        private func selectedBookmarks() -> [Bookmark] {
            items.compactMap(\.bookmark).filter { parent.selection.contains($0.id) }
        }

        private func archiveActionTitle(contextBookmark: Bookmark) -> String? {
            if let provider = parent.archiveStateActionTitleProvider {
                return provider(targetBookmarks(contextBookmark: contextBookmark))
            }
            return parent.archiveStateActionTitle
        }

        func syncSelectionToTable() {
            guard let tableView else { return }
            let rowIndexes = NativeBookmarkSelectionResolver.rowIndexes(
                for: parent.selection,
                in: items
            )

            isSyncingSelection = true
            tableView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
            isSyncingSelection = false
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

        private func restoreBookmarkSymbolName(for title: String, defaultSymbolName: String) -> String {
            let restoreTitle = "恢复到书签"
            if title == restoreTitle || title == restoreTitle.obeliskLocalized {
                return "bookmark"
            }
            return defaultSymbolName
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
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let inside = bounds.contains(point) && visibleRect.contains(point)
        hoverDelegate?.hoverTableView(self, didHoverRow: inside ? row(at: point) : -1)
    }
}

class BookmarkMenuTableView: NSTableView {
    weak var menuDelegate: BookmarkMenuTableViewDelegate?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        guard hitView != nil,
              NativeContextMenuEventView.handlesContextMenuEvent(NSApp.currentEvent) else {
            return hitView
        }

        // Route contextual clicks directly to the table that owns the menu
        // instead of depending on labels and image controls to forward them
        let row = row(at: convert(point, from: superview))
        guard row >= 0,
              menuDelegate?.bookmarkMenuTableView(self, shouldSelectContextRow: row) == true else {
            return hitView
        }
        return self
    }

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

final class HoverableRowView: NSTableRowView {
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
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
        drawRoundedBackground(color: .unemphasizedSelectedContentBackgroundColor)
    }

    private func drawRoundedBackground(color: NSColor) {
        let inset = bounds.insetBy(dx: 10, dy: 2)
        let path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
        color.setFill()
        path.fill()
    }
}

final class BookmarkHeaderCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("BookmarkHeaderCell")
    private let titleField = NSTextField(labelWithString: "")
    private var titleCenterYConstraint: NSLayoutConstraint?

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

        titleCenterYConstraint = titleField.centerYAnchor.constraint(
            equalTo: topAnchor,
            constant: NativeBookmarkList.headerHeight / 2
        )
        NSLayoutConstraint.activate([
            titleCenterYConstraint!,
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: NativeBookmarkList.contentInset),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -NativeBookmarkList.contentInset)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, topSpacing: CGFloat) {
        titleField.stringValue = title
        let rowHeight = topSpacing + NativeBookmarkList.headerHeight + NativeBookmarkList.headerBottomSpacing
        titleCenterYConstraint?.constant = rowHeight / 2
    }
}

final class BookmarkTableCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("BookmarkTableCell")

    private static let faviconEdge: CGFloat = 18
    private static let faviconLayoutSize = NSSize(width: faviconEdge, height: faviconEdge)

    private let faviconContainer = NSView()
    private let faviconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let urlField = NSTextField(labelWithString: "")
    private var textTrailingConstraint: NSLayoutConstraint?
    private var faviconLeadingConstraint: NSLayoutConstraint?

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

        faviconView.translatesAutoresizingMaskIntoConstraints = false
        faviconView.imageScaling = .scaleProportionallyUpOrDown

        faviconContainer.addSubview(faviconView)

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

        [faviconContainer, titleField, urlField].forEach(addSubview)

        textTrailingConstraint = titleField.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -NativeBookmarkList.contentInset
        )

        faviconLeadingConstraint = faviconContainer.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: NativeBookmarkList.contentInset
        )

        NSLayoutConstraint.activate([
            faviconLeadingConstraint!,
            faviconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            faviconContainer.widthAnchor.constraint(equalToConstant: Self.faviconLayoutSize.width),
            faviconContainer.heightAnchor.constraint(equalToConstant: Self.faviconLayoutSize.height),

            faviconView.leadingAnchor.constraint(equalTo: faviconContainer.leadingAnchor),
            faviconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            faviconView.widthAnchor.constraint(equalToConstant: Self.faviconEdge),
            faviconView.heightAnchor.constraint(equalToConstant: Self.faviconEdge),

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
        favicon: NSImage?
    ) {
        let canvasSize = NSSize(width: Self.faviconEdge, height: Self.faviconEdge)
        faviconView.image = favicon ?? AppIcon.faviconPlaceholder(size: canvasSize)
        faviconView.contentTintColor = nil

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
