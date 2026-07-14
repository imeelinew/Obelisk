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
                Section("书签") {
                    TextField("标题", text: $title)
                    TextField("https://example.com", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if !library.collections.isEmpty {
                    Section("分组") {
                        Picker("存入", selection: $collectionID) {
                            Text("未分组").tag(UUID?.none)
                            ForEach(library.collections) { collection in
                                Text(collection.name).tag(Optional(collection.id))
                            }
                        }
                    }
                }
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
