import SwiftUI

struct ContentView: View {
    @Bindable var library: ObeliskLibraryModel
    @State private var searchText = ""

    var body: some View {
        Group {
            switch library.phase {
            case .idle, .loading:
                ProgressView("正在载入书签…")
            case .ready:
                libraryTabs
            case .failed(let message):
                ContentUnavailableView {
                    Label("无法载入书签", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") {
                        Task { await library.retry() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .alert(
            "无法完成操作",
            isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.clearError() } }
            )
        ) {
            Button("好", role: .cancel) {
                library.clearError()
            }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    private var libraryTabs: some View {
        TabView {
            Tab("书签", systemImage: "bookmark.fill") {
                BookmarksTabView(library: library)
            }

            Tab("分组", systemImage: "folder.fill") {
                GroupsTabView(library: library)
            }

            Tab("最近浏览", systemImage: "clock.fill") {
                RecentTabView(library: library)
            }

            Tab("更多", systemImage: "ellipsis") {
                MoreTabView(library: library)
            }

            Tab(role: .search) {
                SearchTabView(library: library, searchText: $searchText)
            } label: {
                Label("搜索", systemImage: "magnifyingglass")
            }
        }
    }
}

#Preview {
    ContentView(library: ObeliskLibraryModel())
        .environment(FaviconStore())
}
