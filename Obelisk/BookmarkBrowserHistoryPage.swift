import SwiftUI

struct BookmarkBrowserHistoryPage: View {
    let faviconLoader: FaviconLoader
    let showsURLHostOnly: Bool

    @State private var selection: Set<BrowserHistoryRecord.ID> = []
    @State private var sections: [BrowserHistorySection] = []
    @State private var errorMessage: String?
    @State private var requiresFullDiskAccess = false
    @State private var isLoading = false
    @AppStorage(BrowserHistoryPreferences.enabledSourcesStorageKey)
    private var enabledSourcesRaw = BrowserHistoryBrowser.dia.rawValue

    var body: some View {
        VStack(spacing: 0) {
            sourcePicker
            content
        }
        .navigationTitle("最近浏览")
        .task(id: enabledSourcesRaw) {
            await refreshLoop()
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
                                Label {
                                    Text(browser.optionTitle)
                                } icon: {
                                    BrowserHistoryBrowserIconView(browser: browser)
                                }
                            }
                        } else {
                            Button {} label: {
                                Label {
                                    Text(browser.optionTitle)
                                } icon: {
                                    BrowserHistoryBrowserIconView(browser: browser)
                                }
                            }
                            .disabled(true)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    if let browser = singleSelectedBrowser {
                        BrowserHistoryBrowserIconView(browser: browser)
                    } else {
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
                Text("Obelisk 只读显示所选浏览器最近访问过的网页。")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoading && sections.isEmpty {
            ProgressView("正在读取最近浏览...")
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
                Text("过去 \(BrowserHistoryStore.defaultDayLimit) 天内没有找到可显示的网页。")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NativeBrowserHistoryList(
                sections: sections,
                selection: $selection,
                faviconLoader: faviconLoader,
                faviconVersion: faviconLoader.version,
                showsURLHostOnly: showsURLHostOnly
            )
        }
    }

    private var enabledBrowsers: Set<BrowserHistoryBrowser> {
        Set(enabledSourcesRaw
            .split(separator: ",")
            .compactMap { BrowserHistoryBrowser(rawValue: String($0)) }
            .filter(\.isImplemented))
    }

    private var sourceMenuTitle: String {
        let selected = BrowserHistoryBrowser.allCases.filter { enabledBrowsers.contains($0) }
        switch selected.count {
        case 0: return "选择浏览器"
        case 1: return selected[0].title
        default: return "已选 \(selected.count) 个浏览器"
        }
    }

    private var singleSelectedBrowser: BrowserHistoryBrowser? {
        let selected = BrowserHistoryBrowser.allCases.filter { enabledBrowsers.contains($0) }
        return selected.count == 1 ? selected[0] : nil
    }

    private func setBrowser(_ browser: BrowserHistoryBrowser, enabled: Bool) {
        guard browser.isImplemented else { return }
        var selected = enabledBrowsers
        if enabled {
            selected.insert(browser)
        } else {
            selected.remove(browser)
        }
        enabledSourcesRaw = BrowserHistoryBrowser.allCases
            .filter { selected.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
        sections = []
        errorMessage = nil
        requiresFullDiskAccess = false
        isLoading = false
        selection = []
    }

    private func refreshLoop() async {
        await load(force: true)
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
            await load(force: true)
        }
    }

    @MainActor
    private func load(force: Bool) async {
        let requestedBrowsers = enabledBrowsers
        guard !requestedBrowsers.isEmpty else {
            sections = []
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
            sections = loaded
        } catch {
            guard !Task.isCancelled, requestedBrowsers == enabledBrowsers else { return }
            errorMessage = error.localizedDescription
            requiresFullDiskAccess = (error as? BrowserHistoryStoreError)?.requiresFullDiskAccess == true
        }
    }
}
