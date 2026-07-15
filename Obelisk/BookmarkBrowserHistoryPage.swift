import AppKit
import ObeliskCore
import SwiftUI

struct BookmarkBrowserHistoryPage: View {
    let model: BookmarksModel
    let faviconLoader: FaviconLoader
    let showsURLHostOnly: Bool

    @State private var selection: Set<BrowserHistoryRecord.ID> = []
    @State private var errorMessage: String?
    @State private var requiresFullDiskAccess = false
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            sourcePicker
            content
        }
        .navigationTitle("最近浏览")
        .task(id: enabledBrowsers) {
            await load(force: true)
        }
    }

    private var sourcePicker: some View {
        HStack(spacing: 12) {
            Menu {
                Section("浏览器") {
                    ForEach(BrowserHistoryBrowser.allCases) { browser in
                        Toggle(isOn: Binding(
                            get: { enabledBrowsers.contains(browser) },
                            set: { setBrowser(browser, enabled: $0) }
                        )) {
                            Label {
                                Text(browser.title)
                            } icon: {
                                BrowserHistoryBrowserIconView(browser: browser)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    ForEach(selectedBrowsers) { browser in
                        BrowserHistoryBrowserIconView(browser: browser)
                    }
                    if selectedBrowsers.isEmpty {
                        Image(systemName: "network")
                    }
                    Text(sourceMenuTitle)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if enabledBrowsers.isEmpty {
            ContentUnavailableView {
                Label("选择浏览器", systemImage: "network")
            } description: {
                Text("Obelisk 只读显示所选浏览器最近访问过的网页")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoading && sections.isEmpty {
            ProgressView("正在读取最近浏览…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, sections.isEmpty {
            ContentUnavailableView {
                Label("无法读取最近浏览", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                if requiresFullDiskAccess {
                    Button("打开完整磁盘访问权限设置") {
                        PermissionSettingsGuide.open(.fullDiskAccess)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sections.isEmpty {
            ContentUnavailableView {
                Label("没有最近浏览", systemImage: "clock")
            } description: {
                Text("过去 \(BrowserHistoryStore.defaultDayLimit) 天内没有找到可显示的网页")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NativeBrowserHistoryList(
                sections: sections,
                selection: $selection,
                faviconLoader: faviconLoader,
                faviconVersion: faviconLoader.version,
                showsURLHostOnly: showsURLHostOnly,
                onOpen: { record in
                    guard let url = URL(string: record.url) else { return }
                    NSWorkspace.shared.open(url)
                }
            )
        }
    }

    private var enabledBrowsers: Set<BrowserHistoryBrowser> {
        model.enabledBrowserHistoryBrowsers
    }

    private var sections: [BrowserHistorySection] {
        model.browserHistorySections(for: enabledBrowsers)
    }

    private var sourceMenuTitle: String {
        selectedBrowsers.isEmpty
            ? "选择浏览器"
            : selectedBrowsers.map(\.title).joined(separator: "，")
    }

    private var selectedBrowsers: [BrowserHistoryBrowser] {
        BrowserHistoryBrowser.allCases.filter { enabledBrowsers.contains($0) }
    }

    private func setBrowser(_ browser: BrowserHistoryBrowser, enabled: Bool) {
        var selected = enabledBrowsers
        if enabled {
            selected.insert(browser)
        } else {
            selected.remove(browser)
        }
        model.setEnabledBrowserHistoryBrowsers(selected)
        errorMessage = nil
        requiresFullDiskAccess = false
        isLoading = false
        selection = []
    }

    @MainActor
    private func load(force: Bool) async {
        let requestedBrowsers = enabledBrowsers
        guard !requestedBrowsers.isEmpty else {
            errorMessage = nil
            requiresFullDiskAccess = false
            isLoading = false
            return
        }
        guard force || sections.isEmpty, !isLoading else { return }

        isLoading = true
        errorMessage = nil
        requiresFullDiskAccess = false
        defer {
            if requestedBrowsers == enabledBrowsers {
                isLoading = false
            }
        }

        do {
            let loaded = try await Task.detached(priority: .utility) {
                try BrowserHistoryStore(browsers: requestedBrowsers).loadRecentSections()
            }.value
            guard !Task.isCancelled, requestedBrowsers == enabledBrowsers else { return }
            model.reconcileBrowserHistory(
                loaded.flatMap(\.records),
                for: requestedBrowsers
            )
        } catch {
            guard !Task.isCancelled, requestedBrowsers == enabledBrowsers else { return }
            errorMessage = error.localizedDescription
            requiresFullDiskAccess = (error as? BrowserHistoryStoreError)?.requiresFullDiskAccess == true
        }
    }
}
