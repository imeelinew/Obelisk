import AppKit
import ObeliskCore
import ObeliskSync
import SwiftUI

// Settings pages: appearance, menu bar, shortcuts, privacy, and the window toolbar
extension BookmarkManagerView {
    var appearancePage: some View {
        Form {
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
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("菜单栏排序")
                    .font(.headline)
                    .foregroundStyle(.primary)

                menuBarOrderCard
            }
            .padding(.top, 20)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .onDisappear(perform: resetMenuBarOrderDrag)
        .navigationTitle("菜单栏")
    }

    @ViewBuilder
    var menuBarOrderCard: some View {
        if #available(macOS 27.0, *) {
            nativeMenuBarOrderCard
        } else {
            legacyMenuBarOrderCard
        }
    }

    @available(macOS 27.0, *)
    var nativeMenuBarOrderCard: some View {
        let items = menuBarOrderItems

        return VStack(spacing: 0) {
            ForEach(items) { item in
                menuBarOrderRow(for: item, isPlaceholder: false, isDropTarget: false)
                    .overlay(alignment: .bottom) {
                        if item.id != items.last?.id {
                            Divider()
                                .padding(.leading, 14)
                        }
                    }
            }
            .reorderable()
        }
        .reorderContainer(for: BookmarkMenuOrderItem.self, itemID: \.id) { difference in
            moveMenuBarSections(using: difference)
        }
        .frame(height: CGFloat(items.count) * menuBarOrderRowHeight)
        .background {
            menuBarOrderBackground(cornerRadius: 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    var legacyMenuBarOrderCard: some View {
        let items = menuBarOrderItems

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    menuBarOrderRow(
                        for: item,
                        isPlaceholder: draggingMenuBarSectionID == item.id,
                        isDropTarget: menuBarDragTargetIndex == index && draggingMenuBarSectionID != item.id
                    )
                    .overlay(alignment: .bottom) {
                        if index < items.count - 1 {
                            Divider()
                                .padding(.leading, 14)
                        }
                    }
                    .offset(y: menuBarOrderRowOffset(for: index, itemID: item.id))
                    .animation(.easeInOut(duration: 0.12), value: menuBarDragTargetIndex)
                    .gesture(menuBarOrderDragGesture(for: item, at: index, itemCount: items.count))
                }
            }

            if let draggingMenuBarSectionID,
               let startIndex = menuBarDragStartIndex,
               let item = items.first(where: { $0.id == draggingMenuBarSectionID }) {
                menuBarOrderRow(for: item, isPlaceholder: false, isDropTarget: false)
                    .background {
                        menuBarOrderBackground(cornerRadius: 9)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .offset(y: CGFloat(startIndex) * menuBarOrderRowHeight + menuBarDragOffsetY)
                    .zIndex(2)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: CGFloat(items.count) * menuBarOrderRowHeight)
        .background {
            menuBarOrderBackground(cornerRadius: 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeInOut(duration: 0.12), value: items.map(\.id))
    }

    @ViewBuilder
    func menuBarOrderBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if windowTransparencyEnabled {
            shape.fill(menuBarOrderTransparentBackgroundColor)
        } else {
            shape.fill(menuBarOrderBackgroundColor)
        }
    }

    func menuBarOrderRow(
        for item: BookmarkMenuOrderItem,
        isPlaceholder: Bool,
        isDropTarget: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Text(item.title)
                .lineLimit(1)
                .foregroundStyle(.primary)

            Spacer(minLength: 16)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: menuBarOrderRowHeight)
        .contentShape(Rectangle())
        .opacity(isPlaceholder ? 0 : 1)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 0, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            }
        }
        .accessibilityLabel(item.title)
    }

    func menuBarOrderDragGesture(
        for item: BookmarkMenuOrderItem,
        at index: Int,
        itemCount: Int
    ) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if draggingMenuBarSectionID != item.id {
                    draggingMenuBarSectionID = item.id
                    menuBarDragStartIndex = index
                    menuBarDragTargetIndex = index
                    menuBarDragOffsetY = 0
                }

                guard draggingMenuBarSectionID == item.id else { return }
                let startIndex = menuBarDragStartIndex ?? index
                let targetIndex = stableMenuBarOrderTargetIndex(
                    startIndex: startIndex,
                    translationY: value.translation.height,
                    itemCount: itemCount
                )
                menuBarDragOffsetY = value.translation.height

                if menuBarDragTargetIndex != targetIndex {
                    menuBarDragTargetIndex = targetIndex
                }
            }
            .onEnded { value in
                defer { resetMenuBarOrderDrag() }
                guard draggingMenuBarSectionID == item.id else { return }
                let targetIndex = menuBarDragTargetIndex ?? menuBarOrderTargetIndex(
                    startIndex: menuBarDragStartIndex ?? index,
                    translationY: value.translation.height,
                    itemCount: itemCount
                )
                moveMenuBarSection(draggedID: item.id, toIndex: targetIndex)
            }
    }

    var shortcutsPage: some View {
        Form {
            Section("快捷键") {
                ShortcutRecorderRow(title: "添加书签", name: .addBookmark)
                ShortcutRecorderRow(title: "添加隐藏书签", name: .addHiddenBookmark)
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

                    Stepper(title, value: value, in: 0...20)
                        .labelsHidden()
                }
            }

            if let desc {
                Text(desc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

                        Button {
                            addHiddenBookmarkExcludedURLKeyword()
                        } label: {
                            Text("添加")
                        }
                        .disabled(newHiddenBookmarkExcludedURLKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    ForEach(hiddenBookmarkExcludedURLKeywords, id: \.self) { keyword in
                        HStack(spacing: 8) {
                            Text(keyword)
                                .lineLimit(1)
                                .truncationMode(.middle)

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
            ToolbarItemGroup {
                assignToCollectionMenu(help: "将选中的书签移到分组")
                addBookmarkButton(isHidden: false, help: "添加书签")
                editBookmarkButton
                togglePinnedButton
            }
            deleteToolbarItem(help: "删除选中的书签", isEnabled: canDeleteSelection) {
                requestDelete(ids: selection)
            }
            if aiFeaturesEnabled {
                optimizeToolbarItems(
                    includeAutoGrouping: true,
                    isDisabled: model.isOptimizingBookmarks
                        || (optimizableTitleCountInScope == 0 && autoGroupableBookmarkCountInScope == 0),
                    help: selection.isEmpty ? "优化全部可用书签的标题与分组" : "优化选中书签的标题与分组"
                )
            }
        case .collections:
            ToolbarItemGroup {
                assignToCollectionMenu(help: "将选中的书签移到其他分组")
                Button {
                    newCollectionName = ""
                    showNewCollectionDialog = true
                } label: {
                    Label("新建", systemImage: "plus")
                }
                .help("新建分组")

                Button {
                    requestEditCollectionPageSelection()
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                .disabled(!canEditCollectionPageSelection)
                .help("重命名选中的分组")

                togglePinnedButton
            }
            deleteToolbarItem(help: "删除选中的分组", isEnabled: canDeleteCollectionPageSelection) {
                requestDeleteCollectionPageSelection()
            }
            if aiFeaturesEnabled {
                optimizeToolbarItems(
                    includeAutoGrouping: true,
                    isDisabled: model.isOptimizingBookmarks
                        || (optimizableTitleCountInScope == 0 && autoGroupableBookmarkCountInScope == 0),
                    help: selection.isEmpty ? "优化全部可用书签的标题与分组" : "优化选中书签的标题与分组"
                )
            }
        case .hiddenBookmarks:
            ToolbarItemGroup {
                addBookmarkButton(isHidden: true, help: "添加隐藏书签")
                editBookmarkButton
            }
            deleteToolbarItem(help: "删除选中的隐藏书签", isEnabled: canDeleteSelection) {
                requestDelete(ids: selection)
            }
            if aiFeaturesEnabled, optimizeHiddenBookmarks {
                optimizeToolbarItems(
                    includeAutoGrouping: false,
                    isDisabled: selection.isEmpty
                        || model.isOptimizingBookmarks
                        || optimizableTitleCountInScope == 0,
                    help: "优化选中隐藏书签的标题"
                )
            }
        default:
            ToolbarItemGroup {}
        }
    }

    @ViewBuilder
    private func assignToCollectionMenu(help: LocalizedStringKey) -> some View {
        if !model.collections.isEmpty {
            Menu {
                ForEach(model.collections) { collection in
                    Button(collection.name) {
                        assignCollectionToSelection(collectionId: collection.id)
                    }
                }
                Button("未分组") {
                    assignCollectionToSelection(collectionId: nil)
                }
            } label: {
                Label("移到分组", systemImage: "folder")
            }
            .disabled(selection.isEmpty)
            .help(help)
        }
    }

    private func addBookmarkButton(isHidden: Bool, help: LocalizedStringKey) -> some View {
        Button {
            presentation = .add(seq: 0, prefilledURL: nil, prefilledTitle: nil, prefilledIsHidden: isHidden)
        } label: {
            Label("添加", systemImage: "plus")
        }
        .disabled(selection.count > 1)
        .help(help)
    }

    private var editBookmarkButton: some View {
        Button {
            if let bookmark = selectedBookmark {
                presentation = .edit(bookmark)
            }
        } label: {
            Label("编辑", systemImage: "pencil")
        }
        .disabled(!canUseSingleSelectionActions)
    }

    private var togglePinnedButton: some View {
        Button {
            togglePinnedSelection()
        } label: {
            Label(selectedPinnedTargetState ? "置顶" : "取消置顶", systemImage: selectedPinnedSystemImage)
        }
        .disabled(!canTogglePinnedSelection)
        .help(selectedPinnedTargetState ? "置顶选中的书签" : "取消置顶选中的书签")
    }

    private func deleteToolbarItem(
        help: LocalizedStringKey,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some ToolbarContent {
        ToolbarItem {
            Button(role: .destructive, action: action) {
                Label("删除", systemImage: "trash")
            }
            .disabled(!isEnabled)
            .help(help)
            .foregroundStyle(.red)
            .tint(.red)
        }
    }

    @ToolbarContentBuilder
    private func optimizeToolbarItems(
        includeAutoGrouping: Bool,
        isDisabled: Bool,
        help: LocalizedStringKey
    ) -> some ToolbarContent {
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button {
                optimizeBookmarks(includeAutoGrouping: includeAutoGrouping)
            } label: {
                IntelligenceSymbolLabel(
                    title: model.isOptimizingBookmarks ? "优化中" : "书签优化"
                )
            }
            .disabled(isDisabled)
            .help(help)
        }
    }
}
