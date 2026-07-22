import AppKit
import ObeliskCore
import SwiftUI

struct BookmarkCardMaterialBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.thinMaterial)
    }
}

@MainActor
enum BookmarkCardMaterialRenderer {
    static func makeView() -> NSView {
        BookmarkCardMaterialHostingView(rootView: BookmarkCardMaterialBackground())
    }
}

private final class BookmarkCardMaterialHostingView: NSHostingView<BookmarkCardMaterialBackground> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
struct NativeBookmarkCardGrid: NSViewRepresentable {
    let sections: [BookmarkGridSection]
    @Binding var selection: Set<Bookmark.ID>
    var selectedCollectionId: Binding<UUID?>? = nil
    let faviconLoader: FaviconLoader
    let faviconVersion: Int
    let showsURLHostOnly: Bool
    let onOpen: ([Bookmark]) -> Void
    let onCopyURL: ([Bookmark]) -> Void
    let onEdit: (Bookmark) -> Void
    let onDelete: (Set<Bookmark.ID>) -> Void
    var hiddenStateActionTitle: String? = nil
    var onSetHidden: ((Set<Bookmark.ID>) -> Void)? = nil
    var archiveStateActionTitle: String? = nil
    var onSetArchived: ((Set<Bookmark.ID>) -> Void)? = nil
    var onSetPinned: ((Set<Bookmark.ID>) -> Void)? = nil
    let collectionAssignOptions: [BookmarkCollectionAssignOption]
    let onAssignCollection: (Set<Bookmark.ID>, UUID?) -> Void
    var onRenameCollection: ((UUID) -> Void)? = nil
    var onDeleteCollection: ((UUID) -> Void)? = nil
    var onRevertTitleOptimization: ((Set<Bookmark.ID>) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = BookmarkCardScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none

        let layout = BookmarkCardFlowLayout()
        let collectionView = BookmarkCardCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.commandDelegate = context.coordinator
        collectionView.isHidden = true
        collectionView.register(
            BookmarkCardCollectionItem.self,
            forItemWithIdentifier: BookmarkCardCollectionItem.identifier
        )
        collectionView.register(
            BookmarkCardSectionHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: BookmarkCardSectionHeaderView.identifier
        )

        collectionView.frame = scrollView.contentView.bounds
        collectionView.autoresizingMask = [.width]
        scrollView.documentView = collectionView

        context.coordinator.scrollView = scrollView
        context.coordinator.collectionView = collectionView
        scrollView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.layoutCollectionForCurrentWidth()
        }
        context.coordinator.installScrollObserver()
        context.coordinator.reloadCollection()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject,
        NSCollectionViewDataSource,
        NSCollectionViewDelegate,
        NSCollectionViewDelegateFlowLayout,
        BookmarkCardCollectionViewCommandDelegate
    {
        var parent: NativeBookmarkCardGrid
        weak var scrollView: NSScrollView?
        weak var collectionView: BookmarkCardCollectionView?
        private var cachedSections: [BookmarkGridSection]
        private var cachedFaviconVersion: Int
        private var cachedShowsURLHostOnly: Bool
        private var isSyncingSelection = false
        private var bookmarkContextMenuController: NativeBookmarkContextMenuController?
        private var collectionContextMenuController: NativeCollectionContextMenuController?

        init(_ parent: NativeBookmarkCardGrid) {
            self.parent = parent
            self.cachedSections = parent.sections
            self.cachedFaviconVersion = parent.faviconVersion
            self.cachedShowsURLHostOnly = parent.showsURLHostOnly
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func update(parent: NativeBookmarkCardGrid) {
            self.parent = parent
            syncCollectionWidth()

            if cachedSections != parent.sections || cachedShowsURLHostOnly != parent.showsURLHostOnly {
                cachedSections = parent.sections
                cachedShowsURLHostOnly = parent.showsURLHostOnly
                cachedFaviconVersion = parent.faviconVersion
                reloadCollection()
                return
            }

            if cachedFaviconVersion != parent.faviconVersion {
                cachedFaviconVersion = parent.faviconVersion
                reloadVisibleCards()
            }
            syncSelectionToCollection()
            syncVisibleHeaderSelection()
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
            syncCollectionWidth()
        }

        func layoutCollectionForCurrentWidth() {
            guard syncCollectionWidth(), let collectionView else { return }
            collectionView.layoutSubtreeIfNeeded()
            collectionView.isHidden = false
        }

        func reloadCollection() {
            guard let collectionView else { return }
            syncCollectionWidth()
            collectionView.reloadData()
            syncSelectionToCollection()
            syncVisibleHeaderSelection()
        }

        private func reloadVisibleCards() {
            guard let collectionView else { return }
            let visible = collectionView.indexPathsForVisibleItems()
            guard !visible.isEmpty else { return }
            collectionView.reloadItems(at: visible)
        }

        @discardableResult
        private func syncCollectionWidth() -> Bool {
            guard let scrollView, let collectionView else { return false }
            let width = scrollView.contentView.bounds.width
            guard BookmarkCardFlowLayout.isUsableCollectionWidth(width) else {
                return false
            }
            if collectionView.frame.width != width {
                collectionView.frame.size.width = width
            }
            (collectionView.collectionViewLayout as? BookmarkCardFlowLayout)?.updateItemWidth(
                for: width
            )
            return true
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            parent.sections.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            guard parent.sections.indices.contains(section) else { return 0 }
            return parent.sections[section].bookmarks.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: BookmarkCardCollectionItem.identifier,
                for: indexPath
            ) as! BookmarkCardCollectionItem
            guard let bookmark = bookmark(at: indexPath) else { return item }
            item.configure(
                bookmark: bookmark,
                showsURLHostOnly: parent.showsURLHostOnly,
                favicon: parent.faviconLoader.image(for: bookmark.url)
            )
            return item
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
            at indexPath: IndexPath
        ) -> NSView {
            let view = collectionView.makeSupplementaryView(
                ofKind: kind,
                withIdentifier: BookmarkCardSectionHeaderView.identifier,
                for: indexPath
            ) as! BookmarkCardSectionHeaderView
            guard parent.sections.indices.contains(indexPath.section) else { return view }
            let section = parent.sections[indexPath.section]
            view.configure(
                title: section.title,
                subtitle: section.subtitle,
                collectionId: section.collectionId,
                isSelected: section.collectionId != nil &&
                    parent.selectedCollectionId?.wrappedValue == section.collectionId,
                onSelect: { [weak self] collectionId in
                    self?.selectCollection(collectionId)
                },
                menuProvider: { [weak self] collectionId in
                    self?.collectionMenu(for: collectionId)
                }
            )
            return view
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            (collectionViewLayout as? BookmarkCardFlowLayout)?.itemSize ??
                NSSize(width: 168, height: BookmarkCardFlowLayout.itemHeight)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            referenceSizeForHeaderInSection section: Int
        ) -> NSSize {
            guard parent.sections.indices.contains(section) else { return .zero }
            let height: CGFloat = parent.sections[section].collectionId == nil ? 20 : 28
            return NSSize(width: collectionView.bounds.width, height: height)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didSelectItemsAt indexPaths: Set<IndexPath>
        ) {
            selectionDidChange(in: collectionView)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didDeselectItemsAt indexPaths: Set<IndexPath>
        ) {
            selectionDidChange(in: collectionView)
        }

        private func selectionDidChange(in collectionView: NSCollectionView) {
            guard !isSyncingSelection else { return }
            let bookmarkIDs = Set(collectionView.selectionIndexPaths.compactMap { bookmark(at: $0)?.id })
            parent.selection = bookmarkIDs
            if !bookmarkIDs.isEmpty {
                parent.selectedCollectionId?.wrappedValue = nil
            }
            syncVisibleHeaderSelection()
        }

        private func syncSelectionToCollection() {
            guard let collectionView else { return }
            let desired = Set(allIndexPaths().filter { indexPath in
                guard let bookmark = bookmark(at: indexPath) else { return false }
                return parent.selection.contains(bookmark.id)
            })
            let current = collectionView.selectionIndexPaths
            guard current != desired else { return }

            isSyncingSelection = true
            collectionView.deselectItems(at: current.subtracting(desired))
            collectionView.selectItems(at: desired.subtracting(current), scrollPosition: [])
            isSyncingSelection = false
        }

        private func syncVisibleHeaderSelection() {
            guard let collectionView else { return }
            for sectionIndex in parent.sections.indices {
                let indexPath = IndexPath(item: 0, section: sectionIndex)
                guard let header = collectionView.supplementaryView(
                    forElementKind: NSCollectionView.elementKindSectionHeader,
                    at: indexPath
                ) as? BookmarkCardSectionHeaderView else {
                    continue
                }
                let collectionId = parent.sections[sectionIndex].collectionId
                header.setSelected(
                    collectionId != nil && parent.selectedCollectionId?.wrappedValue == collectionId
                )
            }
        }

        func bookmarkCardCollectionView(
            _ collectionView: BookmarkCardCollectionView,
            didDoubleClickItemAt indexPath: IndexPath
        ) {
            guard let bookmark = bookmark(at: indexPath) else { return }
            parent.onOpen([bookmark])
        }

        func bookmarkCardCollectionView(
            _ collectionView: BookmarkCardCollectionView,
            menuForItemAt indexPath: IndexPath
        ) -> NSMenu? {
            guard let bookmark = bookmark(at: indexPath) else { return nil }
            parent.selectedCollectionId?.wrappedValue = nil
            if !parent.selection.contains(bookmark.id) {
                parent.selection = [bookmark.id]
            }

            let targets = targetBookmarks(contextBookmark: bookmark)
            var configuration = NativeBookmarkContextMenuConfiguration()
            configuration.onOpen = { [weak self] in
                guard let self else { return }
                parent.onOpen(targetBookmarks(contextBookmark: bookmark))
            }
            configuration.onCopyURL = { [weak self] in
                guard let self else { return }
                parent.onCopyURL(targetBookmarks(contextBookmark: bookmark))
            }
            if targets.count == 1 {
                configuration.onEdit = { [weak self] in
                    guard let self else { return }
                    let currentTargets = targetBookmarks(contextBookmark: bookmark)
                    guard currentTargets.count == 1, let target = currentTargets.first else { return }
                    parent.onEdit(target)
                }
            }
            if canRevertTitle(for: targets) {
                configuration.onRevertTitleOptimization = { [weak self] in
                    guard let self else { return }
                    parent.onRevertTitleOptimization?(targetBookmarkIDs(contextBookmark: bookmark))
                }
            }
            if parent.onSetPinned != nil {
                configuration.pinStateActionTitle = pinActionTitle(for: targets)
                configuration.pinStateSystemSymbolName = pinSystemSymbolName(for: targets)
                configuration.onSetPinned = { [weak self] in
                    guard let self else { return }
                    parent.onSetPinned?(targetBookmarkIDs(contextBookmark: bookmark))
                }
            }
            if !parent.collectionAssignOptions.isEmpty {
                configuration.collectionAssignOptions = parent.collectionAssignOptions
                configuration.onAssignCollection = { [weak self] collectionId in
                    guard let self else { return }
                    parent.onAssignCollection(targetBookmarkIDs(contextBookmark: bookmark), collectionId)
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
            if let title = parent.archiveStateActionTitle, parent.onSetArchived != nil {
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
            configuration.onDelete = { [weak self] in
                guard let self else { return }
                parent.onDelete(targetBookmarkIDs(contextBookmark: bookmark))
            }

            let controller = NativeBookmarkContextMenuController()
            guard let menu = controller.makeMenu(configuration: configuration) else { return nil }
            bookmarkContextMenuController = controller
            return menu
        }

        func bookmarkCardCollectionViewCopySelection(_ collectionView: BookmarkCardCollectionView) {
            let bookmarks = selectedBookmarks()
            guard !bookmarks.isEmpty else { return }
            parent.onCopyURL(bookmarks)
        }

        func bookmarkCardCollectionViewEditSelection(_ collectionView: BookmarkCardCollectionView) {
            let bookmarks = selectedBookmarks()
            guard bookmarks.count == 1, let bookmark = bookmarks.first else { return }
            parent.onEdit(bookmark)
        }

        func bookmarkCardCollectionViewDeleteSelection(_ collectionView: BookmarkCardCollectionView) {
            guard !parent.selection.isEmpty else { return }
            parent.onDelete(parent.selection)
        }

        func bookmarkCardCollectionViewOpenSelection(_ collectionView: BookmarkCardCollectionView) {
            let bookmarks = selectedBookmarks()
            guard !bookmarks.isEmpty else { return }
            parent.onOpen(bookmarks)
        }

        func bookmarkCardCollectionViewSelectionDidChange(
            _ collectionView: BookmarkCardCollectionView
        ) {
            selectionDidChange(in: collectionView)
        }

        func bookmarkCardCollectionViewCancel(_ collectionView: BookmarkCardCollectionView) -> Bool {
            let hasBookmarkSelection = !parent.selection.isEmpty
            let hasCollectionSelection = parent.selectedCollectionId?.wrappedValue != nil
            guard hasBookmarkSelection || hasCollectionSelection else { return false }

            parent.selection = []
            parent.selectedCollectionId?.wrappedValue = nil
            isSyncingSelection = true
            collectionView.deselectItems(at: collectionView.selectionIndexPaths)
            isSyncingSelection = false
            syncVisibleHeaderSelection()
            return true
        }

        func bookmarkCardCollectionView(
            _ collectionView: BookmarkCardCollectionView,
            nextSelectableIndexPathAfter indexPath: IndexPath?
        ) -> IndexPath? {
            let ordered = allIndexPaths()
            guard !ordered.isEmpty else { return nil }
            guard let indexPath, let currentIndex = ordered.firstIndex(of: indexPath) else {
                return ordered.first
            }
            let nextIndex = ordered.index(after: currentIndex)
            return nextIndex < ordered.endIndex ? ordered[nextIndex] : nil
        }

        private func selectCollection(_ collectionId: UUID) {
            guard let collectionView else { return }
            parent.selection = []
            parent.selectedCollectionId?.wrappedValue = collectionId
            isSyncingSelection = true
            collectionView.deselectItems(at: collectionView.selectionIndexPaths)
            isSyncingSelection = false
            collectionView.window?.makeFirstResponder(collectionView)
            syncVisibleHeaderSelection()
        }

        private func collectionMenu(for collectionId: UUID) -> NSMenu? {
            selectCollection(collectionId)
            var configuration = NativeCollectionContextMenuConfiguration()
            if parent.onRenameCollection != nil {
                configuration.onRename = { [weak self] in
                    self?.parent.onRenameCollection?(collectionId)
                }
            }
            if parent.onDeleteCollection != nil {
                configuration.onDelete = { [weak self] in
                    self?.parent.onDeleteCollection?(collectionId)
                }
            }
            let controller = NativeCollectionContextMenuController()
            guard let menu = controller.makeMenu(configuration: configuration) else { return nil }
            collectionContextMenuController = controller
            return menu
        }

        private func bookmark(at indexPath: IndexPath) -> Bookmark? {
            guard parent.sections.indices.contains(indexPath.section) else { return nil }
            let bookmarks = parent.sections[indexPath.section].bookmarks
            guard bookmarks.indices.contains(indexPath.item) else { return nil }
            return bookmarks[indexPath.item]
        }

        private func allIndexPaths() -> [IndexPath] {
            parent.sections.indices.flatMap { sectionIndex in
                parent.sections[sectionIndex].bookmarks.indices.map { itemIndex in
                    IndexPath(item: itemIndex, section: sectionIndex)
                }
            }
        }

        private func targetBookmarkIDs(contextBookmark: Bookmark) -> Set<Bookmark.ID> {
            parent.selection.contains(contextBookmark.id) ? parent.selection : [contextBookmark.id]
        }

        private func targetBookmarks(contextBookmark: Bookmark) -> [Bookmark] {
            let ids = targetBookmarkIDs(contextBookmark: contextBookmark)
            return BookmarkOperationTargetResolver.bookmarks(
                in: parent.sections.flatMap(\.bookmarks),
                matching: ids
            )
        }

        private func selectedBookmarks() -> [Bookmark] {
            BookmarkOperationTargetResolver.bookmarks(
                in: parent.sections.flatMap(\.bookmarks),
                matching: parent.selection
            )
        }

        private func pinActionTitle(for bookmarks: [Bookmark]) -> String {
            let shouldPin = bookmarks.isEmpty || !bookmarks.allSatisfy(\.isPinned)
            return shouldPin
                ? String(localized: "bookmark.action.pin", defaultValue: "置顶")
                : "取消置顶".obeliskLocalized
        }

        private func pinSystemSymbolName(for bookmarks: [Bookmark]) -> String {
            let shouldPin = bookmarks.isEmpty || !bookmarks.allSatisfy(\.isPinned)
            return shouldPin ? "pin" : "pin.slash"
        }

        private func restoreBookmarkSymbolName(for title: String, defaultSymbolName: String) -> String {
            let restoreTitle = "恢复到书签"
            if title == restoreTitle || title == restoreTitle.obeliskLocalized {
                return "bookmark"
            }
            return defaultSymbolName
        }

        private func canRevertTitle(for bookmarks: [Bookmark]) -> Bool {
            guard parent.onRevertTitleOptimization != nil else { return false }
            return bookmarks.contains { bookmark in
                guard bookmark.titleOptimized else { return false }
                let original = bookmark.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !original.isEmpty
            }
        }
    }
}

final class BookmarkCardFlowLayout: NSCollectionViewFlowLayout {
    static let itemHeight: CGFloat = 98
    static let minimumUsableCollectionWidth: CGFloat = 204
    private static let minimumItemWidth: CGFloat = 168
    private static let maximumItemWidth: CGFloat = 224
    private static let spacing: CGFloat = 12
    private static let horizontalInset: CGFloat = 18

    override init() {
        super.init()
        minimumInteritemSpacing = Self.spacing
        minimumLineSpacing = Self.spacing
        sectionInset = NSEdgeInsets(top: 10, left: 18, bottom: 22, right: 18)
        headerReferenceSize = NSSize(width: 1, height: 20)
        itemSize = NSSize(width: Self.minimumItemWidth, height: Self.itemHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateItemWidth(for collectionWidth: CGFloat) {
        let resolvedWidth = Self.itemWidth(for: collectionWidth)
        let nextSize = NSSize(width: resolvedWidth, height: Self.itemHeight)
        guard itemSize != nextSize else { return }
        itemSize = nextSize
        invalidateLayout()
    }

    static func itemWidth(for collectionWidth: CGFloat) -> CGFloat {
        let availableWidth = max(1, collectionWidth - Self.horizontalInset * 2)
        let columnCount = max(
            1,
            Int((availableWidth + Self.spacing) / (Self.minimumItemWidth + Self.spacing))
        )
        let totalSpacing = CGFloat(columnCount - 1) * Self.spacing
        let proposedWidth = floor((availableWidth - totalSpacing) / CGFloat(columnCount))
        return min(Self.maximumItemWidth, max(1, proposedWidth))
    }

    static func isUsableCollectionWidth(_ collectionWidth: CGFloat) -> Bool {
        collectionWidth >= minimumUsableCollectionWidth
    }
}

private final class BookmarkCardScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

@MainActor
protocol BookmarkCardCollectionViewCommandDelegate: AnyObject {
    func bookmarkCardCollectionView(
        _ collectionView: BookmarkCardCollectionView,
        didDoubleClickItemAt indexPath: IndexPath
    )
    func bookmarkCardCollectionView(
        _ collectionView: BookmarkCardCollectionView,
        menuForItemAt indexPath: IndexPath
    ) -> NSMenu?
    func bookmarkCardCollectionViewCopySelection(_ collectionView: BookmarkCardCollectionView)
    func bookmarkCardCollectionViewEditSelection(_ collectionView: BookmarkCardCollectionView)
    func bookmarkCardCollectionViewDeleteSelection(_ collectionView: BookmarkCardCollectionView)
    func bookmarkCardCollectionViewOpenSelection(_ collectionView: BookmarkCardCollectionView)
    func bookmarkCardCollectionViewSelectionDidChange(_ collectionView: BookmarkCardCollectionView)
    func bookmarkCardCollectionViewCancel(_ collectionView: BookmarkCardCollectionView) -> Bool
    func bookmarkCardCollectionView(
        _ collectionView: BookmarkCardCollectionView,
        nextSelectableIndexPathAfter indexPath: IndexPath?
    ) -> IndexPath?
}

final class BookmarkCardCollectionView: NSCollectionView {
    weak var commandDelegate: BookmarkCardCollectionViewCommandDelegate?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedIndexPath = indexPathForItem(at: point)
        super.mouseDown(with: event)
        if event.clickCount == 2, let clickedIndexPath {
            commandDelegate?.bookmarkCardCollectionView(
                self,
                didDoubleClickItemAt: clickedIndexPath
            )
        }
    }

    override func keyDown(with event: NSEvent) {
        switch BookmarkKeyboardCommandResolver.resolve(
            characters: event.charactersIgnoringModifiers ?? "",
            keyCode: event.keyCode,
            modifiers: event.modifierFlags
        ) {
        case .copy:
            commandDelegate?.bookmarkCardCollectionViewCopySelection(self)
        case .edit:
            commandDelegate?.bookmarkCardCollectionViewEditSelection(self)
        case .cancel:
            guard commandDelegate?.bookmarkCardCollectionViewCancel(self) == true else {
                super.keyDown(with: event)
                return
            }
        case .advanceSelection:
            moveSelectionForward()
        case .delete:
            commandDelegate?.bookmarkCardCollectionViewDeleteSelection(self)
        case .open:
            commandDelegate?.bookmarkCardCollectionViewOpenSelection(self)
        case nil:
            super.keyDown(with: event)
        }
    }

    override func insertTab(_ sender: Any?) {
        moveSelectionForward()
    }

    override func insertTabIgnoringFieldEditor(_ sender: Any?) {
        moveSelectionForward()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }

        if !selectionIndexPaths.contains(indexPath) {
            deselectItems(at: selectionIndexPaths)
            selectItems(at: [indexPath], scrollPosition: [])
        }
        window?.makeFirstResponder(self)
        return commandDelegate?.bookmarkCardCollectionView(self, menuForItemAt: indexPath)
    }

    private func moveSelectionForward() {
        let current = selectionIndexPaths.max { lhs, rhs in
            lhs.section == rhs.section ? lhs.item < rhs.item : lhs.section < rhs.section
        }
        guard let next = commandDelegate?.bookmarkCardCollectionView(
            self,
            nextSelectableIndexPathAfter: current
        ) else { return }
        deselectItems(at: selectionIndexPaths)
        selectItems(at: [next], scrollPosition: .nearestHorizontalEdge)
        scrollToItems(at: [next], scrollPosition: .nearestVerticalEdge)
        commandDelegate?.bookmarkCardCollectionViewSelectionDidChange(self)
    }
}

final class BookmarkCardCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("BookmarkCardCollectionItem")

    override func loadView() {
        view = BookmarkCardContentView()
    }

    override var isSelected: Bool {
        didSet {
            (view as? BookmarkCardContentView)?.setSelected(isSelected)
        }
    }

    func configure(bookmark: Bookmark, showsURLHostOnly: Bool, favicon: NSImage?) {
        (view as? BookmarkCardContentView)?.configure(
            bookmark: bookmark,
            showsURLHostOnly: showsURLHostOnly,
            favicon: favicon,
            isSelected: isSelected
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        (view as? BookmarkCardContentView)?.prepareForReuse()
    }
}

private final class BookmarkCardContentView: NSView {
    private let materialView = BookmarkCardMaterialRenderer.makeView()
    private let tintView = NSView()
    private let faviconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let urlField = NSTextField(labelWithString: "")
    private let pinBadge = NSView()
    private let pinImageView = NSImageView()
    private var selected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        materialView.translatesAutoresizingMaskIntoConstraints = false

        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.wantsLayer = true

        faviconView.translatesAutoresizingMaskIntoConstraints = false
        faviconView.imageScaling = .scaleProportionallyUpOrDown

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.usesSingleLineMode = true
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.font = .systemFont(ofSize: 11)
        urlField.textColor = .secondaryLabelColor
        urlField.lineBreakMode = .byTruncatingMiddle
        urlField.usesSingleLineMode = true
        urlField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pinBadge.translatesAutoresizingMaskIntoConstraints = false
        pinBadge.wantsLayer = true
        pinBadge.layer?.cornerRadius = 6

        pinImageView.translatesAutoresizingMaskIntoConstraints = false
        pinImageView.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        pinImageView.imageScaling = .scaleProportionallyUpOrDown
        pinImageView.contentTintColor = .controlAccentColor
        pinBadge.addSubview(pinImageView)

        [materialView, tintView, faviconView, titleField, urlField, pinBadge].forEach(addSubview)

        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),

            faviconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            faviconView.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            faviconView.widthAnchor.constraint(equalToConstant: 24),
            faviconView.heightAnchor.constraint(equalToConstant: 24),

            pinBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            pinBadge.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            pinBadge.widthAnchor.constraint(equalToConstant: 23),
            pinBadge.heightAnchor.constraint(equalToConstant: 23),

            pinImageView.centerXAnchor.constraint(equalTo: pinBadge.centerXAnchor),
            pinImageView.centerYAnchor.constraint(equalTo: pinBadge.centerYAnchor),
            pinImageView.widthAnchor.constraint(equalToConstant: 11),
            pinImageView.heightAnchor.constraint(equalToConstant: 11),

            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            titleField.topAnchor.constraint(equalTo: faviconView.bottomAnchor, constant: 7),

            urlField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            urlField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            urlField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2)
        ])
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func configure(
        bookmark: Bookmark,
        showsURLHostOnly: Bool,
        favicon: NSImage?,
        isSelected: Bool
    ) {
        faviconView.image = favicon ?? AppIcon.faviconPlaceholder(size: NSSize(width: 24, height: 24))
        titleField.stringValue = bookmark.title
        urlField.stringValue = displayURL(for: bookmark.url, showsHostOnly: showsURLHostOnly)
        pinBadge.isHidden = !bookmark.isPinned
        setSelected(isSelected)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(bookmark.title)
    }

    func setSelected(_ selected: Bool) {
        guard self.selected != selected else { return }
        self.selected = selected
        updateAppearance()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        faviconView.image = nil
        titleField.stringValue = ""
        urlField.stringValue = ""
        pinBadge.isHidden = true
        selected = false
        updateAppearance()
    }

    private func displayURL(for urlString: String, showsHostOnly: Bool) -> String {
        guard showsHostOnly, let host = URL(string: urlString)?.host(percentEncoded: false) else {
            return urlString
        }
        return host
    }

    private func updateAppearance() {
        guard let layer else { return }
        let accent = NSColor.controlAccentColor
        tintView.layer?.backgroundColor = (
            selected ? accent.withAlphaComponent(0.14) : NSColor.clear
        ).cgColor
        layer.borderColor = (
            selected ? accent.withAlphaComponent(0.75) : NSColor.separatorColor.withAlphaComponent(0.16)
        ).cgColor
        layer.borderWidth = selected ? 1.4 : 0.5
        pinBadge.layer?.backgroundColor = accent.withAlphaComponent(0.12).cgColor
        pinImageView.contentTintColor = accent
    }
}

private final class BookmarkCardSectionHeaderView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("BookmarkCardSectionHeaderView")

    private let selectionView = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private var titleLeadingConstraint: NSLayoutConstraint!
    private var collectionId: UUID?
    private var onSelect: ((UUID) -> Void)?
    private var menuProvider: ((UUID) -> NSMenu?)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        selectionView.translatesAutoresizingMaskIntoConstraints = false
        selectionView.wantsLayer = true
        selectionView.layer?.cornerRadius = 7
        selectionView.isHidden = true

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentHuggingPriority(.required, for: .horizontal)

        subtitleField.translatesAutoresizingMaskIntoConstraints = false
        subtitleField.font = .systemFont(ofSize: 12, weight: .medium)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        [selectionView, titleField, subtitleField].forEach(addSubview)
        titleLeadingConstraint = titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18)
        NSLayoutConstraint.activate([
            selectionView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            selectionView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            selectionView.topAnchor.constraint(equalTo: topAnchor),
            selectionView.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLeadingConstraint,
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            subtitleField.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 8),
            subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            subtitleField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        guard let collectionId else {
            super.mouseDown(with: event)
            return
        }
        onSelect?(collectionId)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let collectionId else { return nil }
        return menuProvider?(collectionId)
    }

    func configure(
        title: String,
        subtitle: String,
        collectionId: UUID?,
        isSelected: Bool,
        onSelect: @escaping (UUID) -> Void,
        menuProvider: @escaping (UUID) -> NSMenu?
    ) {
        titleField.stringValue = title
        subtitleField.stringValue = subtitle
        self.collectionId = collectionId
        self.onSelect = onSelect
        self.menuProvider = menuProvider
        titleLeadingConstraint.constant = collectionId == nil ? 18 : 26
        setSelected(isSelected)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title) \(subtitle)")
    }

    func setSelected(_ selected: Bool) {
        selectionView.isHidden = !selected
        selectionView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
    }
}
