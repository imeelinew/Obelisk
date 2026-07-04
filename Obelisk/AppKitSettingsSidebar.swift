import AppKit
import SwiftUI

struct AppKitSettingsSidebar: NSViewRepresentable {
    var pages: [BookmarkManagerView.SettingsPage]
    @Binding var selectedPage: BookmarkManagerView.SettingsPage?
    var badgeCount: (BookmarkManagerView.SettingsPage) -> Int?
    var iconTheme: SidebarIconTheme
    var iconStyle: SidebarIconStyle
    var colorfulIconSize: CGFloat
    var colorfulSymbolSize: CGFloat
    var colorfulCornerRadius: CGFloat
    var professionalIconSize: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.reloadIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: AppKitSettingsSidebar
        private weak var tableView: NSTableView?
        private var items: [SettingsSidebarItem]
        private var isSyncingSelection = false

        init(parent: AppKitSettingsSidebar) {
            self.parent = parent
            self.items = parent.items
            super.init()
        }

        func makeScrollView() -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.horizontalScrollElasticity = .none

            let tableView = NSTableView()
            tableView.frame = scrollView.contentView.bounds
            tableView.autoresizingMask = [.width]
            tableView.delegate = self
            tableView.dataSource = self
            tableView.headerView = nil
            tableView.backgroundColor = .clear
            tableView.style = .sourceList
            tableView.selectionHighlightStyle = .regular
            tableView.rowSizeStyle = .custom
            tableView.intercellSpacing = NSSize(width: 0, height: 2)
            tableView.allowsMultipleSelection = false
            tableView.allowsEmptySelection = true
            tableView.floatsGroupRows = false
            tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

            let column = NSTableColumn(identifier: .settingsSidebarColumn)
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)

            scrollView.documentView = tableView
            self.tableView = tableView
            syncSelection(in: tableView)
            return scrollView
        }

        func reloadIfNeeded() {
            let nextItems = parent.items
            let rowsChanged = nextItems != items
            items = nextItems

            guard let tableView else { return }
            syncTableWidth()
            if rowsChanged {
                tableView.reloadData()
            } else {
                reloadVisibleRows(in: tableView)
            }
            syncSelection(in: tableView)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            guard items.indices.contains(row) else { return false }
            if case .header = items[row] { return true }
            return false
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard items.indices.contains(row) else { return false }
            if case .page = items[row] { return true }
            return false
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard items.indices.contains(row) else { return 32 }
            switch items[row] {
            case .header:
                return 24
            case .page:
                return parent.iconTheme == .professional ? 30 : 32
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            SettingsSidebarRowView()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard items.indices.contains(row) else { return nil }
            switch items[row] {
            case .header(let title):
                let cell = tableView.makeView(
                    withIdentifier: SettingsSidebarHeaderCell.reuseIdentifier,
                    owner: self
                ) as? SettingsSidebarHeaderCell ?? SettingsSidebarHeaderCell()
                cell.configure(title: title)
                return cell

            case .page(let page):
                let cell = tableView.makeView(
                    withIdentifier: SettingsSidebarPageCell.reuseIdentifier,
                    owner: self
                ) as? SettingsSidebarPageCell ?? SettingsSidebarPageCell()
                cell.configure(
                    page: page,
                    badgeCount: parent.badgeCount(page),
                    theme: parent.iconTheme,
                    iconStyle: parent.iconStyle,
                    colorfulIconSize: parent.colorfulIconSize,
                    colorfulSymbolSize: parent.colorfulSymbolSize,
                    colorfulCornerRadius: parent.colorfulCornerRadius,
                    professionalIconSize: parent.professionalIconSize,
                    isSelected: tableView.selectedRow == row
                )
                return cell
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection,
                  let tableView = notification.object as? NSTableView,
                  items.indices.contains(tableView.selectedRow),
                  case .page(let page) = items[tableView.selectedRow] else {
                return
            }

            parent.selectedPage = page
            if parent.selectedPage != page {
                syncSelection(in: tableView)
            }
            applySelectionStyleToVisibleRows(in: tableView)
        }

        private func syncSelection(in tableView: NSTableView) {
            guard let selectedPage = parent.selectedPage,
                  let row = items.firstIndex(of: .page(selectedPage)) else {
                isSyncingSelection = true
                tableView.deselectAll(nil)
                isSyncingSelection = false
                applySelectionStyleToVisibleRows(in: tableView)
                return
            }

            guard tableView.selectedRow != row else {
                applySelectionStyleToVisibleRows(in: tableView)
                return
            }
            isSyncingSelection = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isSyncingSelection = false
            applySelectionStyleToVisibleRows(in: tableView)
        }

        private func reloadVisibleRows(in tableView: NSTableView) {
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.location != NSNotFound else { return }

            for row in visibleRows.location ..< NSMaxRange(visibleRows) {
                guard items.indices.contains(row),
                      case .page(let page) = items[row],
                      let cell = tableView.view(
                        atColumn: 0,
                        row: row,
                        makeIfNecessary: false
                      ) as? SettingsSidebarPageCell else {
                    continue
                }

                cell.configure(
                    page: page,
                    badgeCount: parent.badgeCount(page),
                    theme: parent.iconTheme,
                    iconStyle: parent.iconStyle,
                    colorfulIconSize: parent.colorfulIconSize,
                    colorfulSymbolSize: parent.colorfulSymbolSize,
                    colorfulCornerRadius: parent.colorfulCornerRadius,
                    professionalIconSize: parent.professionalIconSize,
                    isSelected: tableView.selectedRow == row
                )
            }
        }

        private func applySelectionStyleToVisibleRows(in tableView: NSTableView) {
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.location != NSNotFound else { return }

            for row in visibleRows.location ..< NSMaxRange(visibleRows) {
                guard let cell = tableView.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: false
                ) as? SettingsSidebarPageCell else {
                    continue
                }
                cell.applySelectionStyle(isSelected: tableView.selectedRow == row)
            }
        }

        private func syncTableWidth() {
            guard let tableView, let scrollView = tableView.enclosingScrollView else { return }
            let width = max(scrollView.contentView.bounds.width, 100)
            if tableView.frame.width != width {
                tableView.frame.size.width = width
            }
            if let column = tableView.tableColumns.first, column.width != width {
                column.width = width
            }
        }
    }
}

private enum SettingsSidebarItem: Equatable {
    case header(String)
    case page(BookmarkManagerView.SettingsPage)
}

private extension AppKitSettingsSidebar {
    var items: [SettingsSidebarItem] {
        var result = pages
            .filter { $0.group == .content }
            .map(SettingsSidebarItem.page)

        for group in BookmarkManagerView.SettingsPage.Group.allCases where group != .content {
            let groupedPages = pages.filter { $0.group == group }
            guard !groupedPages.isEmpty else { continue }
            result.append(.header(group.rawValue))
            result.append(contentsOf: groupedPages.map(SettingsSidebarItem.page))
        }

        return result
    }
}

private final class SettingsSidebarRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            applySelectionStyleToCell()
        }
    }

    override var isEmphasized: Bool {
        get { false }
        set { super.isEmphasized = false }
    }

    private func applySelectionStyleToCell() {
        for subview in subviews {
            (subview as? SettingsSidebarPageCell)?.applySelectionStyle(isSelected: isSelected)
        }
    }
}

private final class SettingsSidebarHeaderCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SettingsSidebarHeaderCell")
    private let titleField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier

        titleField.font = .systemFont(ofSize: 11, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -9),
            titleField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        titleField.stringValue = title
    }
}

private final class SettingsSidebarPageCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SettingsSidebarPageCell")
    private static let leadingInset: CGFloat = 3
    private static let trailingInset: CGFloat = 14
    private static let sourceListSelectionRightInset: CGFloat = 24

    private let colorfulIconView = SettingsSidebarColorIconView()
    private let professionalIconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let badgeField = NSTextField(labelWithString: "")
    private var colorfulIconWidth: NSLayoutConstraint!
    private var colorfulIconHeight: NSLayoutConstraint!
    private var professionalIconWidth: NSLayoutConstraint!
    private var professionalIconHeight: NSLayoutConstraint!
    private var titleToColorfulIcon: NSLayoutConstraint!
    private var titleToProfessionalIcon: NSLayoutConstraint!
    private var isSelected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier

        colorfulIconView.translatesAutoresizingMaskIntoConstraints = false

        professionalIconView.imageScaling = .scaleProportionallyDown
        professionalIconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false

        badgeField.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        badgeField.textColor = .secondaryLabelColor
        badgeField.alignment = .right
        badgeField.lineBreakMode = .byTruncatingTail
        badgeField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(colorfulIconView)
        addSubview(professionalIconView)
        addSubview(titleField)
        addSubview(badgeField)

        colorfulIconWidth = colorfulIconView.widthAnchor.constraint(equalToConstant: 22)
        colorfulIconHeight = colorfulIconView.heightAnchor.constraint(equalToConstant: 22)
        professionalIconWidth = professionalIconView.widthAnchor.constraint(equalToConstant: 18)
        professionalIconHeight = professionalIconView.heightAnchor.constraint(equalToConstant: 18)
        titleToColorfulIcon = titleField.leadingAnchor.constraint(
            equalTo: colorfulIconView.trailingAnchor,
            constant: 12
        )
        titleToProfessionalIcon = titleField.leadingAnchor.constraint(
            equalTo: professionalIconView.trailingAnchor,
            constant: 8
        )

        NSLayoutConstraint.activate([
            colorfulIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            colorfulIconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            colorfulIconWidth,
            colorfulIconHeight,

            professionalIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            professionalIconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            professionalIconWidth,
            professionalIconHeight,

            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: badgeField.leadingAnchor, constant: -8),

            badgeField.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -(Self.sourceListSelectionRightInset + Self.trailingInset)
            ),
            badgeField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        page: BookmarkManagerView.SettingsPage,
        badgeCount: Int?,
        theme: SidebarIconTheme,
        iconStyle: SidebarIconStyle,
        colorfulIconSize: CGFloat,
        colorfulSymbolSize: CGFloat,
        colorfulCornerRadius: CGFloat,
        professionalIconSize: CGFloat,
        isSelected: Bool
    ) {
        titleField.stringValue = page.title
        applySelectionStyle(isSelected: isSelected)

        if let badgeCount {
            badgeField.stringValue = "\(badgeCount)"
            badgeField.isHidden = false
        } else {
            badgeField.stringValue = ""
            badgeField.isHidden = true
        }

        switch theme {
        case .colorful:
            colorfulIconWidth.constant = colorfulIconSize
            colorfulIconHeight.constant = colorfulIconSize
            colorfulIconView.configure(
                page: page,
                iconStyle: iconStyle,
                size: colorfulIconSize,
                symbolSize: colorfulSymbolSize,
                cornerRadius: colorfulCornerRadius
            )
            colorfulIconView.isHidden = false
            professionalIconView.isHidden = true
            titleToProfessionalIcon.isActive = false
            titleToColorfulIcon.isActive = true

        case .professional:
            let iconSize = professionalIconSize + 3
            professionalIconWidth.constant = iconSize
            professionalIconHeight.constant = iconSize
            professionalIconView.image = page.professionalAppKitGradientIcon(style: iconStyle)
            professionalIconView.contentTintColor = nil
            colorfulIconView.isHidden = true
            professionalIconView.isHidden = false
            titleToColorfulIcon.isActive = false
            titleToProfessionalIcon.isActive = true
        }
    }

    func applySelectionStyle(isSelected: Bool) {
        self.isSelected = isSelected
        let weight: NSFont.Weight = isSelected ? .semibold : .regular
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: weight)
        badgeField.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: weight
        )
    }
}

private final class SettingsSidebarColorIconView: NSView {
    private let iconImageView = NSImageView()
    private var page: BookmarkManagerView.SettingsPage = .bookmarks
    private var iconSize: CGFloat = 22
    private var symbolSize: CGFloat = 11
    private var cornerRadius: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconImageView.imageScaling = .scaleProportionallyDown
        iconImageView.contentTintColor = .white
        addSubview(iconImageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        page: BookmarkManagerView.SettingsPage,
        iconStyle: SidebarIconStyle,
        size: CGFloat,
        symbolSize: CGFloat,
        cornerRadius: CGFloat
    ) {
        self.page = page
        self.iconSize = size
        self.symbolSize = symbolSize
        self.cornerRadius = cornerRadius
        iconImageView.image = page.professionalAppKitIcon(style: iconStyle)
        iconImageView.contentTintColor = .white
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()

        let rect = iconRect
        let drawSize = symbolSize + 2
        iconImageView.frame = NSRect(
            x: rect.midX - drawSize / 2,
            y: rect.midY - drawSize / 2,
            width: drawSize,
            height: drawSize
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = iconRect
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

        if let gradient = NSGradient(colors: page.appKitGradientColors) {
            gradient.draw(in: path, angle: 315)
        }
    }

    private var iconRect: NSRect {
        bounds.insetBy(
            dx: max(0, (bounds.width - iconSize) / 2),
            dy: max(0, (bounds.height - iconSize) / 2)
        )
    }
}

private extension BookmarkManagerView.SettingsPage {
    var appKitGradientColors: [NSColor] {
        switch self {
        case .bookmarks:
            return [Self.rgb(1.0, 0.50, 0.40), Self.rgb(0.96, 0.28, 0.24)]
        case .search:
            return [Self.rgb(0.42, 0.74, 0.94), Self.rgb(0.18, 0.46, 0.78)]
        case .ai:
            return [
                Self.rgb(1.0, 0.78, 0.25),
                Self.rgb(1.0, 0.20, 0.28),
                Self.rgb(0.54, 0.28, 0.96),
                Self.rgb(0.22, 0.66, 1.0),
            ]
        case .collections:
            return [Self.rgb(0.52, 0.72, 0.98), Self.rgb(0.22, 0.48, 0.88)]
        case .hiddenBookmarks:
            return [Self.rgb(0.58, 0.66, 0.80), Self.rgb(0.34, 0.44, 0.62)]
        case .archive:
            return [Self.rgb(0.66, 0.72, 0.80), Self.rgb(0.38, 0.46, 0.56)]
        case .appearance:
            return [Self.rgb(0.46, 0.82, 0.50), Self.rgb(0.14, 0.62, 0.30)]
        case .menuBar:
            return [Self.rgb(0.30, 0.78, 0.90), Self.rgb(0.12, 0.48, 0.82)]
        case .shortcuts:
            return [Self.rgb(0.98, 0.72, 0.36), Self.rgb(0.86, 0.48, 0.10)]
        case .privacy:
            return [Self.rgb(0.72, 0.52, 1.0), Self.rgb(0.42, 0.24, 0.86)]
        case .settings:
            return [Self.rgb(0.52, 0.64, 0.78), Self.rgb(0.28, 0.38, 0.52)]
        case .developer:
            return [Self.rgb(1.0, 0.78, 0.30), Self.rgb(0.92, 0.52, 0.08)]
        }
    }

    func professionalAppKitIcon(style: SidebarIconStyle) -> NSImage? {
        if let image = Self.resourceImage(named: professionalIconResourceName, style: style) {
            return image
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    func professionalAppKitGradientIcon(style: SidebarIconStyle) -> NSImage? {
        guard let maskImage = professionalAppKitIcon(style: style),
              let gradient = NSGradient(colors: appKitGradientColors) else {
            return professionalAppKitIcon(style: style)
        }

        let canvasSize = NSSize(width: 64, height: 64)
        let image = NSImage(size: canvasSize)
        let bounds = NSRect(origin: .zero, size: canvasSize)
        let iconMask = maskImage.copy() as? NSImage ?? maskImage
        iconMask.isTemplate = false

        image.lockFocus()
        NSColor.clear.setFill()
        bounds.fill()
        iconMask.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)

        let context = NSGraphicsContext.current
        let previousOperation = context?.compositingOperation
        context?.compositingOperation = .sourceIn
        gradient.draw(in: bounds, angle: 315)
        if let previousOperation {
            context?.compositingOperation = previousOperation
        }
        image.unlockFocus()

        image.isTemplate = false
        return image
    }

    static func resourceImage(named name: String, style: SidebarIconStyle) -> NSImage? {
        let resourceURLs: [URL?]
        switch style {
        case .lucide:
            resourceURLs = [
                Bundle.main.resourceURL?.appendingPathComponent("\(name).svg"),
                Bundle.main.resourceURL?.appendingPathComponent("SidebarIcons/\(name).svg"),
                Bundle.main.resourceURL?.appendingPathComponent("Resources/SidebarIcons/\(name).svg"),
            ]
        case .tabler:
            let tablerName = "tabler-\(name)"
            resourceURLs = [
                Bundle.main.resourceURL?.appendingPathComponent("\(tablerName).svg"),
                Bundle.main.resourceURL?.appendingPathComponent("SidebarIconsTabler/\(tablerName).svg"),
                Bundle.main.resourceURL?.appendingPathComponent("Resources/SidebarIconsTabler/\(tablerName).svg"),
            ]
        }

        for url in resourceURLs.compactMap({ $0 }) {
            if let image = NSImage(contentsOf: url) {
                let copy = image.copy() as? NSImage ?? image
                copy.isTemplate = true
                return copy
            }
        }

        return nil
    }

    static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let settingsSidebarColumn = NSUserInterfaceItemIdentifier("SettingsSidebarColumn")
}
