import AppKit
import SwiftUI

/// Menu bar popover notification shown after a silent bookmark add.
///
/// Visual styles all share the same layout; distinction is purely
/// through the left-hand icon and its restrained gradient colour:
/// - **Success** (normal bookmark): green gradient checkmark
/// - **Hidden** (hidden bookmark): muted gray eye-slash
/// - **Undo** (reverted add): blue-purple undo arrow
/// - **Intelligence** (bookmark optimization): Siri icon with dark-to-color gradient
/// - **Error** (duplicate / no URL / etc.): red gradient x-mark
@MainActor
struct BookmarkAddedNotificationView: View {
    let title: String
    let subtitle: String
    let kind: Kind

    enum Kind {
        case success
        case hidden
        case undo
        case intelligence
        case error
    }

    private var iconName: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .hidden:  "eye.slash.circle.fill"
        case .undo:    "arrow.uturn.backward.circle.fill"
        case .intelligence: IntelligenceSymbolIcon.symbolName
        case .error:   "xmark.circle.fill"
        }
    }

    /// Subtle top-to-bottom gradients so the icons feel premium without
    /// screaming for attention.
    private var iconGradient: LinearGradient {
        switch kind {
        case .success:
            LinearGradient(
                colors: [
                    Color(red: 0.18, green: 0.78, blue: 0.35),
                    Color(red: 0.12, green: 0.64, blue: 0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .hidden:
            LinearGradient(
                colors: [
                    Color.primary.opacity(0.42),
                    Color.primary.opacity(0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .undo:
            LinearGradient(
                colors: [
                    Color(red: 0.38, green: 0.48, blue: 0.96),
                    Color(red: 0.46, green: 0.30, blue: 0.78)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .intelligence:
            LinearGradient(
                colors: [Color.clear, Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        case .error:
            LinearGradient(
                colors: [
                    Color(red: 0.94, green: 0.27, blue: 0.22),
                    Color(red: 0.82, green: 0.18, blue: 0.15)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            iconView

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(verbatim: subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 280, alignment: .leading)
    }

    @ViewBuilder
    private var iconView: some View {
        if kind == .intelligence {
            IntelligenceSymbolIcon(size: 26, weight: .medium)
                .frame(width: 32, height: 32)
        } else {
            Image(systemName: iconName)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(iconGradient)
                .frame(width: 32, height: 32)
        }
    }
}

@MainActor
struct MenuBarBookmarkSearchView: View {
    @Bindable var model: BookmarksModel
    let faviconLoader: FaviconLoader
    var showsURLHostOnly: Bool
    let onOpen: (Bookmark) -> Void
    let onClose: () -> Void

    @State private var searchText = ""
    @State private var selection: Set<Bookmark.ID> = []

    private var searchSections: [BookmarkListSection] {
        model.bookmarkLibrarySections(
            for: model.searchBookmarks(matching: searchText),
            pinnedSortMode: .storedForPinned,
            collectionSortMode: .storedForCollections,
            ungroupedSortMode: .storedForUngrouped
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeSearchField(
                text: $searchText,
                placeholder: "搜索",
                focusesOnAppear: true,
                onEscape: onClose
            )
            .frame(height: 32)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            if searchSections.isEmpty {
                ContentUnavailableView {
                    Label("没有结果", systemImage: "magnifyingglass")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativeBookmarkList(
                    sections: searchSections,
                    selection: $selection,
                    faviconLoader: faviconLoader,
                    faviconVersion: faviconLoader.version,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: { bookmark in
                        onClose()
                        onOpen(bookmark)
                    }
                )
            }
        }
        .frame(width: 420, height: 520)
    }
}
