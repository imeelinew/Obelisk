import ObeliskCore
import SwiftUI

struct AddBookmarkView: View {
    let library: ObeliskLibraryModel

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var url = ""
    @State private var collectionID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                BookmarkFormFields(
                    title: $title,
                    url: $url,
                    collectionID: $collectionID,
                    collections: library.collections
                )
            }
            .navigationTitle("新建书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("存储") { save() }
                        .disabled(!canSave)
                }
            }
            .alert(
                "无法添加书签",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        if let error = library.addBookmark(
            title: title,
            url: url,
            collectionID: collectionID
        ) {
            errorMessage = error
        } else {
            dismiss()
        }
    }
}

struct EditBookmarkView: View {
    let bookmark: Bookmark
    let library: ObeliskLibraryModel

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var url: String
    @State private var collectionID: UUID?
    @State private var errorMessage: String?

    init(bookmark: Bookmark, library: ObeliskLibraryModel) {
        self.bookmark = bookmark
        self.library = library
        _title = State(initialValue: bookmark.title)
        _url = State(initialValue: bookmark.url)
        _collectionID = State(initialValue: library.collectionID(for: bookmark))
    }

    var body: some View {
        NavigationStack {
            Form {
                BookmarkFormFields(
                    title: $title,
                    url: $url,
                    collectionID: $collectionID,
                    collections: library.collections
                )
            }
            .navigationTitle("编辑书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("存储") { save() }
                        .disabled(!canSave)
                }
            }
            .alert(
                "无法编辑书签",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        if let error = library.updateBookmark(
            bookmark,
            title: title,
            url: url,
            collectionID: collectionID
        ) {
            errorMessage = error
        } else {
            dismiss()
        }
    }
}

private struct BookmarkFormFields: View {
    @Binding var title: String
    @Binding var url: String
    @Binding var collectionID: UUID?
    let collections: [BookmarkCollection]

    var body: some View {
        Section("书签") {
            TextField("标题", text: $title)
            TextField("https://example.com", text: $url)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }

        if !collections.isEmpty {
            Section("分组") {
                Picker("存入", selection: $collectionID) {
                    Text("未分组").tag(UUID?.none)
                    ForEach(collections) { collection in
                        Text(collection.name).tag(Optional(collection.id))
                    }
                }
            }
        }
    }
}

struct AddCollectionView: View {
    let library: ObeliskLibraryModel

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("分组名称", text: $name)
            }
            .navigationTitle("新建分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("存储") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert(
                "无法创建分组",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        if let error = library.createCollection(name: name) {
            errorMessage = error
        } else {
            dismiss()
        }
    }
}
