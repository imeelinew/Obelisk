import AppKit
import ObeliskCore
import ObeliskSync
import SwiftUI

// Content pages: bookmarks, search, collections, hidden bookmarks, archive
extension BookmarkManagerView {
    var bookmarkManagementPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.bookmarks.isEmpty {
                bookmarkDisplayModePicker
                    .padding(.leading, 0)
                    .padding(.trailing, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }

            if model.bookmarks.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("还没有书签")
                    } icon: {
                        Image(nsImage: AppIcon.image(size: NSSize(width: 28, height: 28)))
                    }
                } description: {
                    Text("点击工具栏的 + 添加你的第一个书签")
                }
            } else if bookmarkDisplayMode == .dateGrid, visibleBookmarks.isEmpty {
                ContentUnavailableView {
                    Label("没有可见书签", systemImage: "square.grid.2x2")
                } description: {
                    Text("隐藏书签和归档书签不会显示在这里")
                }
            } else if bookmarkDisplayMode == .dateGrid {
                BookmarkSectionGridView(
                    sections: dateGridBookmarkSections,
                    selection: $selection,
                    faviconLoader: faviconLoader,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: { bookmarks in openBookmarks(bookmarks) },
                    onCopyURL: { bookmarks in copyURLs(of: bookmarks) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    hiddenStateActionTitle: "移到隐藏书签".obeliskLocalized,
                    onSetHidden: { ids in requestHiddenFromContextMenu(ids: ids, isHidden: true) },
                    archiveStateActionTitle: "归档".obeliskLocalized,
                    onSetArchived: { ids in requestArchivedFromContextMenu(ids: ids, isArchived: true) },
                    onSetPinned: { ids in requestPinFromContextMenu(ids: ids) },
                    collectionAssignOptions: collectionAssignOptions,
                    onAssignCollection: { bookmarkIds, collectionId in
                        requestAssignCollectionFromContextMenu(bookmarkIds: bookmarkIds, collectionId: collectionId)
                    },
                    onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                )
            } else if bookmarkSections.isEmpty {
                ContentUnavailableView {
                    Label("没有未分组的书签", systemImage: "bookmark")
                } description: {
                    Text("已放入分组的书签在「分组」页查看")
                }
            } else {
                NativeBookmarkList(
                    sections: bookmarkSections,
                    selection: $selection,
                    faviconLoader: faviconLoader,
                    faviconVersion: faviconLoader.version,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: { bookmarks in openBookmarks(bookmarks) },
                    onCopyURL: { bookmarks in copyURLs(of: bookmarks) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    hiddenStateActionTitle: "移到隐藏书签".obeliskLocalized,
                    onSetHidden: { ids in requestHiddenFromContextMenu(ids: ids, isHidden: true) },
                    archiveStateActionTitle: "归档".obeliskLocalized,
                    onSetArchived: { ids in requestArchivedFromContextMenu(ids: ids, isArchived: true) },
                    onSetPinned: { ids in requestPinFromContextMenu(ids: ids) },
                    onSortModeChange: { sortMode, scope in
                        updateBookmarkListSortMode(sortMode, scope: scope)
                    },
                    collectionAssignOptions: collectionAssignOptions,
                    onAssignCollection: { bookmarkIds, collectionId in
                        requestAssignCollectionFromContextMenu(bookmarkIds: bookmarkIds, collectionId: collectionId)
                    },
                    onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                )
            }
        }
        .navigationTitle("书签")
    }

    var bookmarkDisplayModePicker: some View {
        HStack(spacing: 10) {
            Picker("", selection: bookmarkDisplayModeBinding) {
                ForEach([BookmarkDisplayMode.dateGrid, .list]) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 154)

            Spacer(minLength: 0)
        }
    }

    var hiddenBookmarkDisplayModePicker: some View {
        HStack(spacing: 10) {
            Picker("", selection: hiddenBookmarkDisplayModeBinding) {
                ForEach([BookmarkDisplayMode.dateGrid, .list]) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 154)

            Spacer(minLength: 0)
        }
    }

    var collectionBookmarkDisplayModePicker: some View {
        HStack(spacing: 10) {
            Picker("", selection: collectionBookmarkDisplayModeBinding) {
                ForEach([BookmarkDisplayMode.dateGrid, .list]) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 154)

            Spacer(minLength: 0)
        }
    }

    var searchPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeSearchField(
                text: $searchText,
                placeholder: "搜索",
                focusRequest: searchFocusRequest
            )
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

            if searchBookmarkSections.isEmpty {
                ContentUnavailableView {
                    Label("没有结果", systemImage: "magnifyingglass")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativeBookmarkList(
                    sections: searchBookmarkSections,
                    selection: $selection,
                    faviconLoader: faviconLoader,
                    faviconVersion: faviconLoader.version,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: { bookmarks in openBookmarks(bookmarks) },
                    onCopyURL: { bookmarks in copyURLs(of: bookmarks) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    hiddenStateActionTitle: "移到隐藏书签".obeliskLocalized,
                    onSetHidden: { ids in requestHiddenFromContextMenu(ids: ids, isHidden: true) },
                    archiveStateActionTitleProvider: { bookmarks in
                        let shouldArchive = bookmarks.isEmpty || !bookmarks.allSatisfy { model.isEffectivelyArchived($0) }
                        return shouldArchive ? "归档".obeliskLocalized : "恢复到书签".obeliskLocalized
                    },
                    onSetArchived: { ids in
                        let bookmarks = model.bookmarks.filter { ids.contains($0.id) }
                        let shouldArchive = bookmarks.isEmpty || !bookmarks.allSatisfy { model.isEffectivelyArchived($0) }
                        requestArchivedFromContextMenu(ids: ids, isArchived: shouldArchive)
                    },
                    onSetPinned: { ids in requestPinFromContextMenu(ids: ids) },
                    collectionAssignOptions: collectionAssignOptions,
                    onAssignCollection: { bookmarkIds, collectionId in
                        requestAssignCollectionFromContextMenu(bookmarkIds: bookmarkIds, collectionId: collectionId)
                    },
                    onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                )
            }
        }
        .navigationTitle("搜索")
    }

    var collectionsManagementPage: some View {
        VStack(spacing: 0) {
            if !model.collections.isEmpty {
                collectionBookmarkDisplayModePicker
                    .padding(.leading, 0)
                    .padding(.trailing, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }

            if model.collections.isEmpty {
                ContentUnavailableView {
                    Label("还没有分组", systemImage: "folder")
                } description: {
                    Text("点击工具栏 + 创建分组")
                }
            } else if collectionBookmarkDisplayMode == .dateGrid {
                BookmarkSectionGridView(
                    sections: collectionGridSections,
                    selection: $selection,
                    selectedCollectionId: $selectedCollectionId,
                    faviconLoader: faviconLoader,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: { bookmarks in openBookmarks(bookmarks) },
                    onCopyURL: { bookmarks in copyURLs(of: bookmarks) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    hiddenStateActionTitle: "移到隐藏书签".obeliskLocalized,
                    onSetHidden: { ids in requestHiddenFromContextMenu(ids: ids, isHidden: true) },
                    archiveStateActionTitle: "归档".obeliskLocalized,
                    onSetArchived: { ids in requestArchivedFromContextMenu(ids: ids, isArchived: true) },
                    onSetPinned: { ids in requestPinFromContextMenu(ids: ids) },
                    collectionAssignOptions: collectionAssignOptions,
                    onAssignCollection: { bookmarkIds, collectionId in
                        requestAssignCollectionFromContextMenu(bookmarkIds: bookmarkIds, collectionId: collectionId)
                    },
                    onRenameCollection: { id in beginRenameCollection(id: id) },
                    onDeleteCollection: { id in beginDeleteCollection(id: id) },
                    onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                )
            } else if collectionBookmarkSections.allSatisfy({ $0.bookmarks.isEmpty }) {
                NativeBookmarkList(
                    sections: collectionBookmarkSections,
                    selection: $selection,
                    selectedCollectionId: $selectedCollectionId,
                    faviconLoader: faviconLoader,
                    faviconVersion: faviconLoader.version,
                    showsURLHostOnly: showsURLHostOnly,
                    onSortModeChange: { sortMode, _ in collectionListSortMode = sortMode },
                    onRenameCollection: { id in beginRenameCollection(id: id) },
                    onDeleteCollection: { id in beginDeleteCollection(id: id) },
                    onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                )
            } else {
                NativeBookmarkList(
                    sections: collectionBookmarkSections,
                    selection: $selection,
                    selectedCollectionId: $selectedCollectionId,
                    faviconLoader: faviconLoader,
                    faviconVersion: faviconLoader.version,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: { bookmarks in openBookmarks(bookmarks) },
                    onCopyURL: { bookmarks in copyURLs(of: bookmarks) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    hiddenStateActionTitle: "移到隐藏书签".obeliskLocalized,
                    onSetHidden: { ids in requestHiddenFromContextMenu(ids: ids, isHidden: true) },
                    archiveStateActionTitle: "归档".obeliskLocalized,
                    onSetArchived: { ids in requestArchivedFromContextMenu(ids: ids, isArchived: true) },
                    onSetPinned: { ids in requestPinFromContextMenu(ids: ids) },
                    onSortModeChange: { sortMode, _ in collectionListSortMode = sortMode },
                    collectionAssignOptions: collectionAssignOptions,
                    onAssignCollection: { bookmarkIds, collectionId in
                        requestAssignCollectionFromContextMenu(bookmarkIds: bookmarkIds, collectionId: collectionId)
                    },
                    onRenameCollection: { id in beginRenameCollection(id: id) },
                    onDeleteCollection: { id in beginDeleteCollection(id: id) },
                    onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                )
            }
        }
        .navigationTitle("分组")
    }

    var hiddenBookmarkManagementPage: some View {
        Group {
            if hiddenBookmarks.isEmpty {
                ContentUnavailableView {
                    Label("还没有隐藏书签", systemImage: "eye.slash")
                } description: {
                    Text("按 ⌥H 可以把当前浏览器标签添加为隐藏书签")
                }
            } else if hiddenBookmarkDisplayMode == .dateGrid {
                VStack(spacing: 0) {
                    hiddenBookmarkDisplayModePicker
                        .padding(.leading, 0)
                        .padding(.trailing, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    BookmarkSectionGridView(
                        sections: hiddenBookmarkDateGridSections,
                        selection: $selection,
                        faviconLoader: faviconLoader,
                        showsURLHostOnly: showsURLHostOnly,
                        onOpen: { bookmarks in openHiddenBookmarks(bookmarks) },
                        onCopyURL: { bookmarks in copyURLs(of: bookmarks) },
                        onEdit: { bookmark in presentation = .edit(bookmark) },
                        onDelete: { ids in requestDelete(ids: ids) },
                        hiddenStateActionTitle: "恢复到书签".obeliskLocalized,
                        onSetHidden: { ids in requestHiddenFromContextMenu(ids: ids, isHidden: false) },
                        archiveStateActionTitle: "归档".obeliskLocalized,
                        onSetArchived: { ids in requestArchivedFromContextMenu(ids: ids, isArchived: true) },
                        onSetPinned: { ids in requestPinFromContextMenu(ids: ids) },
                        collectionAssignOptions: collectionAssignOptions,
                        onAssignCollection: { bookmarkIds, collectionId in
                            requestAssignCollectionFromContextMenu(bookmarkIds: bookmarkIds, collectionId: collectionId)
                        },
                        onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    hiddenBookmarkDisplayModePicker
                        .padding(.leading, 0)
                        .padding(.trailing, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    hiddenBookmarkSortMenu
                        .padding(.leading, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    NativeBookmarkList(
                        sections: hiddenBookmarkSections,
                        selection: $selection,
                        faviconLoader: faviconLoader,
                        faviconVersion: faviconLoader.version,
                        showsURLHostOnly: showsURLHostOnly,
                        onOpen: { bookmarks in openHiddenBookmarks(bookmarks) },
                        onCopyURL: { bookmarks in copyURLs(of: bookmarks) },
                        onEdit: { bookmark in presentation = .edit(bookmark) },
                        onDelete: { ids in requestDelete(ids: ids) },
                        hiddenStateActionTitle: "恢复到书签".obeliskLocalized,
                        onSetHidden: { ids in requestHiddenFromContextMenu(ids: ids, isHidden: false) },
                        onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                    )
                }
            }
        }
        .navigationTitle("隐藏书签")
    }

    var archivePage: some View {
        VStack(spacing: 0) {
            Form {
                Section("自动归档") {
                    Toggle(
                        "自动归档闲置书签",
                        isOn: Binding(
                            get: { autoArchiveEnabled },
                            set: { newValue in
                                autoArchiveEnabled = newValue
                                syncArchiveSettings()
                            }
                        )
                    )

                    if autoArchiveEnabled {
                        LabeledContent {
                            HStack(spacing: 10) {
                                Text("\(archiveAfterDays)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 24, alignment: .trailing)

                                Stepper(
                                    "闲置天数",
                                    value: Binding(
                                        get: { archiveAfterDays },
                                        set: { newValue in
                                            archiveAfterDays = BookmarksModel.clampedArchiveAfterDays(newValue)
                                            syncArchiveSettings()
                                        }
                                    ),
                                    in: BookmarksModel.minArchiveAfterDays...BookmarksModel.maxArchiveAfterDays
                                )
                                .labelsHidden()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("闲置天数")
                                Text("Obelisk 会自动将超过这个天数没有打开的书签归档")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
            .settingsContentMargins()
            .frame(height: 190)

            if archivedBookmarks.isEmpty {
                ContentUnavailableView {
                    Label("没有归档书签", systemImage: "archivebox")
                } description: {
                    if autoArchiveEnabled {
                        Text("闲置书签会在达到设定天数后自动归档")
                    } else {
                        Text("您手动归档的书签会显示在这里")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativeBookmarkList(
                    sections: archivedBookmarkSections,
                    selection: $selection,
                    faviconLoader: faviconLoader,
                    faviconVersion: faviconLoader.version,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: { bookmarks in openArchivedBookmarks(bookmarks) },
                    onCopyURL: { bookmarks in copyURLs(of: bookmarks) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    archiveStateActionTitle: "恢复到书签".obeliskLocalized,
                    onSetArchived: { ids in requestArchivedFromContextMenu(ids: ids, isArchived: false) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("归档")
    }
}
