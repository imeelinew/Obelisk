import AppKit
import SwiftUI
import UniBookmarkCore

struct BookmarkListSection: Equatable, Identifiable {
    var title: String?
    var bookmarks: [Bookmark]

    var id: String {
        title ?? bookmarks.map(\.id.uuidString).joined(separator: ",")
    }
}

struct NativeBookmarkList: NSViewRepresentable {
    var sections: [BookmarkListSection]
    @Binding var selection: Set<Bookmark.ID>
    var faviconLoader: FaviconLoader
    var faviconVersion: Int
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
        if context.coordinator.items != nextItems {
            context.coordinator.items = nextItems
            context.coordinator.reloadTable()
        } else {
            context.coordinator.syncSelectionToTable()
        }
    }

    private static let columnIdentifier = NSUserInterfaceItemIdentifier("BookmarkColumn")

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, HoverTableViewDelegate {
        var parent: NativeBookmarkList
        fileprivate var items: [NativeBookmarkListItem] = []
        weak var scrollView: NSScrollView?
        weak var tableView: HoverTableView?
        private var isSyncingSelection = false
        private var hoveredRow: Int = -1

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
            case .header(_, let topSpacing):
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
            case .header(let title, let topSpacing):
                let view = tableView.makeView(
                    withIdentifier: BookmarkHeaderCellView.identifier,
                    owner: self
                ) as? BookmarkHeaderCellView ?? BookmarkHeaderCellView()
                view.configure(title: title, topSpacing: topSpacing)
                return view

            case .bookmark(let bookmark):
                let view = tableView.makeView(
                    withIdentifier: BookmarkTableCellView.identifier,
                    owner: self
                ) as? BookmarkTableCellView ?? BookmarkTableCellView()
                view.configure(
                    bookmark: bookmark,
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

        private static let parentRowHeight = NativeBookmarkList.rowHeight
    }
}

fileprivate enum NativeBookmarkListItem: Equatable {
    case header(title: String, topSpacing: CGFloat)
    case bookmark(Bookmark)

    var isHeader: Bool {
        if case .header = self { return true }
        return false
    }

    var bookmark: Bookmark? {
        if case .bookmark(let bookmark) = self { return bookmark }
        return nil
    }
}

private extension Array where Element == BookmarkListSection {
    var flattenedItems: [NativeBookmarkListItem] {
        var items: [NativeBookmarkListItem] = []
        var hasVisibleHeader = false

        for section in self {
            if let title = section.title {
                items.append(.header(title: title, topSpacing: hasVisibleHeader ? 12 : 0))
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

/// Centralized hover tracking. Per-row NSTrackingAreas are unreliable inside
/// scroll views — during inertial scroll, mouseEntered fires for rows passing
/// under the cursor while paired mouseExited events are frequently dropped,
/// leaving multiple rows stuck in the hovered state. We instead derive hover
/// from a single source: the actual cursor position, computed via
/// `row(at:)`. Cursor-driven recomputation runs on mouseMoved events and on
/// scroll-driven content bounds changes (see Coordinator). One row at a time;
/// no enter/exit pairing to lose.
final class HoverTableView: NSTableView {
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
    private var topConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor
        addSubview(titleField)

        topConstraint = titleField.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            topConstraint!,
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: NativeBookmarkList.contentInset),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, topSpacing: CGFloat) {
        titleField.stringValue = title
        topConstraint?.constant = topSpacing
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

    func configure(bookmark: Bookmark, favicon: NSImage?) {
        if let favicon {
            faviconView.image = favicon
            faviconView.contentTintColor = nil
        } else {
            faviconView.image = AppIcon.image(size: NSSize(width: 18, height: 18))
            faviconView.contentTintColor = nil
        }
        titleField.stringValue = bookmark.title
        urlField.stringValue = bookmark.url
        applyNativeTextColors()
    }

    private func applyNativeTextColors() {
        let selected = backgroundStyle == .emphasized
        titleField.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        urlField.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
}
