import ObeliskCore
import SwiftUI

struct HiddenBookmarksLockingModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Binding var settingsPage: BookmarkManagerView.SettingsPage
    @Binding var hiddenBookmarksUnlocked: Bool
    @Binding var showHiddenBookmarksPage: Bool
    @Binding var selection: Set<Bookmark.ID>

    func body(content: Content) -> some View {
        content
            .onChange(of: settingsPage) { oldPage, newPage in
                if oldPage == .hiddenBookmarks, newPage != .hiddenBookmarks {
                    hiddenBookmarksUnlocked = false
                }
                selection.removeAll()
            }
            .onChange(of: showHiddenBookmarksPage) { _, isShowing in
                if !isShowing, settingsPage == .hiddenBookmarks {
                    lockHiddenBookmarks()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase != .active, settingsPage == .hiddenBookmarks {
                    lockHiddenBookmarks()
                }
            }
    }

    private func lockHiddenBookmarks() {
        settingsPage = .bookmarks
        hiddenBookmarksUnlocked = false
        selection.removeAll()
    }
}

// MARK: - Extra Alerts (split out to keep the main body type-checkable)

struct ExtraAlerts: ViewModifier {
    let customTransparencyAlertBinding: Binding<Bool>
    @Binding var showCustomTransparencyAlert: Bool
    @Binding var customTransparencyEnabled: Bool
    @Binding var showNewCollectionDialog: Bool
    @Binding var newCollectionName: String
    let createCollection: () -> Void
    let renameCollectionAlertBinding: Binding<Bool>
    @Binding var renameCollectionName: String
    @Binding var collectionToRename: BookmarkCollection?
    let renameCollection: () -> Void
    let deleteCollectionAlertBinding: Binding<Bool>
    @Binding var collectionToDelete: BookmarkCollection?
    let deleteCollection: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("新建分组", isPresented: $showNewCollectionDialog) {
                TextField("分组名称", text: $newCollectionName)
                Button("取消", role: .cancel) {}
                Button("创建", action: createCollection)
            }
            .alert("重命名分组", isPresented: renameCollectionAlertBinding) {
                TextField("分组名称", text: $renameCollectionName)
                Button("取消", role: .cancel) { collectionToRename = nil }
                Button("保存", action: renameCollection)
            }
            .alert(
                "删除分组?",
                isPresented: deleteCollectionAlertBinding,
                presenting: collectionToDelete
            ) { _ in
                Button("取消", role: .cancel) { collectionToDelete = nil }
                Button("删除", role: .destructive, action: deleteCollection)
            } message: { collection in
                Text("删除「\(collection.name)」后，其中的书签将移到未分组")
            }
            .alert(
                "开启自定义透明度?",
                isPresented: customTransparencyAlertBinding
            ) {
                Button("取消", role: .cancel) {
                    showCustomTransparencyAlert = false
                }
                Button("确定") {
                    customTransparencyEnabled = true
                    showCustomTransparencyAlert = false
                }
            } message: {
                Text("你确定吗？开启自定义透明度可能会大幅降低可读性")
            }
    }
}
