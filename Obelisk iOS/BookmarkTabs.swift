import ObeliskCore
import SwiftUI

struct BookmarksTabView: View {
    let library: ObeliskLibraryModel
    @State private var showsAddBookmark = false

    var body: some View {
        NavigationStack {
            Group {
                if library.bookmarks.isEmpty {
                    ContentUnavailableView(
                        "还没有书签",
                        systemImage: "bookmark",
                        description: Text("添加第一个书签后，它会显示在这里")
                    )
                } else {
                    List {
                        if !library.pinnedBookmarks.isEmpty {
                            Section("置顶") {
                                ForEach(BookmarkSectionItem.items(library.pinnedBookmarks, section: .pinned)) { item in
                                    BookmarkButton(bookmark: item.bookmark, library: library)
                                }
                            }
                        }

                        if !library.recentlyAddedBookmarks.isEmpty {
                            Section("最近添加") {
                                ForEach(BookmarkSectionItem.items(library.recentlyAddedBookmarks, section: .recent)) { item in
                                    BookmarkButton(bookmark: item.bookmark, library: library)
                                }
                            }
                        }

                        if !library.ungroupedBookmarks.isEmpty {
                            Section("未分组") {
                                ForEach(BookmarkSectionItem.items(library.ungroupedBookmarks, section: .ungrouped)) { item in
                                    BookmarkButton(bookmark: item.bookmark, library: library)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("书签")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("添加书签", systemImage: "plus") {
                        showsAddBookmark = true
                    }
                }
            }
            .sheet(isPresented: $showsAddBookmark) {
                AddBookmarkView(library: library)
            }
        }
    }
}

struct BookmarkSectionItem: Identifiable {
    enum Section: Hashable {
        case pinned
        case recent
        case ungrouped
    }

    struct ID: Hashable {
        let section: Section
        let bookmarkID: UUID
    }

    let bookmark: Bookmark
    let section: Section

    var id: ID {
        ID(section: section, bookmarkID: bookmark.id)
    }

    static func items(_ bookmarks: [Bookmark], section: Section) -> [Self] {
        bookmarks.map { Self(bookmark: $0, section: section) }
    }
}

struct GroupsTabView: View {
    let library: ObeliskLibraryModel
    @State private var showsAddCollection = false

    var body: some View {
        NavigationStack {
            Group {
                if library.collections.isEmpty {
                    ContentUnavailableView(
                        "还没有分组",
                        systemImage: "folder",
                        description: Text("创建分组来整理你的书签")
                    )
                } else {
                    List {
                        Section("我的分组") {
                            ForEach(library.collections) { collection in
                                NavigationLink {
                                    CollectionBookmarksView(
                                        collection: collection,
                                        library: library
                                    )
                                } label: {
                                    CollectionRow(
                                        collection: collection,
                                        bookmarkCount: library.bookmarks(in: collection.id).count
                                    )
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("分组")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("添加分组", systemImage: "plus") {
                        showsAddCollection = true
                    }
                }
            }
            .sheet(isPresented: $showsAddCollection) {
                AddCollectionView(library: library)
                    .presentationDetents([.medium])
            }
        }
    }
}

struct RecentTabView: View {
    let library: ObeliskLibraryModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    sourcePicker
                }

                content
            }
            .listStyle(.insetGrouped)
            .navigationTitle("最近浏览")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var sourcePicker: some View {
        HStack(spacing: 12) {
            Menu {
                Section("浏览器") {
                    ForEach(BrowserHistoryBrowser.allCases) { browser in
                        if browser.isImplemented {
                            Toggle(isOn: Binding(
                                get: { enabledBrowsers.contains(browser) },
                                set: { setBrowser(browser, enabled: $0) }
                            )) {
                                browserLabel(browser)
                            }
                        } else {
                            Button {} label: {
                                browserLabel(browser)
                            }
                            .disabled(true)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    ForEach(Array(selectedBrowsers.prefix(2))) { browser in
                        BrowserHistoryBrowserIconView(browser: browser)
                    }
                    if selectedBrowsers.count > 2 {
                        Text("+\(selectedBrowsers.count - 2)")
                            .font(.caption)
                    }
                    if selectedBrowsers.isEmpty {
                        Image(systemName: "network")
                    }
                    Text(sourceMenuTitle)
                        .lineLimit(1)
                }
            }
            .accessibilityIdentifier("recent-browser-picker")
            .buttonStyle(.bordered)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    @ViewBuilder
    private var content: some View {
        if enabledBrowsers.isEmpty {
            Section {
                ContentUnavailableView {
                    Label("选择浏览器", systemImage: "network")
                } description: {
                    Text("Obelisk 显示所选浏览器最近访问过的网页")
                }
                .emptyStateListRow()
            }
        } else if library.browserHistorySections.isEmpty {
            Section {
                ContentUnavailableView(
                    "没有最近浏览",
                    systemImage: "clock",
                    description: Text("macOS 读取浏览器历史后，最近访问的网页会同步到这里")
                )
                .emptyStateListRow()
            }
        } else {
            ForEach(library.browserHistorySections) { section in
                Section(section.title) {
                    ForEach(section.records) { record in
                        BrowserHistoryButton(record: record)
                    }
                }
            }
        }
    }

    private func browserLabel(_ browser: BrowserHistoryBrowser) -> some View {
        Label {
            Text(browser.optionTitle)
        } icon: {
            BrowserHistoryBrowserIconView(browser: browser)
        }
    }

    private var enabledBrowsers: Set<BrowserHistoryBrowser> {
        library.enabledBrowserHistoryBrowsers
    }

    private var selectedBrowsers: [BrowserHistoryBrowser] {
        BrowserHistoryBrowser.allCases.filter { enabledBrowsers.contains($0) }
    }

    private var sourceMenuTitle: String {
        selectedBrowsers.isEmpty
            ? "选择浏览器"
            : selectedBrowsers.map(\.title).joined(separator: "，")
    }

    private func setBrowser(_ browser: BrowserHistoryBrowser, enabled: Bool) {
        guard browser.isImplemented else { return }
        var selected = enabledBrowsers
        if enabled {
            selected.insert(browser)
        } else {
            selected.remove(browser)
        }
        library.setEnabledBrowserHistoryBrowsers(selected)
    }
}

private struct BrowserHistoryButton: View {
    let record: BrowserHistoryRecord

    @Environment(\.openURL) private var openURL
    @AppStorage("showsURLHostOnly") private var showsURLHostOnly = true

    var body: some View {
        Button {
            guard let url = URL(string: record.url) else { return }
            openURL(url)
        } label: {
            HStack(spacing: 12) {
                BookmarkFavicon(urlString: record.url)

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(showsURLHostOnly ? host : record.url)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(record.visitedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    BrowserHistoryBrowserIconView(browser: record.browser, size: 12)
                        .opacity(0.45)
                        .accessibilityLabel(record.browser.title)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var host: String {
        URL(string: record.url)?.host ?? record.url
    }
}

private extension View {
    func emptyStateListRow() -> some View {
        frame(maxWidth: .infinity, minHeight: 320)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

struct SearchTabView: View {
    let library: ObeliskLibraryModel
    @Binding var searchText: String

    var body: some View {
        NavigationStack {
            Group {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "搜索书签",
                        systemImage: "magnifyingglass",
                        description: Text("输入标题、网址或分组名称")
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(results) { bookmark in
                        BookmarkButton(bookmark: bookmark, library: library)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("搜索")
        }
        .searchable(text: $searchText, prompt: "搜索书签")
    }

    private var results: [Bookmark] {
        library.search(searchText)
    }
}

private struct CollectionBookmarksView: View {
    let collection: BookmarkCollection
    let library: ObeliskLibraryModel

    var body: some View {
        Group {
            if bookmarks.isEmpty {
                ContentUnavailableView(
                    "这个分组是空的",
                    systemImage: "folder",
                    description: Text("添加书签时可以将它存入这个分组")
                )
            } else {
                List(bookmarks) { bookmark in
                    BookmarkButton(bookmark: bookmark, library: library)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.large)
    }

    private var bookmarks: [Bookmark] {
        library.bookmarks(in: collection.id)
    }
}

struct BookmarkButton: View {
    let bookmark: Bookmark
    let library: ObeliskLibraryModel
    var trailingText: String?
    var showsManagementActions: Bool

    @Environment(\.openURL) private var openURL
    @State private var editTarget: Bookmark?

    init(
        bookmark: Bookmark,
        library: ObeliskLibraryModel,
        trailingText: String? = nil,
        showsManagementActions: Bool = true
    ) {
        self.bookmark = bookmark
        self.library = library
        self.trailingText = trailingText
        self.showsManagementActions = showsManagementActions
    }

    var body: some View {
        Group {
            if showsManagementActions {
                bookmarkButton
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) {
                            library.deleteBookmark(bookmark)
                        }
                        Button("编辑") {
                            editTarget = bookmark
                        }
                        .tint(.blue)
                    }
            } else {
                bookmarkButton
            }
        }
        .sheet(item: $editTarget) { bookmark in
            EditBookmarkView(bookmark: bookmark, library: library)
        }
    }

    private var bookmarkButton: some View {
        Button {
            guard let url = URL(string: bookmark.url) else { return }
            library.recordUsage(for: bookmark)
            openURL(url)
        } label: {
            BookmarkRow(bookmark: bookmark, trailingText: trailingText)
        }
        .buttonStyle(.plain)
    }
}

private struct BookmarkRow: View {
    let bookmark: Bookmark
    var trailingText: String?

    @AppStorage("showsURLHostOnly") private var showsURLHostOnly = true

    var body: some View {
        HStack(spacing: 12) {
            BookmarkFavicon(urlString: bookmark.url)

            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(showsURLHostOnly ? host : bookmark.url)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let trailingText {
                Text(trailingText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
    }

    private var host: String {
        URL(string: bookmark.url)?.host ?? bookmark.url
    }
}

private struct BookmarkFavicon: View {
    let urlString: String

    @Environment(FaviconStore.self) private var favicons

    var body: some View {
        let _ = favicons.version

        Group {
            if let image = favicons.cachedImage(for: urlString) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "globe")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .task(id: urlString) {
            favicons.load(urlString)
        }
    }
}

private struct CollectionRow: View {
    let collection: BookmarkCollection
    let bookmarkCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(collection.name)
                .foregroundStyle(.primary)
            Text("\(bookmarkCount) 个书签")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
