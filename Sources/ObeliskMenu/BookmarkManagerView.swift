import AppKit
import SwiftUI
import ObeliskCore

struct BookmarkManagerView: View {
    @Bindable var model: BookmarksModel
    let faviconLoader: FaviconLoader
    let addRequest: AddBookmarkRequest
    let onStorageRootChanged: (URL) -> Void
    @State private var selection: Set<Bookmark.ID> = []
    @State private var presentation: Presentation?
    @State private var deleteConfirmation: DeleteConfirmation?
    @State private var toast: Toast?
    @State private var searchText = ""
    @State private var settingsPage: SettingsPage = .bookmarks
    @State private var llmConfig = LLMConfig()
    @State private var llmConfigMessage: String?
    @State private var hiddenBookmarksUnlocked = false
    @State private var isSwitchingICloudSync = false
    @AppStorage("debugSidebarIconTileSize") private var sidebarIconTileSize: Double = 22
    @AppStorage("debugSidebarIconSymbolSize") private var sidebarIconSymbolSize: Double = 11
    @AppStorage("debugSidebarIconCornerRadius") private var sidebarIconCornerRadius: Double = 6
    @AppStorage("showHiddenBookmarksPage") private var showHiddenBookmarksPage = false
    @AppStorage("showsURLHostOnly") private var showsURLHostOnly = false
    @AppStorage("menuFrequentGroupLimit") private var menuFrequentGroupLimit = 5
    @AppStorage("menuRecentGroupLimit") private var menuRecentGroupLimit = 5
    @AppStorage("windowTransparencyEnabled") private var windowTransparencyEnabled = false
    @AppStorage(LocalJSONEncryption.enabledKey) private var encryptLocalJSONData = false
    @AppStorage(ICloudDocumentSync.enabledKey) private var syncWithICloudDrive = false
    @AppStorage("openHiddenBookmarksIncognito") private var openHiddenBookmarksIncognito = false
    // 0 = 完全不透明（默认毛玻璃材质满强度）；上限 0.5（再透可读性会崩）。
    @AppStorage("windowSeeThrough") private var windowSeeThrough: Double = 0.0

    private var effectiveBlurAlpha: Double {
        guard windowTransparencyEnabled else { return 1.0 }
        return 1.0 - min(0.5, max(0.0, windowSeeThrough))
    }

    struct Toast: Equatable, Identifiable {
        enum Kind: Equatable {
            case success
            case error
        }

        let id = UUID()
        let message: String
        let kind: Kind

        var systemImage: String {
            switch kind {
            case .success: return "checkmark.circle.fill"
            case .error: return "xmark.circle.fill"
            }
        }

        var foregroundStyle: Color {
            switch kind {
            case .success: return .primary
            case .error: return Color(red: 0.82, green: 0.18, blue: 0.18)
            }
        }
    }

    enum Presentation: Identifiable {
        // `seq` is part of identity so re-issuing an add request with new
        // prefill while a stale sheet is somehow alive forces a fresh sheet.
        case add(seq: Int, prefilledURL: String?, prefilledTitle: String?, prefilledIsHidden: Bool)
        case edit(Bookmark)

        var id: String {
            switch self {
            case .add(let seq, _, _, _): return "add-\(seq)"
            case .edit(let bookmark): return "edit-\(bookmark.id.uuidString)"
            }
        }
    }

    enum SettingsPage: String, CaseIterable, Hashable, Identifiable {
        case bookmarks
        case hiddenBookmarks
        case appearance
        case sync
        case ai
        case security
        case developer

        var id: String { rawValue }

        enum Group: String, CaseIterable, Identifiable {
            case content = "内容"
            case preferences = "偏好"
            case advanced = "高级"

            var id: String { rawValue }
        }

        var group: Group {
            switch self {
            case .bookmarks, .hiddenBookmarks: return .content
            case .appearance, .sync, .ai:      return .preferences
            case .security, .developer:        return .advanced
            }
        }

        var title: String {
            switch self {
            case .bookmarks: return "书签"
            case .hiddenBookmarks: return "隐藏书签"
            case .appearance: return "外观"
            case .sync: return "同步"
            case .ai: return "AI配置"
            case .security: return "安全"
            case .developer: return "开发者选项"
            }
        }

        var symbolName: String {
            switch self {
            case .bookmarks: return "bookmark.fill"
            case .hiddenBookmarks: return "eye.slash.fill"
            case .appearance: return "paintpalette.fill"
            case .sync: return "icloud.fill"
            case .ai: return "sparkles"
            case .security: return "lock.fill"
            case .developer: return "wrench.fill"
            }
        }

        var iconGradient: LinearGradient {
            switch self {
            case .bookmarks:
                return LinearGradient(
                    colors: [Color(red: 1.0, green: 0.50, blue: 0.40), Color(red: 0.96, green: 0.28, blue: 0.24)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .ai:
                return LinearGradient(
                    colors: [Color(red: 0.30, green: 0.68, blue: 1.0), Color(red: 0.08, green: 0.38, blue: 0.86)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .hiddenBookmarks:
                return LinearGradient(
                    colors: [Color(red: 0.58, green: 0.66, blue: 0.80), Color(red: 0.34, green: 0.44, blue: 0.62)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .appearance:
                return LinearGradient(
                    colors: [Color(red: 0.46, green: 0.82, blue: 0.50), Color(red: 0.14, green: 0.62, blue: 0.30)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .sync:
                return LinearGradient(
                    colors: [Color(red: 0.46, green: 0.78, blue: 1.0), Color(red: 0.18, green: 0.50, blue: 0.92)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .security:
                return LinearGradient(
                    colors: [Color(red: 0.72, green: 0.52, blue: 1.0), Color(red: 0.42, green: 0.24, blue: 0.86)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .developer:
                return LinearGradient(
                    colors: [Color(red: 1.0, green: 0.78, blue: 0.30), Color(red: 0.92, green: 0.52, blue: 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    struct DeleteConfirmation: Identifiable {
        let ids: Set<Bookmark.ID>

        var id: String {
            ids.map(\.uuidString).sorted().joined(separator: ",")
        }

        var count: Int {
            ids.count
        }
    }

    private var filteredFrequent: [Bookmark] {
        filtered(model.frequent)
    }

    private var filteredRecent: [Bookmark] {
        filtered(model.recent)
    }

    private var filteredOthers: [Bookmark] {
        filtered(model.others)
    }

    private var filteredBookmarks: [Bookmark] {
        filtered(visibleBookmarks)
    }

    private var visibleBookmarks: [Bookmark] {
        model.bookmarks.filter { !$0.isHidden }
    }

    private var hiddenBookmarks: [Bookmark] {
        model.bookmarks.filter { $0.isHidden }
    }

    private var filteredHiddenBookmarks: [Bookmark] {
        filtered(hiddenBookmarks)
    }

    private var bookmarkSections: [BookmarkListSection] {
        var sections: [BookmarkListSection] = []

        if !filteredFrequent.isEmpty {
            sections.append(BookmarkListSection(title: "常用", bookmarks: filteredFrequent))
        }

        if !filteredRecent.isEmpty {
            sections.append(BookmarkListSection(title: "最近添加", bookmarks: filteredRecent))
        }

        if !filteredOthers.isEmpty {
            let needsHeader = !filteredFrequent.isEmpty || !filteredRecent.isEmpty
            sections.append(BookmarkListSection(title: needsHeader ? "全部" : nil, bookmarks: filteredOthers))
        }

        return sections
    }

    private var hiddenBookmarkSections: [BookmarkListSection] {
        let bookmarks = filteredHiddenBookmarks
        return bookmarks.isEmpty ? [] : [BookmarkListSection(title: nil, bookmarks: bookmarks)]
    }

    private func filtered(_ bookmarks: [Bookmark]) -> [Bookmark] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return bookmarks
        }

        return bookmarks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.url.localizedCaseInsensitiveContains(query)
        }
    }

    private func consumePendingAddRequestIfNeeded() {
        guard let request = addRequest.consumePending() else { return }
        presentation = .add(
            seq: request.seq,
            prefilledURL: request.url,
            prefilledTitle: request.title,
            prefilledIsHidden: request.isHidden
        )
    }

    private var selectedBookmark: Bookmark? {
        guard selection.count == 1, let id = selection.first else {
            return nil
        }
        return model.bookmarks.first { $0.id == id }
    }

    private var canDeleteSelection: Bool {
        !selection.isEmpty
    }

    private var canUseSingleSelectionActions: Bool {
        selectedBookmark != nil
    }

    private func requestDelete(ids: Set<Bookmark.ID>) {
        guard !ids.isEmpty else { return }
        deleteConfirmation = DeleteConfirmation(ids: ids)
    }

    private func confirmDelete(_ confirmation: DeleteConfirmation) {
        model.delete(ids: confirmation.ids)
        selection.subtract(confirmation.ids)
    }

    private func copyURL(_ bookmark: Bookmark) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bookmark.url, forType: .string)
        showToast("已复制 URL")
    }

    private func setHidden(_ isHidden: Bool, for bookmark: Bookmark) {
        if let errorMessage = model.setHidden(isHidden, for: bookmark.id) {
            model.errorMessage = errorMessage
        } else {
            selection.remove(bookmark.id)
        }
    }

    private func refreshFavicon(for bookmark: Bookmark) {
        faviconLoader.refresh(urlString: bookmark.url)
        showToast("刷新 favicon 成功")
    }

    private func refreshAllFavicons() {
        faviconLoader.refreshAll(urlStrings: model.bookmarks.map(\.url))
        showToast("刷新全部 favicon 成功")
    }

    private func openHiddenBookmark(_ bookmark: Bookmark) {
        guard openHiddenBookmarksIncognito else {
            guard let url = URL(string: bookmark.url) else { return }
            NSWorkspace.shared.open(url)
            return
        }

        switch PrivateBrowserOpener.openIncognito(urlString: bookmark.url) {
        case .opened:
            break
        case .unsupportedBrowser:
            showToast("当前默认浏览器不支持无痕打开", kind: .error)
        case .invalidURL:
            showToast("网址格式不正确", kind: .error)
        case .openFailed:
            showToast("无法打开无痕窗口", kind: .error)
        case .automationPermissionRequired:
            showToast("请允许 Obelisk 控制电脑后重试", kind: .error)
        }
    }

    private func syncMenuGroupLimits() {
        model.setMenuGroupLimits(frequent: menuFrequentGroupLimit, recent: menuRecentGroupLimit)
    }

    private var showsFullURLBinding: Binding<Bool> {
        Binding(
            get: { !showsURLHostOnly },
            set: { showsURLHostOnly = !$0 }
        )
    }

    private var unoptimizedTitleCount: Int {
        model.bookmarks.filter { !$0.titleOptimized && !$0.isHidden }.count
    }

    private var hiddenUnoptimizedTitleCount: Int {
        model.bookmarks.filter { !$0.titleOptimized && $0.isHidden }.count
    }

    private func optimizeTitles(scope: BookmarksModel.TitleOptimizationScope = .visible) {
        Task {
            let message = await model.optimizeAllTitles(scope: scope)
            showToast(message)
        }
    }

    private func showToast(_ message: String, kind: Toast.Kind = .success) {
        withAnimation(.spring(duration: 0.24, bounce: 0.18)) {
            toast = Toast(message: message, kind: kind)
        }
    }

    private var llmConfigStore: LLMConfigStore {
        LLMConfigStore(rootDirectory: model.rootDirectory)
    }

    private func loadLLMConfig() {
        llmConfig = llmConfigStore.load()
    }

    private func saveLLMConfig() {
        do {
            try llmConfigStore.save(llmConfig)
            showToast("模型配置已保存")
        } catch {
            llmConfigMessage = error.localizedDescription
        }
    }

    private func setICloudDocumentSyncEnabled(_ isEnabled: Bool) {
        guard !isSwitchingICloudSync else { return }
        isSwitchingICloudSync = true

        Task {
            do {
                let currentConfig = llmConfigStore.load()
                let targetRoot: URL

                if isEnabled {
                    targetRoot = try await ICloudDocumentSync.resolveRootDirectory()
                    ICloudDocumentSync.setCachedRootDirectory(targetRoot)
                } else {
                    targetRoot = BookmarkStore.defaultLocalRootDirectory()
                }

                try model.migrateStorageRoot(to: targetRoot)
                try LLMConfigStore(rootDirectory: targetRoot).save(currentConfig)
                ICloudDocumentSync.isEnabled = isEnabled
                syncWithICloudDrive = isEnabled
                onStorageRootChanged(targetRoot)
                loadLLMConfig()
                showToast(isEnabled ? "iCloud 同步已开启" : "iCloud 同步已关闭")
            } catch {
                syncWithICloudDrive = ICloudDocumentSync.isEnabled
                llmConfigMessage = error.localizedDescription
            }

            isSwitchingICloudSync = false
        }
    }

    private func setLocalJSONEncryptionEnabled(_ isEnabled: Bool) {
        if !isEnabled {
            Task {
                guard await AuthenticationGate.authenticate(reason: "关闭本地数据加密") else {
                    await MainActor.run {
                        encryptLocalJSONData = true
                    }
                    return
                }
                await MainActor.run {
                    applyLocalJSONEncryptionEnabled(false)
                }
            }
            return
        }

        applyLocalJSONEncryptionEnabled(true)
    }

    private func applyLocalJSONEncryptionEnabled(_ isEnabled: Bool) {
        let previousValue = encryptLocalJSONData
        encryptLocalJSONData = isEnabled
        LocalJSONEncryption.isEnabled = isEnabled

        do {
            try migrateLocalPrivateStorage(isEnabled: isEnabled)
            model.reload()
            loadLLMConfig()
            showToast(isEnabled ? "数据加密已开启" : "数据加密已关闭")
        } catch {
            encryptLocalJSONData = previousValue
            LocalJSONEncryption.isEnabled = previousValue
            llmConfigMessage = error.localizedDescription
        }
    }

    private func migrateLocalPrivateStorage(isEnabled: Bool) throws {
        let root = BookmarkStore.defaultRootDirectory()
        let codec = SecureJSONFileCodec()

        for filename in ["llm.json", "bookmarks.json", "usage.json"] {
            let legacyURL = ObeliskPrivateStorage.legacyFileURL(rootDirectory: root, logicalName: filename)
            let privateURL = ObeliskPrivateStorage.privateFileURL(rootDirectory: root, logicalName: filename)
            let sourceURL = isEnabled ? legacyURL : privateURL
            let destinationURL = isEnabled ? privateURL : legacyURL

            if FileManager.default.fileExists(atPath: sourceURL.path) {
                let plaintext = try codec.readData(from: sourceURL)
                try FileManager.default.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try codec.writeData(plaintext, to: destinationURL)
                try? FileManager.default.removeItem(at: sourceURL)
            } else if FileManager.default.fileExists(atPath: destinationURL.path) {
                try codec.rewriteFile(at: destinationURL)
            }
        }

        if isEnabled {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("favicons", isDirectory: true))
        } else {
            try? FileManager.default.removeItem(at: ObeliskPrivateStorage.faviconDirectory(in: root))
        }
        faviconLoader.reloadStorage()
    }

    private func handleHiddenBookmarksVisibilityChange(isShowing: Bool) {
        guard !isShowing else { return }
        guard settingsPage == SettingsPage.hiddenBookmarks else { return }
        settingsPage = .bookmarks
        hiddenBookmarksUnlocked = false
    }

    private var modelErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deleteConfirmation != nil },
            set: { if !$0 { deleteConfirmation = nil } }
        )
    }

    private var llmConfigAlertBinding: Binding<Bool> {
        Binding(
            get: { llmConfigMessage != nil },
            set: { if !$0 { llmConfigMessage = nil } }
        )
    }

    private func toggleHiddenBookmarksPageVisibility() {
        showHiddenBookmarksPage.toggle()
    }

    private var settingsPageBinding: Binding<SettingsPage?> {
        Binding<SettingsPage?>(
            get: { settingsPage },
            set: { nextPage in
                guard let nextPage else { return }
                if nextPage == .hiddenBookmarks, !hiddenBookmarksUnlocked {
                    Task {
                        guard await AuthenticationGate.authenticate(reason: "查看隐藏书签") else { return }
                        await MainActor.run {
                            hiddenBookmarksUnlocked = true
                            settingsPage = .hiddenBookmarks
                        }
                    }
                    return
                }
                settingsPage = nextPage
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            settingsSidebar
        } detail: {
            settingsDetail
        }
        .environment(\.sidebarIconTileSize, sidebarIconTileSize)
        .environment(\.sidebarIconSymbolSize, sidebarIconSymbolSize)
        .environment(\.sidebarIconCornerRadius, sidebarIconCornerRadius)
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索标题或网址")
        .toolbar {
            settingsToolbar
        }
        .overlay(alignment: .top) {
            toastView
        }
        .background {
            WindowTransparencyConfigurator(enabled: windowTransparencyEnabled)
                .frame(width: 0, height: 0)

            if windowTransparencyEnabled {
                WindowBackgroundBlur(materialAlpha: effectiveBlurAlpha)
                    .ignoresSafeArea()
            }

            Button {
                toggleHiddenBookmarksPageVisibility()
            } label: {
                EmptyView()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .sheet(item: $presentation) { kind in
            switch kind {
            case .add(_, let prefilledURL, let prefilledTitle, let prefilledIsHidden):
                BookmarkEditor(
                    mode: .add,
                    model: model,
                    prefilledURL: prefilledURL,
                    prefilledTitle: prefilledTitle,
                    prefilledIsHidden: prefilledIsHidden
                )
            case .edit(let bookmark):
                BookmarkEditor(mode: .edit(bookmark), model: model)
            }
        }
        .onAppear {
            loadLLMConfig()
            syncMenuGroupLimits()
            // First-launch path: the hotkey may have already bumped seq before
            // the view mounted. .onChange only fires on subsequent updates,
            // so we'd miss the initial request without this check. Subsequent
            // presses (window already open) hit .onChange below.
            consumePendingAddRequestIfNeeded()
        }
        .onChange(of: addRequest.seq) { _, _ in
            consumePendingAddRequestIfNeeded()
        }
        .onChange(of: settingsPage) { _, _ in
            selection.removeAll()
        }
        .onChange(of: showHiddenBookmarksPage) { _, isShowing in
            handleHiddenBookmarksVisibilityChange(isShowing: isShowing)
        }
        .onChange(of: menuFrequentGroupLimit) { _, _ in
            syncMenuGroupLimits()
        }
        .onChange(of: menuRecentGroupLimit) { _, _ in
            syncMenuGroupLimits()
        }
        .task(id: toast) {
            guard let currentToast = toast else { return }
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                guard toast == currentToast else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    toast = nil
                }
            }
        }
        .alert(
            "出错了",
            isPresented: modelErrorAlertBinding,
            presenting: model.errorMessage
        ) { _ in
            Button("好") { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
        .alert(
            "删除书签?",
            isPresented: deleteConfirmationBinding,
            presenting: deleteConfirmation
        ) { confirmation in
            Button("取消", role: .cancel) {
                deleteConfirmation = nil
            }
            Button("删除", role: .destructive) {
                confirmDelete(confirmation)
                deleteConfirmation = nil
            }
        } message: { confirmation in
            Text("共计删除 \(confirmation.count) 个书签。")
        }
        .alert(
            "提示",
            isPresented: llmConfigAlertBinding,
            presenting: llmConfigMessage
        ) { _ in
            Button("好") { llmConfigMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Label(toast.message, systemImage: toast.systemImage)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(toast.foregroundStyle)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .glassEffect(.regular, in: Capsule())
                .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
                .padding(.top, 12)
                .transition(.blurReplace)
                .allowsHitTesting(false)
                .accessibilityAddTraits(.isStaticText)
        }
    }

    private var settingsSidebar: some View {
        List(selection: settingsPageBinding) {
            // 顶部：书签 / 隐藏书签 直接铺开，不带分组标题。
            ForEach(visibleSettingsPages.filter { $0.group == .content }) { page in
                NavigationLink(value: page) {
                    SidebarPageLabel(page: page)
                }
            }

            // 其余按 group 分 Section，跳过 .content 避免重复。
            ForEach(SettingsPage.Group.allCases.filter { $0 != .content }) { group in
                let pages = visibleSettingsPages.filter { $0.group == group }
                if !pages.isEmpty {
                    Section(group.rawValue) {
                        ForEach(pages) { page in
                            NavigationLink(value: page) {
                                SidebarPageLabel(page: page)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("设置")
        .navigationSplitViewColumnWidth(min: 150, ideal: 180)
    }

    private var visibleSettingsPages: [SettingsPage] {
        SettingsPage.allCases.filter { page in
            page != .hiddenBookmarks || showHiddenBookmarksPage
        }
    }

    @ViewBuilder
    private var settingsDetail: some View {
        NavigationStack {
            switch settingsPage {
            case .bookmarks:
                bookmarkManagementPage
            case .hiddenBookmarks:
                hiddenBookmarkManagementPage
            case .appearance:
                appearancePage
            case .sync:
                syncPage
            case .ai:
                aiOptimizationPage
            case .security:
                securityPage
            case .developer:
                developerOptionsPage
            }
        }
    }

    private var bookmarkManagementPage: some View {
        Group {
            if model.bookmarks.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("还没有书签")
                    } icon: {
                        Image(nsImage: AppIcon.image(size: NSSize(width: 28, height: 28)))
                    }
                } description: {
                    Text("点击工具栏的 + 添加你的第一个书签。")
                }
            } else if filteredBookmarks.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                NativeBookmarkList(
                    sections: bookmarkSections,
                    selection: $selection,
                    faviconLoader: faviconLoader,
                    faviconVersion: faviconLoader.version,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: nil,
                    onCopyURL: { bookmark in copyURL(bookmark) },
                    onRefreshFavicon: { bookmark in refreshFavicon(for: bookmark) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    hiddenStateActionTitle: "移到隐藏书签",
                    onSetHidden: { bookmark in setHidden(true, for: bookmark) }
                )
            }
        }
        .navigationTitle("书签")
    }

    private var hiddenBookmarkManagementPage: some View {
        Group {
            if hiddenBookmarks.isEmpty {
                ContentUnavailableView {
                    Label("还没有隐藏书签", systemImage: "eye.slash")
                } description: {
                    Text("按 ⌥H 可以把当前浏览器标签添加为隐藏书签。")
                }
            } else if filteredHiddenBookmarks.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                NativeBookmarkList(
                    sections: hiddenBookmarkSections,
                    selection: $selection,
                    faviconLoader: faviconLoader,
                    faviconVersion: faviconLoader.version,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: { bookmark in openHiddenBookmark(bookmark) },
                    onCopyURL: { bookmark in copyURL(bookmark) },
                    onRefreshFavicon: { bookmark in refreshFavicon(for: bookmark) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    hiddenStateActionTitle: "恢复到书签",
                    onSetHidden: { bookmark in setHidden(false, for: bookmark) }
                )
            }
        }
        .navigationTitle("隐藏书签")
    }

    private var appearancePage: some View {
        Form {
            Section("书签") {
                Toggle("显示完整网站域名", isOn: showsFullURLBinding)
            }

            Section("菜单栏") {
                LabeledContent {
                    Button {
                        refreshAllFavicons()
                    } label: {
                        Text("刷新")
                    }
                    .buttonStyle(.bordered)
                } label: {
                    Text("刷新全部 favicon")
                }

                menuLimitStepper("常用数量", value: $menuFrequentGroupLimit)
                menuLimitStepper("最近添加数量", value: $menuRecentGroupLimit)
            }

            Section("窗口") {
                Toggle("启用窗口透明效果", isOn: $windowTransparencyEnabled)

                if windowTransparencyEnabled {
                    Slider(value: $windowSeeThrough, in: 0...0.5, step: 0.05) {
                        Text("透明度")
                    } minimumValueLabel: {
                        Text("0%")
                    } maximumValueLabel: {
                        Text("50%")
                    }

                    LabeledContent("当前透明度", value: "\(Int(windowSeeThrough * 100))%")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("外观")
    }

    private var syncPage: some View {
        Form {
            Section("iCloud") {
                Toggle(
                    isOn: Binding(
                        get: { syncWithICloudDrive },
                        set: { setICloudDocumentSyncEnabled($0) }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("使用 iCloud 同步")
                        Text("开启后 Obelisk 会通过 iCloud Drive 同步书签数据，并使用系统文件协调处理读写。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isSwitchingICloudSync)

                if isSwitchingICloudSync {
                    ProgressView()
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("同步")
    }

    private func menuLimitStepper(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Text("\(value.wrappedValue)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .trailing)

                Stepper(title, value: value, in: 0...20)
                    .labelsHidden()
            }
        }
    }

    private var aiOptimizationPage: some View {
        Form {
            Section("模型配置") {
                SecureField(text: $llmConfig.apiKey, prompt: Text("sk-...")) {
                    Label("API Key", systemImage: "key")
                }

                TextField(text: $llmConfig.model, prompt: Text("gpt-4.1-mini")) {
                    Label("Model", systemImage: "cpu")
                }

                TextField(text: $llmConfig.baseURL, prompt: Text("https://api.openai.com/v1/chat/completions")) {
                    Label("Base URL", systemImage: "link")
                }

                Button {
                    saveLLMConfig()
                } label: {
                    Text("保存配置")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("AI配置")
    }

    private var securityPage: some View {
        Form {
            Section("安全") {
                Toggle(
                    isOn: Binding(
                        get: { encryptLocalJSONData },
                        set: { setLocalJSONEncryptionEnabled($0) }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("开启加密功能")
                        Text("开启后 Obelisk 会使用 AES-GCM 加密您的书签、使用记录、模型配置和 favicon 缓存。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .help("开启后 Obelisk 会使用 AES-GCM 加密您的书签、使用记录、模型配置和 favicon 缓存。")
            }

            Section("隐藏书签") {
                Toggle(isOn: $openHiddenBookmarksIncognito) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("使用无痕窗口打开隐藏书签")
                        Text("Dia 会复用 Obelisk 创建的无痕窗口；其他 Chromium 浏览器使用启动参数。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("安全")
    }

    private var developerOptionsPage: some View {
        Form {
            Section("Toast 调试") {
                HStack(spacing: 10) {
                    Button("成功 Toast") {
                        showToast("操作成功")
                    }

                    Button("失败 Toast") {
                        showToast("操作失败", kind: .error)
                    }
                }
            }

            Section("侧栏图标调试") {
                centeredValueSlider("背景尺寸", value: $sidebarIconTileSize, range: 16...28)
                centeredValueSlider("符号尺寸", value: $sidebarIconSymbolSize, range: 6...16)
                centeredValueSlider("圆角", value: $sidebarIconCornerRadius, range: 2...10)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("开发者选项")
    }

    private func centeredValueSlider(
        _ title: LocalizedStringKey,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .frame(width: 72, alignment: .leading)

            Slider(value: value, in: range, step: 1)

            Text("\(Int(value.wrappedValue))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        if settingsPage == .bookmarks {
            ToolbarSpacer(.flexible)

            ToolbarItemGroup {
                Button {
                    presentation = .add(seq: 0, prefilledURL: nil, prefilledTitle: nil, prefilledIsHidden: false)
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .disabled(selection.count > 1)
                .help("添加书签")

                Button {
                    requestDelete(ids: selection)
                } label: {
                    Label("删除", systemImage: "minus")
                }
                .disabled(!canDeleteSelection)
                .help("删除选中的书签")

                Button {
                    if let bookmark = selectedBookmark {
                        presentation = .edit(bookmark)
                    }
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .disabled(!canUseSingleSelectionActions)
            }

            ToolbarSpacer(.fixed)

            ToolbarItem {
                Button {
                    optimizeTitles(scope: .visible)
                } label: {
                    Label(
                        model.isOptimizingTitles ? "优化中" : "优化标题",
                        systemImage: model.isOptimizingTitles ? "hourglass" : "sparkles"
                    )
                }
                .disabled(model.bookmarks.isEmpty || model.isOptimizingTitles || unoptimizedTitleCount == 0)
                .help("优化全部未处理的标题")
            }
        } else if settingsPage == .hiddenBookmarks {
            ToolbarSpacer(.flexible)

            ToolbarItemGroup {
                Button {
                    presentation = .add(seq: 0, prefilledURL: nil, prefilledTitle: nil, prefilledIsHidden: true)
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .disabled(selection.count > 1)
                .help("添加隐藏书签")

                Button {
                    requestDelete(ids: selection)
                } label: {
                    Label("删除", systemImage: "minus")
                }
                .disabled(!canDeleteSelection)
                .help("删除选中的隐藏书签")

                Button {
                    if let bookmark = selectedBookmark {
                        presentation = .edit(bookmark)
                    }
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .disabled(!canUseSingleSelectionActions)
            }

            ToolbarSpacer(.fixed)

            ToolbarItem {
                Button {
                    optimizeTitles(scope: .hidden)
                } label: {
                    Label(
                        model.isOptimizingTitles ? "优化中" : "优化标题",
                        systemImage: model.isOptimizingTitles ? "hourglass" : "sparkles"
                    )
                }
                .disabled(hiddenBookmarks.isEmpty || model.isOptimizingTitles || hiddenUnoptimizedTitleCount == 0)
                .help("优化全部未处理的隐藏书签标题")
            }
        }
    }
}

private struct SidebarPageLabel: View {
    let page: BookmarkManagerView.SettingsPage

    var body: some View {
        HStack(spacing: 12) {
            SidebarCategoryIcon(page: page)

            Text(page.title)
        }
    }
}

private struct SidebarCategoryIcon: View {
    let page: BookmarkManagerView.SettingsPage
    @Environment(\.sidebarIconTileSize) private var tileSize
    @Environment(\.sidebarIconSymbolSize) private var symbolSize
    @Environment(\.sidebarIconCornerRadius) private var cornerRadius

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(page.iconGradient)

            Image(systemName: page.symbolName)
                .font(.system(size: symbolSize, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
        .frame(width: tileSize, height: tileSize)
    }
}

private struct SidebarIconTileSizeKey: EnvironmentKey {
    static let defaultValue: Double = 32
}

private struct SidebarIconSymbolSizeKey: EnvironmentKey {
    static let defaultValue: Double = 15
}

private struct SidebarIconCornerRadiusKey: EnvironmentKey {
    static let defaultValue: Double = 8
}

private extension EnvironmentValues {
    var sidebarIconTileSize: Double {
        get { self[SidebarIconTileSizeKey.self] }
        set { self[SidebarIconTileSizeKey.self] = newValue }
    }

    var sidebarIconSymbolSize: Double {
        get { self[SidebarIconSymbolSizeKey.self] }
        set { self[SidebarIconSymbolSizeKey.self] = newValue }
    }

    var sidebarIconCornerRadius: Double {
        get { self[SidebarIconCornerRadiusKey.self] }
        set { self[SidebarIconCornerRadiusKey.self] = newValue }
    }
}

private extension View {
    func settingsContentMargins() -> some View {
        self
            .contentMargins(.horizontal, 18, for: .scrollContent)
            .contentMargins(.top, 0, for: .scrollContent)
    }
}

private struct BookmarkRow: View {
    let bookmark: Bookmark
    let faviconLoader: FaviconLoader

    var body: some View {
        // Subscribe to loader.version so newly cached favicons trigger a redraw.
        _ = faviconLoader.version
        let icon = faviconLoader.image(for: bookmark.url)

        return HStack(spacing: 12) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                } else {
                    Image(nsImage: AppIcon.image(size: NSSize(width: 16, height: 16)))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.title)
                    .font(.body)
                Text(bookmark.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct BookmarkEditor: View {
    enum Mode {
        case add
        case edit(Bookmark)

        var title: String {
            switch self {
            case .add: return "添加书签"
            case .edit: return "编辑书签"
            }
        }
    }

    let mode: Mode
    @Bindable var model: BookmarksModel
    /// Optional prefilled values. Set by the global hotkey path (Wave 5)
    /// when we have URL+title from the frontmost browser. When non-nil,
    /// these win over clipboard-URL detection.
    var prefilledURL: String? = nil
    var prefilledTitle: String? = nil
    var prefilledIsHidden: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var url: String = ""
    @State private var isHidden = false
    @State private var isFetchingTitle = false
    /// Tracks whether the user has typed in the title field. We never
    /// overwrite a manual title with an auto-fetched one.
    @State private var titleEditedByUser = false
    @State private var titleFetchTask: Task<Void, Never>?
    @State private var lastFetchedURL: String?
    /// Per-sheet error so the alert presents on top of the sheet instead
    /// of being queued behind it on the parent view.
    @State private var commitErrorMessage: String?

    private static let metadataFetcher = PageMetadataFetcher()

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("标题", text: $title, prompt: Text("例如:GitHub"))
                        .onChange(of: title) { _, _ in
                            // Distinguish user typing from our own programmatic
                            // assignment after a fetch.
                            if !isProgrammaticTitleUpdate {
                                titleEditedByUser = true
                            }
                        }
                    if isFetchingTitle {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                TextField("网址", text: $url, prompt: Text("https://example.com"))
                    .textContentType(.URL)
                    .onChange(of: url) { _, newValue in
                        scheduleTitleFetch(for: newValue)
                    }
                Toggle("隐藏书签", isOn: $isHidden)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(mode.title)
        .frame(minWidth: 420)
        .padding(.top, 4)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saveLabel) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .alert(
            "无法保存书签",
            isPresented: Binding(
                get: { commitErrorMessage != nil },
                set: { if !$0 { commitErrorMessage = nil } }
            ),
            presenting: commitErrorMessage
        ) { _ in
            Button("好") { commitErrorMessage = nil }
        } message: { msg in
            Text(msg)
        }
        .onAppear {
            switch mode {
            case .edit(let bookmark):
                isProgrammaticTitleUpdate = true
                title = bookmark.title
                url = bookmark.url
                isHidden = bookmark.isHidden
                isProgrammaticTitleUpdate = false
                // Don't auto-fetch when editing: preserve whatever the user already saved.
                titleEditedByUser = true
            case .add:
                isHidden = prefilledIsHidden
                // Prefill from the global hotkey path takes precedence:
                // a real browser-tab snapshot beats whatever happens to
                // be on the clipboard. If a title is supplied, mark it as
                // user-edited so the auto-fetch doesn't overwrite it.
                if let prefilledURL, !prefilledURL.isEmpty {
                    url = prefilledURL
                    if let prefilledTitle, !prefilledTitle.isEmpty {
                        isProgrammaticTitleUpdate = true
                        title = prefilledTitle
                        isProgrammaticTitleUpdate = false
                        titleEditedByUser = true
                    }
                } else if let clipboard = clipboardURL() {
                    url = clipboard
                    // The url onChange handler will schedule the title fetch.
                }
            }
        }
        .onDisappear {
            titleFetchTask?.cancel()
        }
    }

    @State private var isProgrammaticTitleUpdate = false

    private var saveLabel: String {
        switch mode {
        case .add: return "添加"
        case .edit: return "保存"
        }
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commit() {
        let errorMessage: String?
        switch mode {
        case .add:
            errorMessage = model.add(title: title, url: url, isHidden: isHidden)
        case .edit(let bookmark):
            var updated = bookmark
            updated.title = title
            updated.url = url
            updated.isHidden = isHidden
            errorMessage = model.update(updated)
        }
        if let errorMessage {
            commitErrorMessage = errorMessage
        } else {
            dismiss()
        }
    }

    // MARK: - Auto-fill helpers

    private func clipboardURL() -> String? {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              parsed.host?.isEmpty == false
        else { return nil }
        return trimmed
    }

    private func scheduleTitleFetch(for raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cancel any in-flight fetch — input is changing.
        titleFetchTask?.cancel()
        isFetchingTitle = false

        guard
            !titleEditedByUser,
            !trimmed.isEmpty,
            trimmed != lastFetchedURL,
            let parsed = URL(string: trimmed),
            let scheme = parsed.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            parsed.host?.isEmpty == false
        else { return }

        let urlSnapshot = trimmed
        isFetchingTitle = true

        titleFetchTask = Task { @MainActor in
            // Debounce: typing fast enough cancels the sleep.
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }

            guard let parsed = URL(string: urlSnapshot) else {
                isFetchingTitle = false
                return
            }
            let fetched = await Self.metadataFetcher.title(for: parsed)
            if Task.isCancelled { return }

            // Re-check preconditions: user may have started typing the title,
            // or changed the URL while we were fetching.
            if !titleEditedByUser, url.trimmingCharacters(in: .whitespacesAndNewlines) == urlSnapshot,
               let fetched, !fetched.isEmpty {
                isProgrammaticTitleUpdate = true
                title = fetched
                isProgrammaticTitleUpdate = false
            }
            lastFetchedURL = urlSnapshot
            isFetchingTitle = false
        }
    }
}
