import AppKit
import ObeliskCore
import SwiftUI

// Content pages share one chronological section model
// The global display preference changes only the layout
extension BookmarkManagerView {
    var bookmarkManagementPage: some View {
        bookmarkResults(
            bookmarks: model.visibleBookmarksSnapshot,
            emptyTitle: "还没有书签",
            emptyDescription: "点击工具栏的 + 添加你的第一个书签",
            emptySystemImage: "bookmark",
            onOpen: openBookmarks,
            hiddenStateActionTitle: "移到隐藏书签".obeliskLocalized,
            onSetHidden: { requestHiddenFromContextMenu(ids: $0, isHidden: true) },
            archiveStateActionTitle: "归档".obeliskLocalized,
            onSetArchived: { requestArchivedFromContextMenu(ids: $0, isArchived: true) }
        )
        .navigationTitle("全部")
    }

    var searchPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeSearchField(text: $searchText, placeholder: "搜索", focusRequest: searchFocusRequest)
                .frame(height: 38)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            CompactBorderedMenuPicker(
                options: searchFilterOptions,
                selection: searchFilterBinding,
                title: { searchFilterTitle(for: $0) }
            )
            .padding(.leading, 16)
            .padding(.bottom, 6)

            bookmarkResults(
                bookmarks: searchableBookmarks,
                emptyTitle: "没有结果",
                emptyDescription: nil,
                emptySystemImage: "magnifyingglass",
                onOpen: openBookmarks,
                hiddenStateActionTitle: "移到隐藏书签".obeliskLocalized,
                onSetHidden: { requestHiddenFromContextMenu(ids: $0, isHidden: true) },
                archiveStateActionTitleProvider: { bookmarks in
                    let shouldArchive = bookmarks.isEmpty || !bookmarks.allSatisfy { model.isEffectivelyArchived($0) }
                    return shouldArchive ? "归档".obeliskLocalized : "恢复到书签".obeliskLocalized
                },
                onSetArchived: { ids in
                    let bookmarks = model.bookmarks.filter { ids.contains($0.id) }
                    let shouldArchive = bookmarks.isEmpty || !bookmarks.allSatisfy { model.isEffectivelyArchived($0) }
                    requestArchivedFromContextMenu(ids: ids, isArchived: shouldArchive)
                }
            )
        }
        .navigationTitle("搜索")
    }

    var collectionsManagementPage: some View {
        VStack(spacing: 0) {
            HStack {
                CompactBorderedMenuPicker(
                    options: BookmarkListSortMode.allCases,
                    selection: collectionBookmarkSortModeBinding,
                    title: { $0.title }
                )
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            bookmarkResults(
                bookmarks: currentCollectionScopeBookmarks,
                emptyTitle: currentCollectionScopeEmptyTitle,
                emptyDescription: "点击工具栏的 + 添加书签",
                emptySystemImage: "folder",
                preservesInputOrder: collectionBookmarkSortMode == .frequency,
                onOpen: openBookmarks,
                hiddenStateActionTitle: "移到隐藏书签".obeliskLocalized,
                onSetHidden: { requestHiddenFromContextMenu(ids: $0, isHidden: true) },
                archiveStateActionTitle: "归档".obeliskLocalized,
                onSetArchived: { requestArchivedFromContextMenu(ids: $0, isArchived: true) }
            )
        }
        .navigationTitle(currentCollectionScopeTitle)
    }

    var hiddenBookmarkManagementPage: some View {
        bookmarkResults(
            bookmarks: hiddenBookmarks,
            emptyTitle: "还没有隐藏书签",
            emptyDescription: "按 ⌥H 可以把当前浏览器标签添加为隐藏书签",
            emptySystemImage: "eye.slash",
            onOpen: openHiddenBookmarks,
            hiddenStateActionTitle: "恢复到书签".obeliskLocalized,
            onSetHidden: { requestHiddenFromContextMenu(ids: $0, isHidden: false) },
            archiveStateActionTitle: "归档".obeliskLocalized,
            onSetArchived: { requestArchivedFromContextMenu(ids: $0, isArchived: true) }
        )
        .navigationTitle("隐藏书签")
    }

    var archivePage: some View {
        bookmarkResults(
            bookmarks: archivedBookmarks,
            emptyTitle: "没有归档书签",
            emptyDescription: nil,
            emptySystemImage: "archivebox",
            onOpen: openArchivedBookmarks,
            archiveStateActionTitle: "恢复到书签".obeliskLocalized,
            onSetArchived: { requestArchivedFromContextMenu(ids: $0, isArchived: false) }
        )
        .navigationTitle("归档")
    }

    @ViewBuilder
    func bookmarkResults(
        bookmarks: [Bookmark],
        emptyTitle: String,
        emptyDescription: String?,
        emptySystemImage: String,
        preservesInputOrder: Bool = false,
        onOpen: @escaping ([Bookmark]) -> Void,
        hiddenStateActionTitle: String? = nil,
        onSetHidden: ((Set<Bookmark.ID>) -> Void)? = nil,
        archiveStateActionTitle: String? = nil,
        archiveStateActionTitleProvider: (([Bookmark]) -> String)? = nil,
        onSetArchived: ((Set<Bookmark.ID>) -> Void)? = nil
    ) -> some View {
        if bookmarks.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: emptySystemImage)
            } description: {
                if let emptyDescription {
                    Text(emptyDescription)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let sections = preservesInputOrder
                ? BookmarkGridSection.orderedSection(from: bookmarks)
                : BookmarkGridSection.dateSections(from: bookmarks)
            if bookmarkDisplayMode == .dateGrid {
                BookmarkSectionGridView(
                    sections: sections,
                    selection: $selection,
                    faviconLoader: faviconLoader,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: onOpen,
                    onCopyURL: copyURLs,
                    onEdit: { presentation = .edit($0) },
                    onDelete: requestDelete,
                    hiddenStateActionTitle: hiddenStateActionTitle,
                    onSetHidden: onSetHidden,
                    archiveStateActionTitle: archiveStateActionTitle,
                    onSetArchived: onSetArchived,
                    collectionAssignOptions: collectionAssignOptions,
                    onAssignCollection: assignCollection,
                    collectionName: collectionDisplayName,
                    onRevertTitleOptimization: revertTitleOptimizations,
                    onRetryTitleOptimization: retryTitleOptimization
                )
            } else {
                NativeBookmarkList(
                    sections: sections.listSections,
                    selection: $selection,
                    faviconLoader: faviconLoader,
                    faviconVersion: faviconLoader.version,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: onOpen,
                    onCopyURL: copyURLs,
                    onEdit: { presentation = .edit($0) },
                    onDelete: requestDelete,
                    hiddenStateActionTitle: hiddenStateActionTitle,
                    onSetHidden: onSetHidden,
                    archiveStateActionTitle: archiveStateActionTitle,
                    archiveStateActionTitleProvider: archiveStateActionTitleProvider,
                    onSetArchived: onSetArchived,
                    collectionAssignOptions: collectionAssignOptions,
                    onAssignCollection: assignCollection,
                    onRevertTitleOptimization: revertTitleOptimizations,
                    onRetryTitleOptimization: retryTitleOptimization
                )
            }
        }
    }
}

extension Array where Element == BookmarkGridSection {
    var listSections: [BookmarkListSection] {
        map { BookmarkListSection(title: $0.title.isEmpty ? nil : $0.title, bookmarks: $0.bookmarks) }
    }
}
