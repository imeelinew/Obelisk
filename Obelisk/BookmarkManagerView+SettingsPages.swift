import AppKit
import ObeliskCore
import SwiftUI

// Settings pages: appearance, menu bar, shortcuts, privacy, and the window toolbar
extension BookmarkManagerView {
    var appearancePage: some View {
        Form {
            Section("书签显示") {
                LabeledContent("显示方式") {
                    Picker("显示方式", selection: bookmarkDisplayModeBinding) {
                        ForEach([BookmarkDisplayMode.dateGrid, .list]) { mode in
                            Label(mode.title, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            Section("侧边栏") {
                LabeledContent("主题") {
                    Picker("主题", selection: sidebarIconThemeBinding) {
                        ForEach(SidebarIconTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                LabeledContent("图标风格") {
                    Picker("图标风格", selection: sidebarIconStyleBinding) {
                        ForEach(SidebarIconStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            Section("窗口") {
                Toggle("启用窗口透明效果", isOn: $windowTransparencyEnabled)
                if windowTransparencyEnabled {
                    Toggle("自定义透明度", isOn: customTransparencyBinding)
                    if customTransparencyEnabled {
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

            Section("域名显示") {
                Toggle("显示完整网站域名", isOn: showsFullURLBinding)
            }

            Section("菜单栏") {
                LabeledContent("图标样式") {
                    Picker("图标样式", selection: menuBarIconStyleBinding) {
                        ForEach(MenuBarIconStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                menuLimitStepper("最近添加数量", desc: "「最近添加」最多显示的书签数量", value: $menuRecentGroupLimit)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("外观")
    }

    var menuBarPage: some View {
        Form {
            Section("展开方式") {
                Toggle("最近添加", isOn: menuBarExpansionBinding(for: .recent))

                ForEach(model.collections) { collection in
                    Toggle(
                        collection.name,
                        isOn: menuBarExpansionBinding(for: .collection(collection.id))
                    )
                }
                .onMove(perform: reorderMenuBarCollections)

                Toggle("未分组", isOn: menuBarExpansionBinding(for: .ungrouped))

                Text("勾选后直接显示书签，未勾选时收起为子菜单，拖动分组会同步侧边栏与菜单栏顺序")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("菜单栏")
    }

    func menuBarExpansionBinding(for id: BookmarkMenuSectionID) -> Binding<Bool> {
        Binding(
            get: {
                BookmarkMenuExpansionPreferences.expandedIDs(collections: model.collections).contains(id)
            },
            set: { isExpanded in
                BookmarkMenuExpansionPreferences.setExpanded(
                    isExpanded,
                    id: id,
                    collections: model.collections
                )
                model.notifyMenuPresentationChanged()
            }
        )
    }

    func reorderMenuBarCollections(from source: IndexSet, to destination: Int) {
        var collections = model.collections
        collections.move(fromOffsets: source, toOffset: destination)
        if let error = model.reorderCollections(collections.map(\.id)) {
            showToast(error, kind: .error)
        }
    }

    var shortcutsPage: some View {
        Form {
            Section("快捷键") {
                ShortcutRecorderRow(title: "添加书签", name: .addBookmark)
                ShortcutRecorderRow(title: "添加隐藏书签", name: .addHiddenBookmark)
                ShortcutRecorderRow(title: "显示或隐藏隐藏书签", name: .toggleHiddenBookmarksSidebar)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("快捷键")
    }

    func menuLimitStepper(
        _ title: LocalizedStringKey,
        desc: LocalizedStringKey? = nil,
        value: Binding<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                HStack(spacing: 10) {
                    Text("\(value.wrappedValue)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 24, alignment: .trailing)
                    Stepper(title, value: value, in: 0...20).labelsHidden()
                }
            }
            if let desc {
                Text(desc).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    var privacyPage: some View {
        Form {
            Section("隐藏书签") {
                Toggle("在侧边栏显示隐藏书签", isOn: $showHiddenBookmarksPage)
                Toggle("使用无痕窗口打开隐藏书签", isOn: $openHiddenBookmarksIncognito)

                VStack(alignment: .leading, spacing: 8) {
                    Text("排除关键词")
                    HStack(spacing: 8) {
                        TextField("", text: $newHiddenBookmarkExcludedURLKeyword)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addHiddenBookmarkExcludedURLKeyword)
                        Button("添加", action: addHiddenBookmarkExcludedURLKeyword)
                            .disabled(newHiddenBookmarkExcludedURLKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    ForEach(hiddenBookmarkExcludedURLKeywords, id: \.self) { keyword in
                        HStack(spacing: 8) {
                            Text(keyword).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            Button(role: .destructive) {
                                removeHiddenBookmarkExcludedURLKeyword(keyword)
                            } label: {
                                Label("删除", systemImage: "minus.circle")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                        }
                    }

                    Text("包含关键字的 URL 只能添加到「隐藏书签」")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("隐私")
    }

    @ToolbarContentBuilder
    var settingsToolbar: some ToolbarContent {
        switch settingsPage {
        case .bookmarks:
            ToolbarItem { addBookmarkButton(isHidden: false, collectionID: nil, help: "添加书签") }
        case .collections:
            ToolbarItem {
                addBookmarkButton(
                    isHidden: false,
                    collectionID: currentCollectionScopeCollectionID,
                    help: "添加书签"
                )
            }
        case .hiddenBookmarks:
            ToolbarItem { addBookmarkButton(isHidden: true, collectionID: nil, help: "添加隐藏书签") }
        default:
            ToolbarItemGroup {}
        }
    }

    var currentCollectionScopeCollectionID: UUID? {
        guard case .collection(let id) = collectionScope else { return nil }
        return id
    }

    private func addBookmarkButton(
        isHidden: Bool,
        collectionID: UUID?,
        help: LocalizedStringKey
    ) -> some View {
        Button {
            presentation = .add(
                seq: 0,
                prefilledURL: nil,
                prefilledTitle: nil,
                prefilledIsHidden: isHidden,
                collectionID: collectionID
            )
        } label: {
            Label("添加", systemImage: "plus")
        }
        .help(help)
    }
}
