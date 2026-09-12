import AppKit
import ObeliskCore
import SwiftUI

struct BookmarkGridSection: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let bookmarks: [Bookmark]

    static func dateSections(from bookmarks: [Bookmark], calendar: Calendar = .current) -> [BookmarkGridSection] {
        let sorted = bookmarks.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
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

    static func orderedSection(from bookmarks: [Bookmark]) -> [BookmarkGridSection] {
        guard !bookmarks.isEmpty else { return [] }
        return [BookmarkGridSection(id: "ordered", title: "", subtitle: "", bookmarks: bookmarks)]
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
    let faviconLoader: FaviconLoader
    let showsURLHostOnly: Bool
    let onOpen: ([Bookmark]) -> Void
    let onCopyURL: ([Bookmark]) -> Void
    let onEdit: (Bookmark) -> Void
    let onDelete: (Set<Bookmark.ID>) -> Void
    var hiddenStateActionTitle: String? = nil
    var onSetHidden: ((Set<Bookmark.ID>) -> Void)? = nil
    var archiveStateActionTitle: String? = nil
    var onSetArchived: ((Set<Bookmark.ID>) -> Void)? = nil
    let collectionAssignOptions: [BookmarkCollectionAssignOption]
    let onAssignCollection: (Set<Bookmark.ID>, UUID?) -> Void
    let collectionName: (Bookmark.ID) -> String?
    var onRevertTitleOptimization: ((Set<Bookmark.ID>) -> Void)? = nil
    var onRetryTitleOptimization: ((Set<Bookmark.ID>) -> Void)? = nil

    @State private var selectionAnchorID: Bookmark.ID?
    @State private var contextMenuController = NativeBookmarkContextMenuController()
    @FocusState private var isFocused: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 168, maximum: 224), spacing: 12, alignment: .top)
    ]

    private var orderedBookmarks: [Bookmark] {
        sections.flatMap(\.bookmarks)
    }

    var body: some View {
        ScrollView {
            // Keep every card in the scroll view's single lazy layout, including
            // large date groups and the ungrouped search results.
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.bookmarks) { bookmark in
                            NativeContextMenuHost(
                                content: BookmarkGridCard(
                                    bookmark: bookmark,
                                    collectionName: collectionName(bookmark.id),
                                    isSelected: selection.contains(bookmark.id),
                                    faviconLoader: faviconLoader,
                                    showsURLHostOnly: showsURLHostOnly,
                                    onSelect: {
                                        selectBookmark(bookmark)
                                    },
                                    onOpenCard: {
                                        isFocused = true
                                        onOpen([bookmark])
                                    }
                                ),
                                menuProvider: { _ in
                                    bookmarkContextMenu(for: bookmark)
                                }
                            )
                        }
                    } header: {
                        sectionHeader(section)
                            .padding(.top, section.id == sections.first?.id ? 0 : 10)
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
            selectionAnchorID = stableSelectionAnchorID(in: selection)
            isFocused = true
        }
        .onChange(of: selection) { _, newValue in
            if newValue.isEmpty {
                selectionAnchorID = nil
            } else if let anchor = selectionAnchorID, !newValue.contains(anchor) {
                selectionAnchorID = stableSelectionAnchorID(in: newValue)
            }
        }
        .onKeyPress { keyPress in
            handleKeyPress(keyPress)
        }
    }

    private func sectionHeader(_ section: BookmarkGridSection) -> some View {
        Group {
            if !section.title.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(section.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(section.subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func selectBookmark(_ bookmark: Bookmark) {
        isFocused = true

        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers.contains(.shift) {
            let orderedIDs = orderedBookmarks.map(\.id)
            let anchor = selectionAnchorID ?? stableSelectionAnchorID(in: selection) ?? bookmark.id
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
        if !selection.contains(bookmark.id) {
            selection = [bookmark.id]
            selectionAnchorID = bookmark.id
        }
        isFocused = true
    }

    private func bookmarkContextMenu(for bookmark: Bookmark) -> NSMenu? {
        alignSelectionForContextMenu(bookmark)
        return contextMenuController.makeMenu(
            configuration: contextMenuConfiguration(for: bookmark)
        )
    }

    private func contextMenuConfiguration(
        for bookmark: Bookmark
    ) -> NativeBookmarkContextMenuConfiguration {
        let targets = targetBookmarks(contextBookmark: bookmark)
        var configuration = NativeBookmarkContextMenuConfiguration()

        configuration.onOpen = {
            onOpen(targetBookmarks(contextBookmark: bookmark))
        }
        configuration.onCopyURL = {
            onCopyURL(targetBookmarks(contextBookmark: bookmark))
        }
        if targets.count == 1 {
            configuration.onEdit = {
                let currentTargets = targetBookmarks(contextBookmark: bookmark)
                guard currentTargets.count == 1, let target = currentTargets.first else { return }
                onEdit(target)
            }
        }
        if canRevertTitle(for: targets) {
            configuration.onRevertTitleOptimization = {
                onRevertTitleOptimization?(targetBookmarkIDs(contextBookmark: bookmark))
            }
        }
        if targets.contains(where: { $0.titleOptimizationState == .failed }),
           onRetryTitleOptimization != nil {
            configuration.onRetryTitleOptimization = {
                onRetryTitleOptimization?(targetBookmarkIDs(contextBookmark: bookmark))
            }
        }
        if !collectionAssignOptions.isEmpty {
            configuration.collectionAssignOptions = collectionAssignOptions
            configuration.onAssignCollection = { collectionId in
                onAssignCollection(targetBookmarkIDs(contextBookmark: bookmark), collectionId)
            }
        }
        if let hiddenStateActionTitle, onSetHidden != nil {
            configuration.hiddenStateActionTitle = hiddenStateActionTitle
            configuration.hiddenStateSystemSymbolName = restoreBookmarkSymbolName(
                for: hiddenStateActionTitle,
                defaultSymbolName: "eye.slash"
            )
            configuration.onSetHidden = {
                onSetHidden?(targetBookmarkIDs(contextBookmark: bookmark))
            }
        }
        if let archiveStateActionTitle, onSetArchived != nil {
            configuration.archiveStateActionTitle = archiveStateActionTitle
            configuration.archiveStateSystemSymbolName = restoreBookmarkSymbolName(
                for: archiveStateActionTitle,
                defaultSymbolName: "archivebox"
            )
            configuration.onSetArchived = {
                onSetArchived?(targetBookmarkIDs(contextBookmark: bookmark))
            }
        }
        configuration.onDelete = {
            onDelete(targetBookmarkIDs(contextBookmark: bookmark))
        }
        return configuration
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

    private func stableSelectionAnchorID(in selection: Set<Bookmark.ID>) -> Bookmark.ID? {
        BookmarkGridSelectionResolver.stableAnchorID(
            orderedIDs: orderedBookmarks.map(\.id),
            selection: selection
        )
    }

    private func restoreBookmarkSymbolName(for title: String, defaultSymbolName: String) -> String {
        let restoreTitle = "恢复到书签"
        if title == restoreTitle || title == restoreTitle.obeliskLocalized {
            return "bookmark"
        }
        return defaultSymbolName
    }

    private func canRevertTitle(for bookmarks: [Bookmark]) -> Bool {
        guard onRevertTitleOptimization != nil else { return false }
        return bookmarks.contains { bookmark in
            guard bookmark.titleOptimizationState == .succeeded else { return false }
            let original = bookmark.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !original.isEmpty
        }
    }

    private func clearSelection() -> KeyPress.Result {
        guard !selection.isEmpty else { return .ignored }
        selection = []
        selectionAnchorID = nil
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
    let collectionName: String?
    let isSelected: Bool
    let faviconLoader: FaviconLoader
    let showsURLHostOnly: Bool
    let onSelect: () -> Void
    let onOpenCard: () -> Void

    @State private var isPressed = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                BookmarkGridFaviconView(
                    url: bookmark.url,
                    faviconLoader: faviconLoader
                )

                Spacer(minLength: collectionName == nil ? 0 : 8)

                if let collectionName {
                    Text(collectionName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.trailing)
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
        .animation(.easeOut(duration: 0.12), value: isHovered)
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
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bookmark.title)
    }

    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        return shape
            .fill(.thinMaterial)
            .overlay {
                shape.fill(
                    isSelected
                        ? Color.accentColor.opacity(0.14)
                        : Color.primary.opacity(isHovered ? 0.08 : 0.018)
                )
            }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(
                isSelected
                    ? Color.accentColor.opacity(0.75)
                    : Color(nsColor: .separatorColor).opacity(isHovered ? 0.70 : 0.42),
                lineWidth: isSelected ? 1.4 : 1
            )
    }

    private var displayURL: String {
        guard showsURLHostOnly, let host = URL(string: bookmark.url)?.host(percentEncoded: false) else {
            return bookmark.url
        }
        return host
    }

}

private struct BookmarkGridFaviconView: View {
    let url: String
    let faviconLoader: FaviconLoader
    @State private var favicon: NSImage?

    var body: some View {
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
        .task(id: LoadRequest(url: url, version: faviconLoader.imageVersion(for: url))) {
            let image = await faviconLoader.loadImage(for: url)
            guard !Task.isCancelled else { return }
            favicon = image
        }
    }

    private struct LoadRequest: Hashable {
        let url: String
        let version: Int
    }
}

enum BookmarkGridSelectionResolver {
    static func stableAnchorID<ID: Hashable>(orderedIDs: [ID], selection: Set<ID>) -> ID? {
        orderedIDs.first { selection.contains($0) }
    }
}
