import AppKit
import ObeliskCore
import SwiftUI

struct BookmarkGridSection: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let bookmarks: [Bookmark]
    var collectionId: UUID? = nil

    static func dateSections(from bookmarks: [Bookmark], calendar: Calendar = .current) -> [BookmarkGridSection] {
        let sorted = bookmarks.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        let grouped = Dictionary(grouping: sorted) { bookmark -> Date? in
            guard bookmark.createdAt > .distantPast else { return nil }
            return calendar.startOfDay(for: bookmark.createdAt)
        }

        let datedSections = grouped.keys.compactMap { $0 }.sorted(by: >).compactMap { day -> BookmarkGridSection? in
            guard let bookmarks = grouped[day], !bookmarks.isEmpty else { return nil }
            return BookmarkGridSection(
                id: "day-\(day.timeIntervalSinceReferenceDate)",
                title: title(for: day, calendar: calendar),
                subtitle: bookmarkCountSubtitle(bookmarks.count),
                bookmarks: bookmarks
            )
        }

        let unknownBookmarks = grouped[nil] ?? []
        guard !unknownBookmarks.isEmpty else { return datedSections }
        return datedSections + [
            BookmarkGridSection(
                id: "unknown",
                title: "未知日期".obeliskLocalized,
                subtitle: bookmarkCountSubtitle(unknownBookmarks.count),
                bookmarks: unknownBookmarks
            )
        ]
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        let now = Date()
        if calendar.isDateInToday(day) {
            return "今天".obeliskLocalized
        }
        if calendar.isDateInYesterday(day) {
            return "昨天".obeliskLocalized
        }

        let formatter = DateFormatter()
        formatter.locale = .current
        if calendar.component(.year, from: day) == calendar.component(.year, from: now) {
            formatter.setLocalizedDateFormatFromTemplate("MMMdEEE")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("yMMMdEEE")
        }
        return formatter.string(from: day)
    }
}

struct BookmarkSectionGridView: View {
    let sections: [BookmarkGridSection]
    @Binding var selection: Set<Bookmark.ID>
    var selectedCollectionId: Binding<UUID?>? = nil
    let faviconLoader: FaviconLoader
    let showsURLHostOnly: Bool
    let onOpen: ([Bookmark]) -> Void
    let onCopyURL: ([Bookmark]) -> Void
    let onRefreshFavicon: ([Bookmark]) -> Void
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

    @State private var selectionAnchorID: Bookmark.ID?
    @FocusState private var isFocused: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 168, maximum: 224), spacing: 12, alignment: .top)
    ]

    private var orderedBookmarks: [Bookmark] {
        sections.flatMap(\.bookmarks)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader(section)

                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(section.bookmarks) { bookmark in
                                let targets = targetBookmarks(contextBookmark: bookmark)
                                BookmarkGridCard(
                                    bookmark: bookmark,
                                    isSelected: selection.contains(bookmark.id),
                                    faviconLoader: faviconLoader,
                                    showsURLHostOnly: showsURLHostOnly,
                                    showsEdit: targets.count == 1,
                                    showsRevertTitle: canRevertTitle(for: targets),
                                    showsPin: onSetPinned != nil,
                                    pinStateActionTitle: pinActionTitle(for: targets),
                                    hiddenStateActionTitle: hiddenStateActionTitle,
                                    archiveStateActionTitle: archiveStateActionTitle,
                                    collectionAssignOptions: collectionAssignOptions,
                                    onSelect: {
                                        selectBookmark(bookmark)
                                    },
                                    onOpenCard: {
                                        isFocused = true
                                        onOpen([bookmark])
                                    },
                                    onOpen: {
                                        alignSelectionForContextMenu(bookmark)
                                        onOpen(targetBookmarks(contextBookmark: bookmark))
                                    },
                                    onCopyURL: {
                                        alignSelectionForContextMenu(bookmark)
                                        onCopyURL(targetBookmarks(contextBookmark: bookmark))
                                    },
                                    onRefreshFavicon: {
                                        alignSelectionForContextMenu(bookmark)
                                        onRefreshFavicon(targetBookmarks(contextBookmark: bookmark))
                                    },
                                    onEdit: {
                                        alignSelectionForContextMenu(bookmark)
                                        let targets = targetBookmarks(contextBookmark: bookmark)
                                        guard targets.count == 1, let target = targets.first else { return }
                                        onEdit(target)
                                    },
                                    onRevertTitle: {
                                        alignSelectionForContextMenu(bookmark)
                                        onRevertTitleOptimization?(targetBookmarkIDs(contextBookmark: bookmark))
                                    },
                                    onDelete: {
                                        alignSelectionForContextMenu(bookmark)
                                        onDelete(targetBookmarkIDs(contextBookmark: bookmark))
                                    },
                                    onSetHidden: {
                                        alignSelectionForContextMenu(bookmark)
                                        onSetHidden?(targetBookmarkIDs(contextBookmark: bookmark))
                                    },
                                    onSetArchived: {
                                        alignSelectionForContextMenu(bookmark)
                                        onSetArchived?(targetBookmarkIDs(contextBookmark: bookmark))
                                    },
                                    onSetPinned: {
                                        alignSelectionForContextMenu(bookmark)
                                        onSetPinned?(targetBookmarkIDs(contextBookmark: bookmark))
                                    },
                                    onAssignCollection: { collectionId in
                                        alignSelectionForContextMenu(bookmark)
                                        onAssignCollection(targetBookmarkIDs(contextBookmark: bookmark), collectionId)
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 20)
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            isFocused = true
        }
        .onChange(of: selection) { _, newValue in
            if newValue.isEmpty {
                selectionAnchorID = nil
            } else if let anchor = selectionAnchorID, !newValue.contains(anchor) {
                selectionAnchorID = newValue.first
            }
        }
        .onKeyPress { keyPress in
            handleKeyPress(keyPress)
        }
    }

    private func sectionHeader(_ section: BookmarkGridSection) -> some View {
        let isSelected = section.collectionId != nil && selectedCollectionId?.wrappedValue == section.collectionId

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(section.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text(section.subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, section.collectionId == nil ? 0 : 8)
        .padding(.vertical, section.collectionId == nil ? 0 : 5)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let collectionId = section.collectionId else { return }
            selection.removeAll()
            selectionAnchorID = nil
            selectedCollectionId?.wrappedValue = collectionId
            isFocused = true
        }
        .contextMenu {
            if let collectionId = section.collectionId {
                if let onRenameCollection {
                    Button("重命名分组") {
                        onRenameCollection(collectionId)
                    }
                }
                if onRenameCollection != nil, onDeleteCollection != nil {
                    Divider()
                }
                if let onDeleteCollection {
                    Button("删除分组", role: .destructive) {
                        onDeleteCollection(collectionId)
                    }
                }
            }
        }
    }

    private func selectBookmark(_ bookmark: Bookmark) {
        isFocused = true
        selectedCollectionId?.wrappedValue = nil

        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers.contains(.shift) {
            let orderedIDs = orderedBookmarks.map(\.id)
            let anchor = selectionAnchorID ?? selection.first ?? bookmark.id
            guard
                let from = orderedIDs.firstIndex(of: anchor),
                let to = orderedIDs.firstIndex(of: bookmark.id)
            else {
                selection = [bookmark.id]
                selectionAnchorID = bookmark.id
                return
            }
            let lower = min(from, to)
            let upper = max(from, to)
            selection = Set(orderedIDs[lower...upper])
            if selectionAnchorID == nil {
                selectionAnchorID = anchor
            }
            return
        }

        if modifiers.contains(.command) {
            if selection.contains(bookmark.id) {
                selection.remove(bookmark.id)
            } else {
                selection.insert(bookmark.id)
            }
            selectionAnchorID = bookmark.id
            return
        }

        selection = [bookmark.id]
        selectionAnchorID = bookmark.id
    }

    private func alignSelectionForContextMenu(_ bookmark: Bookmark) {
        selectedCollectionId?.wrappedValue = nil
        if !selection.contains(bookmark.id) {
            selection = [bookmark.id]
            selectionAnchorID = bookmark.id
        }
        isFocused = true
    }

    private func targetBookmarkIDs(contextBookmark: Bookmark) -> Set<Bookmark.ID> {
        if selection.contains(contextBookmark.id) {
            return selection
        }
        return [contextBookmark.id]
    }

    private func targetBookmarks(contextBookmark: Bookmark) -> [Bookmark] {
        let ids = targetBookmarkIDs(contextBookmark: contextBookmark)
        return orderedBookmarks.filter { ids.contains($0.id) }
    }

    private func selectedBookmarks() -> [Bookmark] {
        orderedBookmarks.filter { selection.contains($0.id) }
    }

    private func pinActionTitle(for bookmarks: [Bookmark]) -> String {
        let shouldPin = bookmarks.isEmpty || !bookmarks.allSatisfy(\.isPinned)
        return shouldPin ? "置顶" : "取消置顶"
    }

    private func canRevertTitle(for bookmarks: [Bookmark]) -> Bool {
        guard onRevertTitleOptimization != nil else { return false }
        return bookmarks.contains { bookmark in
            guard bookmark.titleOptimized else { return false }
            let original = bookmark.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !original.isEmpty
        }
    }

    private func clearSelection() -> KeyPress.Result {
        let hasBookmarkSelection = !selection.isEmpty
        let hasCollectionSelection = selectedCollectionId?.wrappedValue != nil
        guard hasBookmarkSelection || hasCollectionSelection else {
            return .ignored
        }
        selection = []
        selectionAnchorID = nil
        selectedCollectionId?.wrappedValue = nil
        return .handled
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        let modifiers = keyPress.modifiers

        if modifiers.isEmpty, keyPress.key == .escape {
            return clearSelection()
        }

        if modifiers == .command, keyPress.key == KeyEquivalent("c") {
            let bookmarks = selectedBookmarks()
            guard !bookmarks.isEmpty else { return .ignored }
            onCopyURL(bookmarks)
            return .handled
        }

        if modifiers == .command, keyPress.key == KeyEquivalent("e") {
            guard selection.count == 1, let bookmark = selectedBookmarks().first else {
                return .ignored
            }
            onEdit(bookmark)
            return .handled
        }

        if modifiers.isEmpty, keyPress.key == .return {
            let bookmarks = selectedBookmarks()
            guard !bookmarks.isEmpty else { return .ignored }
            onOpen(bookmarks)
            return .handled
        }

        if modifiers.isEmpty, keyPress.key == .delete || keyPress.characters == "\u{007F}" || keyPress.characters == "\u{F728}" {
            guard !selection.isEmpty else { return .ignored }
            onDelete(selection)
            return .handled
        }

        return .ignored
    }
}

struct BookmarkGridCard: View {
    let bookmark: Bookmark
    let isSelected: Bool
    let faviconLoader: FaviconLoader
    let showsURLHostOnly: Bool
    let showsEdit: Bool
    let showsRevertTitle: Bool
    let showsPin: Bool
    let pinStateActionTitle: String
    let hiddenStateActionTitle: String?
    let archiveStateActionTitle: String?
    let collectionAssignOptions: [BookmarkCollectionAssignOption]
    let onSelect: () -> Void
    let onOpenCard: () -> Void
    let onOpen: () -> Void
    let onCopyURL: () -> Void
    let onRefreshFavicon: () -> Void
    let onEdit: () -> Void
    let onRevertTitle: () -> Void
    let onDelete: () -> Void
    let onSetHidden: () -> Void
    let onSetArchived: () -> Void
    let onSetPinned: () -> Void
    let onAssignCollection: (UUID?) -> Void

    @State private var isPressed = false

    var body: some View {
        let _ = faviconLoader.version
        let favicon = faviconLoader.image(for: bookmark.url)

        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                faviconView(favicon)

                Spacer(minLength: 0)

                if bookmark.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                        .padding(6)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(displayURL)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .padding(9)
        .background(cardBackground)
        .overlay(cardBorder)
        .scaleEffect(isPressed ? 0.985 : 1)
        .animation(.easeOut(duration: 0.12), value: isPressed)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            onSelect()
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onOpenCard()
            }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .contextMenu {
            Button("打开", action: onOpen)
            Button("复制 URL", action: onCopyURL)
            Button("刷新 favicon", action: onRefreshFavicon)
            if showsEdit {
                Button("编辑", action: onEdit)
            }
            if showsRevertTitle {
                Button("恢复原标题", action: onRevertTitle)
            }
            if showsPin {
                Divider()
                Button(pinStateActionTitle, action: onSetPinned)
            }
            if !collectionAssignOptions.isEmpty {
                Menu("移到分组") {
                    ForEach(collectionAssignOptions, id: \.title) { option in
                        Button(option.title) {
                            onAssignCollection(option.collectionId)
                        }
                    }
                }
            }
            if let hiddenStateActionTitle {
                Button(hiddenStateActionTitle, action: onSetHidden)
            }
            if let archiveStateActionTitle {
                Button(archiveStateActionTitle, action: onSetArchived)
            }
            Divider()
            Button("删除", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bookmark.title)
    }

    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        return shape
            .fill(.thinMaterial)
            .overlay {
                shape.fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.018))
            }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(
                isSelected ? Color.accentColor.opacity(0.75) : Color(nsColor: .separatorColor).opacity(0.42),
                lineWidth: isSelected ? 1.4 : 1
            )
    }

    private var displayURL: String {
        guard showsURLHostOnly, let host = URL(string: bookmark.url)?.host(percentEncoded: false) else {
            return bookmark.url
        }
        return host
    }

    private func faviconView(_ favicon: NSImage?) -> some View {
        Group {
            if let favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(nsImage: AppIcon.faviconPlaceholder(size: NSSize(width: 24, height: 24)))
                    .resizable()
                    .interpolation(.high)
            }
        }
        .frame(width: 24, height: 24)
    }
}
