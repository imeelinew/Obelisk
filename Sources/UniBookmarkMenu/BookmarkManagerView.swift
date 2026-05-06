import AppKit
import SwiftUI
import UniBookmarkCore

struct BookmarkManagerView: View {
    @Bindable var model: BookmarksModel
    let faviconLoader: FaviconLoader
    let addRequest: AddBookmarkRequest
    @State private var selection: Set<Bookmark.ID> = []
    @State private var presentation: Presentation?
    @State private var deleteConfirmation: DeleteConfirmation?
    @State private var titleOptimizationMessage: String?
    @State private var searchText = ""
    @State private var settingsPage: SettingsPage = .bookmarks
    @State private var llmConfig = LLMConfig()
    @State private var llmConfigMessage: String?
    @AppStorage("debugSidebarIconTileSize") private var sidebarIconTileSize: Double = 32
    @AppStorage("debugSidebarIconSymbolSize") private var sidebarIconSymbolSize: Double = 15
    @AppStorage("debugSidebarIconCornerRadius") private var sidebarIconCornerRadius: Double = 8
    @AppStorage("showHiddenBookmarksPage") private var showHiddenBookmarksPage = false

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
        case ai
        case developer

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bookmarks: return "书签"
            case .hiddenBookmarks: return "隐藏书签"
            case .ai: return "AI配置"
            case .developer: return "开发者选项"
            }
        }

        var symbolName: String {
            switch self {
            case .bookmarks: return "bookmark.fill"
            case .hiddenBookmarks: return "eye.slash.fill"
            case .ai: return "sparkles"
            case .developer: return "wrench.fill"
            }
        }

        var iconGradient: LinearGradient {
            switch self {
            case .bookmarks:
                return LinearGradient(
                    colors: [Color(red: 1.0, green: 0.45, blue: 0.30), Color(red: 1.0, green: 0.28, blue: 0.22)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .ai:
                return LinearGradient(
                    colors: [Color(red: 0.54, green: 0.44, blue: 1.0), Color(red: 0.34, green: 0.25, blue: 0.86)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .hiddenBookmarks:
                return LinearGradient(
                    colors: [Color(red: 0.48, green: 0.54, blue: 0.64), Color(red: 0.24, green: 0.29, blue: 0.38)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .developer:
                return LinearGradient(
                    colors: [Color(red: 1.0, green: 0.82, blue: 0.28), Color(red: 0.95, green: 0.62, blue: 0.10)],
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

    private var unoptimizedTitleCount: Int {
        model.bookmarks.filter { !$0.titleOptimized && !$0.isHidden }.count
    }

    private func optimizeTitles() {
        Task {
            titleOptimizationMessage = await model.optimizeAllTitles()
        }
    }

    private var llmConfigStore: LLMConfigStore {
        LLMConfigStore(rootDirectory: BookmarkStore.defaultRootDirectory())
    }

    private func loadLLMConfig() {
        llmConfig = llmConfigStore.load()
    }

    private func saveLLMConfig() {
        do {
            try llmConfigStore.save(llmConfig)
            llmConfigMessage = "模型配置已保存"
        } catch {
            llmConfigMessage = error.localizedDescription
        }
    }

    private func handleHiddenBookmarksVisibilityChange(isShowing: Bool) {
        guard !isShowing else { return }
        guard settingsPage == SettingsPage.hiddenBookmarks else { return }
        settingsPage = .bookmarks
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
        .alert(
            "出错了",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("好") { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
        .alert(
            "删除书签?",
            isPresented: Binding(
                get: { deleteConfirmation != nil },
                set: { if !$0 { deleteConfirmation = nil } }
            ),
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
            "标题优化",
            isPresented: Binding(
                get: { titleOptimizationMessage != nil },
                set: { if !$0 { titleOptimizationMessage = nil } }
            ),
            presenting: titleOptimizationMessage
        ) { _ in
            Button("好") { titleOptimizationMessage = nil }
        } message: { message in
            Text(message)
        }
        .alert(
            "模型配置",
            isPresented: Binding(
                get: { llmConfigMessage != nil },
                set: { if !$0 { llmConfigMessage = nil } }
            ),
            presenting: llmConfigMessage
        ) { _ in
            Button("好") { llmConfigMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private var settingsSidebar: some View {
        List(selection: $settingsPage) {
            ForEach(visibleSettingsPages) { page in
                NavigationLink(value: page) {
                    SidebarPageLabel(page: page)
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
            case .ai:
                aiOptimizationPage
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
                bookmarkList
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
                List(selection: $selection) {
                    ForEach(hiddenBookmarkSections) { section in
                        Section(section.title ?? "") {
                            ForEach(section.bookmarks) { bookmark in
                                BookmarkRow(bookmark: bookmark, faviconLoader: faviconLoader)
                                    .tag(bookmark.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("隐藏书签")
    }

    private var bookmarkList: some View {
        List(selection: $selection) {
            ForEach(bookmarkSections) { section in
                Section(section.title ?? "") {
                    ForEach(section.bookmarks) { bookmark in
                        BookmarkRow(bookmark: bookmark, faviconLoader: faviconLoader)
                            .tag(bookmark.id)
                    }
                }
            }
        }
        .listStyle(.inset)
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
                    Label("保存配置", systemImage: "square.and.arrow.down")
                }
            }
        }
        .formStyle(.grouped)
        .settingsContentMargins()
        .navigationTitle("AI配置")
    }

    private var developerOptionsPage: some View {
        Form {
            Section("隐藏书签") {
                Toggle("显示隐藏书签页", isOn: $showHiddenBookmarksPage)
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }

            Section("侧栏图标调试") {
                Slider(value: $sidebarIconTileSize, in: 22...40, step: 1) {
                    Text("背景尺寸")
                } minimumValueLabel: {
                    Text("22")
                } maximumValueLabel: {
                    Text("40")
                }

                Slider(value: $sidebarIconSymbolSize, in: 10...22, step: 1) {
                    Text("符号尺寸")
                } minimumValueLabel: {
                    Text("10")
                } maximumValueLabel: {
                    Text("22")
                }

                Slider(value: $sidebarIconCornerRadius, in: 4...12, step: 1) {
                    Text("圆角")
                } minimumValueLabel: {
                    Text("4")
                } maximumValueLabel: {
                    Text("12")
                }
            }
        }
        .formStyle(.grouped)
        .settingsContentMargins()
        .navigationTitle("开发者选项")
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
            }

            ToolbarSpacer(.fixed)

            ToolbarItem {
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
                    optimizeTitles()
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
            .contentMargins(.horizontal, 32, for: .scrollContent)
            .padding(.horizontal, 18)
            .padding(.top, -9)
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
