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

                menuLimitStepper("最近添加数量", value: $menuRecentGroupLimit)
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
                        if item.id != items.last?.id { Divider().padding(.leading, 14) }
                    }
            }
            .reorderable()
        }
        .reorderContainer(for: BookmarkMenuOrderItem.self, itemID: \.id) { difference in
            moveMenuBarSections(using: difference)
        }
        .frame(height: CGFloat(items.count) * menuBarOrderRowHeight)
        .background { menuBarOrderBackground(cornerRadius: 10) }
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
                        if index < items.count - 1 { Divider().padding(.leading, 14) }
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
                    .background { menuBarOrderBackground(cornerRadius: 9) }
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .offset(y: CGFloat(startIndex) * menuBarOrderRowHeight + menuBarDragOffsetY)
                    .zIndex(2)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: CGFloat(items.count) * menuBarOrderRowHeight)
        .background { menuBarOrderBackground(cornerRadius: 10) }
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
            Toggle("展开", isOn: menuBarExpansionBinding(for: item.id))
                .toggleStyle(.checkbox)
                .fixedSize()
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: menuBarOrderRowHeight)
        .contentShape(Rectangle())
        .opacity(isPlaceholder ? 0 : 1)
        .background {
            if isDropTarget { Color.accentColor.opacity(0.08) }
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
                menuBarDragOffsetY = value.translation.height
                menuBarDragTargetIndex = stableMenuBarOrderTargetIndex(
                    startIndex: menuBarDragStartIndex ?? index,
                    translationY: value.translation.height,
                    itemCount: itemCount
                )
            }
            .onEnded { value in
                defer { resetMenuBarOrderDrag() }
                guard draggingMenuBarSectionID == item.id else { return }
                let target = menuBarDragTargetIndex ?? menuBarOrderTargetIndex(
                    startIndex: menuBarDragStartIndex ?? index,
                    translationY: value.translation.height,
                    itemCount: itemCount
                )
                moveMenuBarSection(draggedID: item.id, toIndex: target)
            }
    }

    func menuBarExpansionBinding(for id: BookmarkMenuSectionID) -> Binding<Bool> {
        Binding(
            get: {
                BookmarkMenuExpansionPreferences.expandedIDs(
                    collections: model.collections,
                    rawValue: menuBarExpandedSectionsRaw == "\u{0}"
                        ? nil
                        : menuBarExpandedSectionsRaw
                ).contains(id)
            },
            set: { isExpanded in
                var expanded = BookmarkMenuExpansionPreferences.expandedIDs(
                    collections: model.collections,
                    rawValue: menuBarExpandedSectionsRaw == "\u{0}"
                        ? nil
                        : menuBarExpandedSectionsRaw
                )
                if isExpanded {
                    expanded.insert(id)
                } else {
                    expanded.remove(id)
                }
                menuBarExpandedSectionsRaw = BookmarkMenuExpansionPreferences.encoded(expanded)
                model.notifyMenuPresentationChanged()
            }
        )
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
        value: Binding<Int>
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Text("\(value.wrappedValue)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
                Stepper(title, value: value, in: 0...20).labelsHidden()
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
