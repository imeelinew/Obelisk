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
                                ForEach(library.pinnedBookmarks) { bookmark in
                                    BookmarkButton(bookmark: bookmark, library: library)
                                }
                            }
                        }

                        if !library.unpinnedBookmarks.isEmpty {
                            Section("全部书签") {
                                ForEach(library.unpinnedBookmarks) { bookmark in
                                    BookmarkButton(bookmark: bookmark, library: library)
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
    @Environment(\.calendar) private var calendar

    var body: some View {
        NavigationStack {
            Group {
                if recentSections.isEmpty {
                    ContentUnavailableView(
                        "没有浏览记录",
                        systemImage: "clock",
                        description: Text("从 Obelisk 打开书签后，浏览记录会显示在这里")
                    )
                } else {
                    List {
                        ForEach(recentSections) { section in
                            Section(dayTitle(section.day)) {
                                ForEach(section.bookmarks) { bookmark in
                                    BookmarkButton(
                                        bookmark: bookmark,
                                        library: library,
                                        trailingText: library.lastOpenedAt(for: bookmark)?.formatted(
                                            date: .omitted,
                                            time: .shortened
                                        )
                                    )
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("最近浏览")
        }
    }

    private var recentSections: [RecentDaySection] {
        let grouped = Dictionary(grouping: library.recentlyOpenedBookmarks) { bookmark in
            calendar.startOfDay(for: library.lastOpenedAt(for: bookmark) ?? .distantPast)
        }
        return grouped.keys.sorted(by: >).map { day in
            RecentDaySection(day: day, bookmarks: grouped[day] ?? [])
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        return day.formatted(.dateTime.month().day().weekday(.wide))
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

private struct BookmarkButton: View {
    let bookmark: Bookmark
    let library: ObeliskLibraryModel
    var trailingText: String?

    @Environment(\.openURL) private var openURL

    init(
        bookmark: Bookmark,
        library: ObeliskLibraryModel,
        trailingText: String? = nil
    ) {
        self.bookmark = bookmark
        self.library = library
        self.trailingText = trailingText
    }

    var body: some View {
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

    var body: some View {
        HStack(spacing: 12) {
            BookmarkFavicon(urlString: bookmark.url)

            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(host)
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

private struct RecentDaySection: Identifiable {
    let day: Date
    let bookmarks: [Bookmark]

    var id: Date { day }
}
