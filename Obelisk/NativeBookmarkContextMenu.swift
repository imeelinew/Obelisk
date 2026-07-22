import AppKit

@MainActor
struct NativeBookmarkContextMenuConfiguration {
    var onOpen: (() -> Void)? = nil
    var onCopyURL: (() -> Void)? = nil
    var onRefreshFavicon: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onRevertTitleOptimization: (() -> Void)? = nil
    var pinStateActionTitle: String? = nil
    var pinStateSystemSymbolName: String? = nil
    var onSetPinned: (() -> Void)? = nil
    var collectionAssignOptions: [BookmarkCollectionAssignOption] = []
    var onAssignCollection: ((UUID?) -> Void)? = nil
    var hiddenStateActionTitle: String? = nil
    var hiddenStateSystemSymbolName: String? = nil
    var onSetHidden: (() -> Void)? = nil
    var archiveStateActionTitle: String? = nil
    var archiveStateSystemSymbolName: String? = nil
    var onSetArchived: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
}

@MainActor
struct NativeCollectionContextMenuConfiguration {
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
}

@MainActor
private enum NativeContextMenuAppearance {
    static let destructiveMenuItemIdentifier = NSUserInterfaceItemIdentifier(
        "ObeliskDestructiveMenuItem"
    )

    static func menuSymbolImage(_ symbolName: String, color: NSColor? = nil) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return nil
        }

        var configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if let color {
            configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        }
        return image.withSymbolConfiguration(configuration)
    }

    static func applyDestructiveStyle(
        to item: NSMenuItem,
        systemSymbolName: String = "trash",
        highlighted: Bool
    ) {
        let color: NSColor = highlighted ? .white : .systemRed
        item.attributedTitle = NSAttributedString(
            string: item.title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: color
            ]
        )
        item.image = menuSymbolImage(systemSymbolName, color: color)
    }
}

@MainActor
final class NativeBookmarkContextMenuController: NSObject, NSMenuDelegate {
    private var configuration: NativeBookmarkContextMenuConfiguration?

    func makeMenu(configuration: NativeBookmarkContextMenuConfiguration) -> NSMenu? {
        self.configuration = configuration

        let menu = NSMenu()
        menu.delegate = self

        appendItem(
            title: "打开".obeliskLocalized,
            systemSymbolName: "arrow.up.forward.square",
            action: #selector(open(_:)),
            when: configuration.onOpen != nil,
            to: menu
        )
        appendItem(
            title: "复制 URL".obeliskLocalized,
            systemSymbolName: "doc.on.doc",
            action: #selector(copyURL(_:)),
            when: configuration.onCopyURL != nil,
            to: menu
        )
        appendItem(
            title: "刷新 favicon".obeliskLocalized,
            systemSymbolName: "arrow.clockwise",
            action: #selector(refreshFavicon(_:)),
            when: configuration.onRefreshFavicon != nil,
            to: menu
        )
        appendItem(
            title: "编辑".obeliskLocalized,
            systemSymbolName: "pencil",
            action: #selector(edit(_:)),
            when: configuration.onEdit != nil,
            to: menu
        )
        appendItem(
            title: "恢复原标题".obeliskLocalized,
            systemSymbolName: "arrow.uturn.backward",
            action: #selector(revertTitleOptimization(_:)),
            when: configuration.onRevertTitleOptimization != nil,
            to: menu
        )

        if let title = configuration.pinStateActionTitle,
           let systemSymbolName = configuration.pinStateSystemSymbolName,
           configuration.onSetPinned != nil {
            appendSeparator(to: menu)
            menu.addItem(menuItem(
                title: title,
                systemSymbolName: systemSymbolName,
                action: #selector(setPinned(_:))
            ))
        }

        if !configuration.collectionAssignOptions.isEmpty,
           configuration.onAssignCollection != nil {
            appendSeparator(to: menu)
            let title = "移到分组".obeliskLocalized
            let submenu = NSMenu(title: title)
            for option in configuration.collectionAssignOptions {
                let item = NSMenuItem(
                    title: option.title,
                    action: #selector(assignCollection(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = CollectionAssignment(collectionId: option.collectionId)
                submenu.addItem(item)
            }

            let moveItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            moveItem.image = NativeContextMenuAppearance.menuSymbolImage("folder")
            moveItem.submenu = submenu
            menu.addItem(moveItem)
        }

        if let title = configuration.hiddenStateActionTitle,
           let systemSymbolName = configuration.hiddenStateSystemSymbolName,
           configuration.onSetHidden != nil {
            appendSeparator(to: menu)
            menu.addItem(menuItem(
                title: title,
                systemSymbolName: systemSymbolName,
                action: #selector(setHidden(_:))
            ))
        }

        if let title = configuration.archiveStateActionTitle,
           let systemSymbolName = configuration.archiveStateSystemSymbolName,
           configuration.onSetArchived != nil {
            appendSeparator(to: menu)
            menu.addItem(menuItem(
                title: title,
                systemSymbolName: systemSymbolName,
                action: #selector(setArchived(_:))
            ))
        }

        if configuration.onDelete != nil {
            appendSeparator(to: menu)
            menu.addItem(destructiveMenuItem(
                title: "删除".obeliskLocalized,
                systemSymbolName: "trash",
                action: #selector(delete(_:))
            ))
        }

        return menu.items.isEmpty ? nil : menu
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for menuItem in menu.items
        where menuItem.identifier == NativeContextMenuAppearance.destructiveMenuItemIdentifier {
            NativeContextMenuAppearance.applyDestructiveStyle(
                to: menuItem,
                highlighted: menuItem === item
            )
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        configuration = nil
    }

    private func appendItem(
        title: String,
        systemSymbolName: String,
        action: Selector,
        when condition: Bool,
        to menu: NSMenu
    ) {
        guard condition else { return }
        menu.addItem(menuItem(title: title, systemSymbolName: systemSymbolName, action: action))
    }

    private func appendSeparator(to menu: NSMenu) {
        guard !menu.items.isEmpty, menu.items.last?.isSeparatorItem != true else { return }
        menu.addItem(.separator())
    }

    private func menuItem(title: String, systemSymbolName: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NativeContextMenuAppearance.menuSymbolImage(systemSymbolName)
        return item
    }

    private func destructiveMenuItem(
        title: String,
        systemSymbolName: String,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.identifier = NativeContextMenuAppearance.destructiveMenuItemIdentifier
        NativeContextMenuAppearance.applyDestructiveStyle(
            to: item,
            systemSymbolName: systemSymbolName,
            highlighted: false
        )
        return item
    }

    @objc private func open(_ sender: NSMenuItem) {
        configuration?.onOpen?()
    }

    @objc private func copyURL(_ sender: NSMenuItem) {
        configuration?.onCopyURL?()
    }

    @objc private func refreshFavicon(_ sender: NSMenuItem) {
        configuration?.onRefreshFavicon?()
    }

    @objc private func edit(_ sender: NSMenuItem) {
        configuration?.onEdit?()
    }

    @objc private func revertTitleOptimization(_ sender: NSMenuItem) {
        configuration?.onRevertTitleOptimization?()
    }

    @objc private func setPinned(_ sender: NSMenuItem) {
        configuration?.onSetPinned?()
    }

    @objc private func assignCollection(_ sender: NSMenuItem) {
        guard let assignment = sender.representedObject as? CollectionAssignment else { return }
        configuration?.onAssignCollection?(assignment.collectionId)
    }

    @objc private func setHidden(_ sender: NSMenuItem) {
        configuration?.onSetHidden?()
    }

    @objc private func setArchived(_ sender: NSMenuItem) {
        configuration?.onSetArchived?()
    }

    @objc private func delete(_ sender: NSMenuItem) {
        configuration?.onDelete?()
    }

    private final class CollectionAssignment: NSObject {
        let collectionId: UUID?

        init(collectionId: UUID?) {
            self.collectionId = collectionId
        }
    }
}

@MainActor
final class NativeCollectionContextMenuController: NSObject, NSMenuDelegate {
    private var configuration: NativeCollectionContextMenuConfiguration?

    func makeMenu(configuration: NativeCollectionContextMenuConfiguration) -> NSMenu? {
        self.configuration = configuration

        let menu = NSMenu()
        menu.delegate = self

        if configuration.onRename != nil {
            let item = NSMenuItem(
                title: "重命名分组".obeliskLocalized,
                action: #selector(rename(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.image = NativeContextMenuAppearance.menuSymbolImage("pencil")
            menu.addItem(item)
        }

        if configuration.onDelete != nil {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(
                title: "删除分组".obeliskLocalized,
                action: #selector(delete(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.identifier = NativeContextMenuAppearance.destructiveMenuItemIdentifier
            NativeContextMenuAppearance.applyDestructiveStyle(to: item, highlighted: false)
            menu.addItem(item)
        }

        return menu.items.isEmpty ? nil : menu
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for menuItem in menu.items
        where menuItem.identifier == NativeContextMenuAppearance.destructiveMenuItemIdentifier {
            NativeContextMenuAppearance.applyDestructiveStyle(
                to: menuItem,
                highlighted: menuItem === item
            )
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        configuration = nil
    }

    @objc private func rename(_ sender: NSMenuItem) {
        configuration?.onRename?()
    }

    @objc private func delete(_ sender: NSMenuItem) {
        configuration?.onDelete?()
    }
}
