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
    let refreshAllFaviconAlertBinding: Binding<Bool>
    @Binding var refreshAllFaviconConfirmation: Bool
    let refreshAllFavicons: () -> Void
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
    let restoreAllOriginalTitlesAlertBinding: Binding<Bool>
    @Binding var restoreAllOriginalTitlesConfirmation: Bool
    let restoreAllOriginalTitles: () -> Void
    let refetchAllOriginalTitlesAlertBinding: Binding<Bool>
    @Binding var refetchAllOriginalTitlesConfirmation: Bool
    let fetchAllOriginalTitles: () -> Void
    let enableDeveloperFeaturesAlertBinding: Binding<Bool>
    @Binding var enableDeveloperFeaturesConfirmation: Bool
    let enableDeveloperFeatures: () -> Void
    let resetDeveloperOptionsAlertBinding: Binding<Bool>
    @Binding var resetDeveloperOptionsConfirmation: Bool
    let resetDeveloperOptionsToDefaults: () -> Void

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
                Text("删除「\(collection.name)」后，其中的书签将移到未分组。")
            }
            .alert(
                "恢复全部原标题?",
                isPresented: restoreAllOriginalTitlesAlertBinding
            ) {
                Button("取消", role: .cancel) {
                    restoreAllOriginalTitlesConfirmation = false
                }
                Button("恢复", role: .destructive) {
                    restoreAllOriginalTitlesConfirmation = false
                    restoreAllOriginalTitles()
                }
            } message: {
                Text("将使用本地保存的原标题覆盖当前标题，此操作不可撤销。")
            }
            .alert(
                "重新获取并覆盖全部标题?",
                isPresented: refetchAllOriginalTitlesAlertBinding
            ) {
                Button("取消", role: .cancel) {
                    refetchAllOriginalTitlesConfirmation = false
                }
                Button("覆盖", role: .destructive) {
                    refetchAllOriginalTitlesConfirmation = false
                    fetchAllOriginalTitles()
                }
            } message: {
                Text("将从各书签网址抓取网页标题并应用到全部书签，已 Intelligence 优化的标题也会被覆盖。")
            }
            .alert(
                "刷新全部 favicon?",
                isPresented: refreshAllFaviconAlertBinding
            ) {
                Button("取消", role: .cancel) {
                    refreshAllFaviconConfirmation = false
                }
                Button("刷新", role: .destructive) {
                    refreshAllFavicons()
                    refreshAllFaviconConfirmation = false
                }
            } message: {
                Text("将清除所有已缓存的网站图标并重新下载，此操作不可撤销。")
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
                Text("你确定吗？开启自定义透明度可能会大幅降低可读性。")
            }
            .alert(
                "开启开发者选项?",
                isPresented: enableDeveloperFeaturesAlertBinding
            ) {
                Button("取消", role: .cancel) {
                    enableDeveloperFeaturesConfirmation = false
                }
                Button("开启", role: .destructive) {
                    enableDeveloperFeatures()
                }
            } message: {
                Text("修改「开发者选项」中的任意一项配置都可能导致 Obelisk 出现非预期的变化、甚至崩溃和数据丢失，如果你不清楚设置和选项的含义，请不要修改任何内容，并保持「开发者选项」关闭。")
            }
            .alert(
                "恢复默认设置?",
                isPresented: resetDeveloperOptionsAlertBinding
            ) {
                Button("取消", role: .cancel) {
                    resetDeveloperOptionsConfirmation = false
                }
                Button("恢复", role: .destructive) {
                    resetDeveloperOptionsToDefaults()
                }
            } message: {
                Text("将把开发者选项恢复为默认状态，不会修改书签数据。")
            }
    }
}

