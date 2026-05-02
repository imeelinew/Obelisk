import SwiftUI
import UniBookmarkCore

struct BookmarkManagerView: View {
    @Bindable var model: BookmarksModel
    let faviconLoader: FaviconLoader
    @State private var selection: Bookmark.ID?
    @State private var presentation: Presentation?

    enum Presentation: Identifiable {
        case add
        case edit(Bookmark)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let bookmark): return "edit-\(bookmark.id.uuidString)"
            }
        }
    }

    var body: some View {
        Group {
            if model.bookmarks.isEmpty {
                ContentUnavailableView {
                    Label("还没有书签", systemImage: "bookmark")
                } description: {
                    Text("点击工具栏的 + 添加你的第一个书签。")
                }
            } else {
                List(selection: $selection) {
                    ForEach(model.bookmarks) { bookmark in
                        BookmarkRow(bookmark: bookmark, faviconLoader: faviconLoader)
                            .tag(bookmark.id)
                            .contextMenu {
                                Button("编辑…") { presentation = .edit(bookmark) }
                                Button("打开") {
                                    if let url = URL(string: bookmark.url) {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                Divider()
                                Button("删除", role: .destructive) {
                                    model.delete(id: bookmark.id)
                                }
                            }
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .navigationTitle("书签")
        .navigationSubtitle(model.bookmarks.isEmpty ? "" : "\(model.bookmarks.count) 个书签")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    presentation = .add
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .help("添加书签")

                Button {
                    if let id = selection {
                        model.delete(id: id)
                        selection = nil
                    }
                } label: {
                    Label("删除", systemImage: "minus")
                }
                .disabled(selection == nil)
                .help("删除选中的书签")

                Spacer()

                Button {
                    if let id = selection,
                       let bookmark = model.bookmarks.first(where: { $0.id == id }) {
                        presentation = .edit(bookmark)
                    }
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .disabled(selection == nil)
            }
        }
        .sheet(item: $presentation) { kind in
            switch kind {
            case .add:
                BookmarkEditor(mode: .add, model: model)
            case .edit(let bookmark):
                BookmarkEditor(mode: .edit(bookmark), model: model)
            }
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
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var url: String = ""

    var body: some View {
        Form {
            Section {
                TextField("标题", text: $title, prompt: Text("例如:GitHub"))
                TextField("网址", text: $url, prompt: Text("https://example.com"))
                    .textContentType(.URL)
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
        .onAppear {
            if case .edit(let bookmark) = mode {
                title = bookmark.title
                url = bookmark.url
            }
        }
    }

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
        let ok: Bool
        switch mode {
        case .add:
            ok = model.add(title: title, url: url)
        case .edit(let bookmark):
            var updated = bookmark
            updated.title = title
            updated.url = url
            ok = model.update(updated)
        }
        if ok { dismiss() }
    }
}
