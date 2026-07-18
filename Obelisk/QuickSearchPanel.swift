import AppKit
import ObeliskCore

private enum QuickSearchPanelLayout {
    static let contentSize = NSSize(width: 420, height: 520)
}

enum QuickSearchPanelToggleAction: Equatable {
    case show
    case hide

    static func resolve(isVisible: Bool) -> Self {
        isVisible ? .hide : .show
    }
}

struct QuickSearchPanelAlignmentResolution: Equatable {
    let frame: NSRect
}

enum QuickSearchPanelAlignmentResolver {
    static func resolve(
        frame: NSRect,
        visibleFrame: NSRect,
        alignsHorizontally: Bool,
        alignsVertically: Bool
    ) -> QuickSearchPanelAlignmentResolution {
        let target = NSPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        var resolvedFrame = frame
        if alignsHorizontally {
            resolvedFrame.origin.x = target.x - frame.width / 2
        }
        if alignsVertically {
            resolvedFrame.origin.y = target.y - frame.height / 2
        }

        return QuickSearchPanelAlignmentResolution(frame: resolvedFrame)
    }
}

@MainActor
enum QuickSearchPanelDragTargetResolver {
    static func allowsWindowDrag(from hitView: NSView?, within rootView: NSView) -> Bool {
        var view = hitView
        while let currentView = view {
            switch currentView {
            case is NSSearchField,
                 is NSTextView,
                 is NSScrollView,
                 is NSTableView,
                 is NSScroller,
                 is NSButton:
                return false
            default:
                break
            }
            if currentView === rootView {
                return true
            }
            view = currentView.superview
        }
        return false
    }
}

@MainActor
final class QuickSearchPanelController: NSObject, NSWindowDelegate {
    private static let frameAutosaveName = "ObeliskQuickSearchPanel"

    private let model: BookmarksModel
    private let contentController: QuickSearchViewController
    private var panel: QuickSearchPanel?

    init(model: BookmarksModel, faviconLoader: FaviconLoader) {
        self.model = model
        self.contentController = QuickSearchViewController(
            model: model,
            faviconLoader: faviconLoader
        )
        super.init()

        contentController.onOpen = { [weak self] bookmark in
            self?.hide()
            self?.model.openBookmark(bookmark)
        }
        contentController.onClose = { [weak self] in
            self?.hide()
        }
    }

    /// Builds and lays out the panel once during launch so the first shortcut
    /// press only changes window visibility.
    func prepare() {
        _ = panel ?? makePanel()
    }

    func toggle() {
        switch QuickSearchPanelToggleAction.resolve(isVisible: panel?.isVisible == true) {
        case .show:
            show()
        case .hide:
            hide()
        }
    }

    func show() {
        let panel = panel ?? makePanel()
        contentController.prepareForPresentation()
        panel.makeKeyAndOrderFront(nil)
        contentController.focusSearchField()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.cancelAlignmentDrag()
        panel.orderOut(nil)
        contentController.resetAfterDismissal()
    }

    func refreshResults() {
        contentController.reloadResults()
    }

    func refreshFaviconsIfVisible() {
        guard panel?.isVisible == true else { return }
        contentController.reloadVisibleBookmarkRows()
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func makePanel() -> QuickSearchPanel {
        let panel = QuickSearchPanel(
            contentRect: NSRect(origin: .zero, size: QuickSearchPanelLayout.contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "搜索书签".obeliskLocalized
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.isExcludedFromWindowsMenu = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        contentController.preferredContentSize = QuickSearchPanelLayout.contentSize
        panel.contentViewController = contentController
        panel.installAlignmentDragRecognizer(on: contentController.view)
        panel.contentMinSize = QuickSearchPanelLayout.contentSize
        panel.contentMaxSize = QuickSearchPanelLayout.contentSize
        panel.delegate = self
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let restoredFrame = panel.setFrameUsingName(Self.frameAutosaveName)
        // Frame autosave includes size. Always restore only the user's chosen
        // position and keep this fixed-purpose panel at its designed size.
        panel.setContentSize(QuickSearchPanelLayout.contentSize)
        _ = panel.setFrameAutosaveName(Self.frameAutosaveName)
        if !restoredFrame {
            centerOnPointerScreen(panel)
        }

        panel.contentView?.layoutSubtreeIfNeeded()
        self.panel = panel
        return panel
    }

    private func centerOnPointerScreen(_ panel: NSWindow) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }

        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        ))
    }
}

private final class QuickSearchPanel: NSPanel, NSGestureRecognizerDelegate {
    private let alignmentFeedbackFilter = NSAlignmentFeedbackFilter()
    private weak var alignmentDragRootView: NSView?
    private var alignmentDragRecognizer: NSPanGestureRecognizer?
    private var dragPointerOffset = NSPoint.zero
    private var lastPresentedFrame: NSRect?
    private var hasDragPointerOffset = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func installAlignmentDragRecognizer(on rootView: NSView) {
        let recognizer = NSPanGestureRecognizer(
            target: self,
            action: #selector(handleAlignmentDrag(_:))
        )
        recognizer.delegate = self
        recognizer.delaysPrimaryMouseButtonEvents = false
        rootView.addGestureRecognizer(recognizer)
        alignmentDragRootView = rootView
        alignmentDragRecognizer = recognizer
    }

    func cancelAlignmentDrag() {
        lastPresentedFrame = nil
        hasDragPointerOffset = false
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        guard event.type == .leftMouseDown,
              gestureRecognizer === alignmentDragRecognizer,
              let rootView = alignmentDragRootView else {
            return false
        }

        let location = rootView.convert(event.locationInWindow, from: nil)
        let hitView = rootView.hitTest(location)
        guard QuickSearchPanelDragTargetResolver.allowsWindowDrag(
            from: hitView,
            within: rootView
        ) else {
            return false
        }

        let pointer = convertPoint(toScreen: event.locationInWindow)
        dragPointerOffset = NSPoint(
            x: pointer.x - frame.origin.x,
            y: pointer.y - frame.origin.y
        )
        hasDragPointerOffset = true
        return true
    }

    @objc private func handleAlignmentDrag(_ recognizer: NSPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            alignmentFeedbackFilter.update(withPanRecognizer: recognizer)
            lastPresentedFrame = frame
        case .changed:
            alignmentFeedbackFilter.update(withPanRecognizer: recognizer)
            updateFrameForAlignmentDrag()
        case .ended, .cancelled:
            cancelAlignmentDrag()
        default:
            break
        }
    }

    private func updateFrameForAlignmentDrag() {
        guard hasDragPointerOffset else { return }

        let pointer = NSEvent.mouseLocation
        var defaultFrame = frame
        defaultFrame.origin = NSPoint(
            x: pointer.x - dragPointerOffset.x,
            y: pointer.y - dragPointerOffset.y
        )
        let alignmentScreen = screenContaining(pointer)
            ?? bestScreen(for: defaultFrame)
        guard let alignmentScreen else {
            setFrameOrigin(defaultFrame.origin)
            lastPresentedFrame = defaultFrame
            return
        }

        defaultFrame = constrainFrameRect(defaultFrame, to: alignmentScreen)
        let visibleFrame = alignmentScreen.visibleFrame
        let previousFrame = lastPresentedFrame ?? frame
        var feedbackTokens: [any NSAlignmentFeedbackToken] = []
        var alignsHorizontally = false
        var alignsVertically = false

        if let token = alignmentFeedbackFilter.alignmentFeedbackTokenForHorizontalMovement(
            in: nil,
            previousX: previousFrame.midX,
            alignedX: visibleFrame.midX,
            defaultX: defaultFrame.midX
        ) {
            alignsHorizontally = true
            feedbackTokens.append(token)
        }
        if let token = alignmentFeedbackFilter.alignmentFeedbackTokenForVerticalMovement(
            in: nil,
            previousY: previousFrame.midY,
            alignedY: visibleFrame.midY,
            defaultY: defaultFrame.midY
        ) {
            alignsVertically = true
            feedbackTokens.append(token)
        }

        let resolution = QuickSearchPanelAlignmentResolver.resolve(
            frame: defaultFrame,
            visibleFrame: visibleFrame,
            alignsHorizontally: alignsHorizontally,
            alignsVertically: alignsVertically
        )
        if !feedbackTokens.isEmpty {
            alignmentFeedbackFilter.performFeedback(feedbackTokens, performanceTime: .now)
        }
        setFrameOrigin(resolution.frame.origin)
        lastPresentedFrame = resolution.frame
    }

    private func screenContaining(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func bestScreen(for frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            intersectionArea(of: frame, with: lhs.frame)
                < intersectionArea(of: frame, with: rhs.frame)
        }
    }

    private func intersectionArea(of lhs: NSRect, with rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}

@MainActor
private final class QuickSearchViewController: NSViewController,
    NSSearchFieldDelegate,
    NSTableViewDataSource,
    NSTableViewDelegate,
    HoverTableViewDelegate,
    BookmarkMenuTableViewDelegate
{
    var onOpen: ((Bookmark) -> Void)?
    var onClose: (() -> Void)?

    private let model: BookmarksModel
    private let faviconLoader: FaviconLoader
    private let showsURLHostOnly: Bool
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let tableView = HoverTableView()
    private let emptyView = NSStackView()
    private var items: [NativeBookmarkListItem] = []
    private var hoveredRow = -1

    init(model: BookmarksModel, faviconLoader: FaviconLoader) {
        self.model = model
        self.faviconLoader = faviconLoader
        self.showsURLHostOnly = UserDefaults.standard.bool(forKey: "showsURLHostOnly")
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let frame = NSRect(origin: .zero, size: QuickSearchPanelLayout.contentSize)
        let contentView = NSView(frame: frame)
        contentView.autoresizingMask = [.width, .height]

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "搜索".obeliskLocalized
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .large
        searchField.bezelStyle = .roundedBezel
        searchField.delegate = self

        configureTableView()
        configureEmptyView()

        contentView.addSubview(searchField)
        contentView.addSubview(scrollView)
        contentView.addSubview(emptyView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),

            emptyView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        let glassView = NSGlassEffectView(frame: frame)
        glassView.autoresizingMask = [.width, .height]
        glassView.style = .regular
        glassView.cornerRadius = 20
        if #available(macOS 27.0, *) {
            glassView.effectIsInteractive = true
        }
        glassView.contentView = contentView
        view = glassView
        preferredContentSize = QuickSearchPanelLayout.contentSize

        reloadResults()
    }

    func prepareForPresentation() {
        loadViewIfNeeded()
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            reloadResults()
        }
        tableView.deselectAll(nil)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func resetAfterDismissal() {
        guard isViewLoaded else { return }
        tableView.deselectAll(nil)
        guard !searchField.stringValue.isEmpty else { return }
        searchField.stringValue = ""
        reloadResults()
    }

    func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
    }

    func reloadResults() {
        loadViewIfNeeded()
        let sections = model.bookmarkLibrarySections(
            for: model.searchBookmarks(matching: searchField.stringValue),
            pinnedSortMode: .storedForPinned,
            collectionSortMode: .storedForCollections,
            ungroupedSortMode: .storedForUngrouped
        )
        items = sections.flattenedItems
        hoveredRow = -1
        tableView.reloadData()
        tableView.deselectAll(nil)

        let hasResults = items.contains { $0.bookmark != nil }
        scrollView.isHidden = !hasResults
        emptyView.isHidden = hasResults
    }

    func reloadVisibleBookmarkRows() {
        guard !items.isEmpty else { return }
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.length > 0 else { return }
        let rows = IndexSet(
            IndexSet(integersIn: visibleRange.location ..< (visibleRange.location + visibleRange.length))
                .filter { items[$0].bookmark != nil }
        )
        guard !rows.isEmpty else { return }
        tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    private func configureTableView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none

        tableView.frame = scrollView.contentView.bounds
        tableView.autoresizingMask = [.width]
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.intercellSpacing = .zero
        tableView.rowSizeStyle = .custom
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.hoverDelegate = self
        tableView.menuDelegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openDoubleClickedRow(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("QuickSearchBookmarkColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        scrollView.documentView = tableView
    }

    private func configureEmptyView() {
        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)

        let label = NSTextField(labelWithString: "没有结果".obeliskLocalized)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .secondaryLabelColor

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        emptyView.orientation = .vertical
        emptyView.alignment = .centerX
        emptyView.spacing = 10
        emptyView.addArrangedSubview(imageView)
        emptyView.addArrangedSubview(label)
    }

    func controlTextDidChange(_ notification: Notification) {
        reloadResults()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        case #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.insertTabIgnoringFieldEditor(_:)),
             #selector(NSResponder.moveDown(_:)):
            focusFirstResult()
            return true
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            openFirstResult()
            return true
        default:
            return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        items.indices.contains(row) && items[row].bookmark != nil
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard items.indices.contains(row), items[row].bookmark != nil else { return nil }
        let rowView = HoverableRowView()
        rowView.isHovered = row == hoveredRow
        return rowView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard items.indices.contains(row) else { return NativeBookmarkList.rowHeight }
        switch items[row] {
        case .header(_, let topSpacing, _, _, _):
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
        guard items.indices.contains(row) else { return nil }

        switch items[row] {
        case .header(let title, let topSpacing, _, _, _):
            let cell = tableView.makeView(
                withIdentifier: BookmarkHeaderCellView.identifier,
                owner: self
            ) as? BookmarkHeaderCellView ?? BookmarkHeaderCellView()
            cell.configure(
                title: title,
                topSpacing: topSpacing,
                sortMode: nil,
                sortScope: nil,
                target: nil,
                action: #selector(noop(_:))
            )
            return cell

        case .bookmark(let bookmark, let referenceIndicatorSystemImage, _, _):
            let cell = tableView.makeView(
                withIdentifier: BookmarkTableCellView.identifier,
                owner: self
            ) as? BookmarkTableCellView ?? BookmarkTableCellView()
            cell.configure(
                bookmark: bookmark,
                showsURLHostOnly: showsURLHostOnly,
                favicon: faviconLoader.image(for: bookmark.url),
                referenceIndicatorSystemImage: referenceIndicatorSystemImage
            )
            return cell
        }
    }

    func hoverTableView(_ tableView: HoverTableView, didHoverRow row: Int) {
        let nextRow = items.indices.contains(row) && items[row].bookmark != nil ? row : -1
        guard nextRow != hoveredRow else { return }
        let previousRow = hoveredRow
        hoveredRow = nextRow

        if previousRow >= 0,
           let rowView = tableView.rowView(atRow: previousRow, makeIfNecessary: false) as? HoverableRowView {
            rowView.isHovered = false
        }
        if nextRow >= 0,
           let rowView = tableView.rowView(atRow: nextRow, makeIfNecessary: false) as? HoverableRowView {
            rowView.isHovered = true
        }
    }

    func bookmarkMenuTableView(_ tableView: BookmarkMenuTableView, shouldSelectContextRow row: Int) -> Bool {
        items.indices.contains(row) && items[row].bookmark != nil
    }

    func bookmarkMenuTableView(_ tableView: BookmarkMenuTableView, menuForRow row: Int) -> NSMenu? {
        guard items.indices.contains(row), items[row].bookmark != nil else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "打开".obeliskLocalized, action: #selector(openFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.tag = row
        menu.addItem(item)
        return menu
    }

    func bookmarkMenuTableViewCopySelection(_ tableView: BookmarkMenuTableView) {
        guard let bookmark = selectedBookmark else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bookmark.url, forType: .string)
    }

    func bookmarkMenuTableViewEditSelection(_ tableView: BookmarkMenuTableView) {}

    func bookmarkMenuTableViewDeleteSelection(_ tableView: BookmarkMenuTableView) {}

    func bookmarkMenuTableViewOpenSelection(_ tableView: BookmarkMenuTableView) {
        guard let bookmark = selectedBookmark else { return }
        onOpen?(bookmark)
    }

    func bookmarkMenuTableViewCancel(_ tableView: BookmarkMenuTableView) -> Bool {
        onClose?()
        return true
    }

    func bookmarkMenuTableView(
        _ tableView: BookmarkMenuTableView,
        nextSelectableRowAfter row: Int
    ) -> Int? {
        let start = max(row + 1, 0)
        guard start < items.count else { return nil }
        return items.indices[start...].first { items[$0].bookmark != nil }
    }

    @objc private func openDoubleClickedRow(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard items.indices.contains(row), let bookmark = items[row].bookmark else { return }
        onOpen?(bookmark)
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag), let bookmark = items[sender.tag].bookmark else { return }
        onOpen?(bookmark)
    }

    @objc private func noop(_ sender: Any?) {}

    private var selectedBookmark: Bookmark? {
        let row = tableView.selectedRow
        guard items.indices.contains(row) else { return nil }
        return items[row].bookmark
    }

    private func focusFirstResult() {
        guard let row = items.firstIndex(where: { $0.bookmark != nil }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        view.window?.makeFirstResponder(tableView)
    }

    private func openFirstResult() {
        guard let bookmark = items.lazy.compactMap(\.bookmark).first else { return }
        onOpen?(bookmark)
    }
}
