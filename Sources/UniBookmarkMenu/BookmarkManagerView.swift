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
    @State private var searchText = ""
    /// Tracks the last consumed addRequest.seq. Bumped after we present the
    /// sheet so subsequent identical-prefill requests still trigger.
    @State private var lastConsumedAddSeq: Int = 0

    enum Presentation: Identifiable {
        // `seq` is part of identity so re-issuing an add request with new
        // prefill while a stale sheet is somehow alive forces a fresh sheet.
        case add(seq: Int, prefilledURL: String?, prefilledTitle: String?)
        case edit(Bookmark)

        var id: String {
            switch self {
            case .add(let seq, _, _): return "add-\(seq)"
            case .edit(let bookmark): return "edit-\(bookmark.id.uuidString)"
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

    @ViewBuilder
    private func row(for bookmark: Bookmark) -> some View {
        BookmarkRow(bookmark: bookmark, faviconLoader: faviconLoader)
            .tag(bookmark.id)
            .contextMenu {
                // "打开" here is a preview/check action — the manage window
                // is for organization, not navigation. We deliberately do
                // NOT route this through model.openBookmark so it doesn't
                // pollute frecency. Only menubar clicks count as "usage".
                Button("在浏览器中打开") {
                    if let url = URL(string: bookmark.url) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("编辑…") { presentation = .edit(bookmark) }
                Button(bookmark.pinned ? "取消置顶" : "置顶") {
                    model.togglePin(bookmark)
                }
                Divider()
                Button("删除", role: .destructive) {
                    let ids = selection.contains(bookmark.id) ? selection : [bookmark.id]
                    requestDelete(ids: ids)
                }
            }
    }

    private var filteredFrequent: [Bookmark] {
        filtered(model.frequent)
    }

    private var filteredPinned: [Bookmark] {
        filtered(model.pinned)
    }

    private var filteredRecent: [Bookmark] {
        filtered(model.recent)
    }

    private var filteredOthers: [Bookmark] {
        filtered(model.others)
    }

    private var filteredBookmarks: [Bookmark] {
        filtered(model.bookmarks)
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
        let seq = addRequest.seq
        guard seq != lastConsumedAddSeq, seq > 0 else { return }
        lastConsumedAddSeq = seq
        presentation = .add(
            seq: seq,
            prefilledURL: addRequest.url,
            prefilledTitle: addRequest.title
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

    var body: some View {
        Group {
            if model.bookmarks.isEmpty {
                ContentUnavailableView {
                    Label("还没有书签", systemImage: "bookmark")
                } description: {
                    Text("点击工具栏的 + 添加你的第一个书签。")
                }
            } else if filteredBookmarks.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(selection: $selection) {
                    if !filteredPinned.isEmpty {
                        Section("置顶") {
                            ForEach(filteredPinned) { bookmark in
                                row(for: bookmark)
                            }
                        }
                    }
                    if !filteredFrequent.isEmpty {
                        Section("常用") {
                            ForEach(filteredFrequent) { bookmark in
                                row(for: bookmark)
                            }
                        }
                    }
                    if !filteredRecent.isEmpty {
                        Section("最近添加") {
                            ForEach(filteredRecent) { bookmark in
                                row(for: bookmark)
                            }
                        }
                    }
                    if !filteredOthers.isEmpty {
                        // Only show the "全部" header when one of the
                        // grouped sections is also visible — otherwise
                        // it would be the only section and the header
                        // would just be noise.
                        let needsHeader = !filteredPinned.isEmpty || !filteredFrequent.isEmpty || !filteredRecent.isEmpty
                        Section(needsHeader ? "全部" : "") {
                            ForEach(filteredOthers) { bookmark in
                                row(for: bookmark)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .navigationTitle("书签")
        .navigationSubtitle(model.bookmarks.isEmpty ? "" : "\(model.bookmarks.count) 个书签")
        .searchable(text: $searchText, prompt: "搜索标题或网址")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    presentation = .add(seq: 0, prefilledURL: nil, prefilledTitle: nil)
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

                Spacer()

                Button {
                    if let selectedBookmark {
                        model.togglePin(selectedBookmark)
                    }
                } label: {
                    Label(
                        selectedBookmark?.pinned == true ? "取消置顶" : "置顶",
                        systemImage: selectedBookmark?.pinned == true ? "pin.slash" : "pin"
                    )
                }
                .disabled(!canUseSingleSelectionActions)
                .help(selectedBookmark?.pinned == true ? "取消置顶" : "置顶选中的书签")

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
        .sheet(item: $presentation) { kind in
            switch kind {
            case .add(_, let prefilledURL, let prefilledTitle):
                BookmarkEditor(
                    mode: .add,
                    model: model,
                    prefilledURL: prefilledURL,
                    prefilledTitle: prefilledTitle
                )
            case .edit(let bookmark):
                BookmarkEditor(mode: .edit(bookmark), model: model)
            }
        }
        .onAppear {
            // First-launch path: the hotkey may have already bumped seq before
            // the view mounted. .onChange only fires on subsequent updates,
            // so we'd miss the initial request without this check. Subsequent
            // presses (window already open) hit .onChange below.
            consumePendingAddRequestIfNeeded()
        }
        .onChange(of: addRequest.seq) { _, _ in
            consumePendingAddRequestIfNeeded()
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
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(.tint)
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
            if bookmark.pinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }
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
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var url: String = ""
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
                isProgrammaticTitleUpdate = false
                // Don't auto-fetch when editing: preserve whatever the user already saved.
                titleEditedByUser = true
            case .add:
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
            errorMessage = model.add(title: title, url: url)
        case .edit(let bookmark):
            var updated = bookmark
            updated.title = title
            updated.url = url
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
