import AppKit
import ObeliskCore

@MainActor
struct NativeBookmarkContextMenuConfiguration {
    var isTrash = false
    var onOpen: (() -> Void)? = nil
    var onCopyURL: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onRevertTitleOptimization: (() -> Void)? = nil
    var onRetryTitleOptimization: (() -> Void)? = nil
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
    var selectedColor: BookmarkCollectionColor = .blue
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onColorChange: ((BookmarkCollectionColor) -> Void)? = nil
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

        if configuration.isTrash {
            menu.addItem(menuItem(title: "恢复".obeliskLocalized, systemSymbolName: "arrow.uturn.backward", action: #selector(setArchived(_:))))
            menu.addItem(menuItem(title: "复制 URL".obeliskLocalized, systemSymbolName: "doc.on.doc", action: #selector(copyURL(_:))))
            menu.addItem(.separator())
            menu.addItem(destructiveMenuItem(title: "trash.permanentDelete.menu".obeliskLocalized, systemSymbolName: "trash", action: #selector(delete(_:))))
            return menu
        }

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
            title: "编辑".obeliskLocalized,
            systemSymbolName: "pencil",
            action: #selector(edit(_:)),
            when: configuration.onEdit != nil,
            to: menu
        )
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

        appendItem(
            title: "恢复原标题".obeliskLocalized,
            systemSymbolName: "arrow.uturn.backward",
            action: #selector(revertTitleOptimization(_:)),
            when: configuration.onRevertTitleOptimization != nil,
            to: menu
        )
        appendItem(
            title: "重新优化".obeliskLocalized,
            systemSymbolName: "sparkles",
            action: #selector(retryTitleOptimization(_:)),
            when: configuration.onRetryTitleOptimization != nil,
            to: menu
        )

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
            menu.addItem(menuItem(
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

    @objc private func edit(_ sender: NSMenuItem) {
        configuration?.onEdit?()
    }

    @objc private func revertTitleOptimization(_ sender: NSMenuItem) {
        configuration?.onRevertTitleOptimization?()
    }

    @objc private func retryTitleOptimization(_ sender: NSMenuItem) {
        configuration?.onRetryTitleOptimization?()
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
final class NativeCollectionContextMenuController: NSObject {
    private var configuration: NativeCollectionContextMenuConfiguration?

    func makeMenu(configuration: NativeCollectionContextMenuConfiguration) -> NSMenu? {
        self.configuration = configuration

        let menu = NSMenu()

        if configuration.onRename != nil {
            let item = NSMenuItem(
                title: "重命名".obeliskLocalized,
                action: #selector(rename(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }

        if configuration.onDelete != nil {
            let item = NSMenuItem(
                title: "删除...".obeliskLocalized,
                action: #selector(delete(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }

        if configuration.onColorChange != nil {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            let item = NSMenuItem()
            item.view = CollectionColorPickerMenuView(
                selectedColor: configuration.selectedColor,
                onSelect: { [weak self] color in
                    self?.configuration?.onColorChange?(color)
                }
            )
            menu.addItem(item)
        }

        return menu.items.isEmpty ? nil : menu
    }

    @objc private func rename(_ sender: NSMenuItem) {
        configuration?.onRename?()
    }

    @objc private func delete(_ sender: NSMenuItem) {
        configuration?.onDelete?()
    }
}

extension BookmarkCollectionColor {
    var appKitColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .gray: .systemGray
        }
    }

    var localizedName: String {
        switch self {
        case .red: "红色".obeliskLocalized
        case .orange: "橙色".obeliskLocalized
        case .yellow: "黄色".obeliskLocalized
        case .green: "绿色".obeliskLocalized
        case .blue: "蓝色".obeliskLocalized
        case .purple: "紫色".obeliskLocalized
        case .pink: "粉色".obeliskLocalized
        case .gray: "灰色".obeliskLocalized
        }
    }
}

@MainActor
private final class CollectionColorPickerMenuView: NSView {
    private let colors = BookmarkCollectionColor.allCases
    private let onSelect: (BookmarkCollectionColor) -> Void
    private var buttons: [CollectionColorSwatchButton] = []

    init(
        selectedColor: BookmarkCollectionColor,
        onSelect: @escaping (BookmarkCollectionColor) -> Void
    ) {
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: 214, height: 42))

        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .fillEqually
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        buttons = colors.enumerated().map { index, color in
            let button = CollectionColorSwatchButton(
                color: color.appKitColor,
                isSelected: color == selectedColor
            )
            button.tag = index
            button.target = self
            button.action = #selector(selectColor(_:))
            button.toolTip = color.localizedName
            button.setAccessibilityLabel(color.localizedName)
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityValue(color == selectedColor ? 1 : 0)
            stackView.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 23).isActive = true
            button.heightAnchor.constraint(equalToConstant: 23).isActive = true
            return button
        }

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func selectColor(_ sender: NSButton) {
        guard colors.indices.contains(sender.tag) else { return }
        let selectedColor = colors[sender.tag]
        for (button, color) in zip(buttons, colors) {
            let isSelected = color == selectedColor
            button.isSwatchSelected = isSelected
            button.setAccessibilityValue(isSelected ? 1 : 0)
        }
        onSelect(selectedColor)
        enclosingMenuItem?.menu?.cancelTracking()
    }
}

@MainActor
private final class CollectionColorSwatchButton: NSButton {
    let swatchColor: NSColor
    var isSwatchSelected: Bool {
        didSet { needsDisplay = true }
    }

    init(color: NSColor, isSelected: Bool) {
        self.swatchColor = color
        self.isSwatchSelected = isSelected
        super.init(frame: .zero)
        title = ""
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        if isSwatchSelected {
            let ringRect = NSRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)
            let ring = NSBezierPath(ovalIn: ringRect)
            NSColor.separatorColor.setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }

        let swatchRect = NSRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)
        let swatch = NSBezierPath(ovalIn: swatchRect)
        swatchColor.withAlphaComponent(isHighlighted ? 0.72 : 1).setFill()
        swatch.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
