import AppKit
import ObeliskCore

@MainActor
final class BookmarkStatusMenuController: NSObject, NSMenuDelegate {
    private let maxMenuTitlePixelWidth: CGFloat = 300
    private static let destructiveMenuItemIdentifier = NSUserInterfaceItemIdentifier("ObeliskDestructiveMenuItem")
    private lazy var statusItem: NSStatusItem = {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // macOS 27 presents the default status-bar button through a scene-backed
        // replicant whose local host window can remain parked at the screen's
        // trailing edge. Reusing AppKit's own button as the status item's view
        // keeps native NSMenu geometry attached to the rendered menu-bar slot.
        if #available(macOS 27.0, *), let button = item.button {
            button.frame.size.width = AppIcon.menuBarImage().size.width
            item.view = button
        }

        item.autosaveName = "com.eli.Obelisk.statusItem.main"
        return item
    }()
    private var statusBarButton: NSStatusBarButton? {
        (statusItem.view as? NSStatusBarButton) ?? statusItem.button
    }
    var feedbackAnchorView: NSView? { statusBarButton }
    private let bookmarksModel: BookmarksModel
    private let faviconLoader: FaviconLoader
    private var statusMenu: NSMenu?
    private var rebuildDebounce: DispatchWorkItem?

    init(model: BookmarksModel, faviconLoader: FaviconLoader) {
        self.bookmarksModel = model
        self.faviconLoader = faviconLoader
        super.init()
        configureStatusItemAppearance()
    }

    func configureStatusItemAppearance() {
        guard let button = statusBarButton else { return }

        let image = AppIcon.menuBarImage()
        button.image = image
        button.title = ""
        button.refusesFirstResponder = true
        button.setAccessibilityLabel("Obelisk")
    }

    func scheduleRebuild() {
        guard statusMenu != nil else { return }
        rebuildDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rebuildMenu()
        }
        rebuildDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    @discardableResult
    func rebuildMenu() -> NSMenu {
        bookmarksModel.applyAutoArchiveIfNeeded()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let renderSections = bookmarksModel.menuRenderSections()

        if let error = bookmarksModel.loadErrorMessage {
            let errorItem = NSMenuItem(title: "读取失败: \(error)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        if bookmarksModel.loadErrorMessage == nil, renderSections.isEmpty {
            let header = NSMenuItem(title: "书签", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(NSMenuItem.separator())
            let emptyItem = NSMenuItem(title: "暂无书签", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for section in renderSections {
                switch section.presentation {
                case .inline:
                    appendSection(title: section.title, bookmarks: section.bookmarks, to: menu)
                case .submenu:
                    appendBookmarkSubmenu(title: section.title, bookmarks: section.bookmarks, to: menu)
                }
            }
        }

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        quitItem.identifier = Self.destructiveMenuItemIdentifier
        applyDestructiveMenuItemStyle(to: quitItem, highlighted: false)
        menu.addItem(quitItem)

        statusMenu = menu
        statusItem.menu = menu
        return menu
    }

    private func appendSection(title: String, bookmarks: [Bookmark], to menu: NSMenu) {
        if menu.items.last != nil {
            menu.addItem(NSMenuItem.separator())
        }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for bookmark in bookmarks {
            menu.addItem(menuItem(for: bookmark))
        }
    }

    private func appendBookmarkSubmenu(title: String, bookmarks: [Bookmark], to menu: NSMenu) {
        if menu.items.last != nil {
            menu.addItem(NSMenuItem.separator())
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        for bookmark in bookmarks {
            submenu.addItem(menuItem(for: bookmark))
        }
        item.submenu = submenu
        menu.addItem(item)
    }

    private func menuItem(for bookmark: Bookmark) -> NSMenuItem {
        let title = truncatedTitle(bookmark.title)
        let item = NSMenuItem(
            title: title,
            action: #selector(openBookmark(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = bookmark
        let baseFavicon = faviconLoader.image(for: bookmark.url)
            ?? AppIcon.faviconPlaceholder(size: AppIcon.menuItemFaviconSize)
        AppIcon.setMenuItemFavicon(baseFavicon, on: item)
        return item
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for menuItem in menu.items where menuItem.identifier == Self.destructiveMenuItemIdentifier {
            applyDestructiveMenuItemStyle(to: menuItem, highlighted: menuItem === item)
        }
    }

    private func applyDestructiveMenuItemStyle(to item: NSMenuItem, highlighted: Bool) {
        item.attributedTitle = NSAttributedString(
            string: item.title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: highlighted ? NSColor.white : NSColor.systemRed
            ]
        )
    }

    private func truncatedTitle(_ title: String) -> String {
        let ellipsis = "…"
        let font = NSFont.menuFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]

        guard title.size(withAttributes: attributes).width > maxMenuTitlePixelWidth else {
            return title
        }

        var low = title.startIndex
        var high = title.endIndex
        var best = ""

        while low < high {
            let distance = title.distance(from: low, to: high)
            let mid = title.index(low, offsetBy: distance / 2)
            let candidate = String(title[..<mid]).trimmingCharacters(in: .whitespacesAndNewlines) + ellipsis

            if candidate.size(withAttributes: attributes).width <= maxMenuTitlePixelWidth {
                best = candidate
                if mid == title.endIndex { break }
                low = title.index(after: mid)
            } else {
                if mid == low { break }
                high = mid
            }
        }

        return best.isEmpty ? ellipsis : best
    }

    @objc private func openBookmark(_ sender: NSMenuItem) {
        guard let bookmark = sender.representedObject as? Bookmark else { return }
        bookmarksModel.openBookmark(bookmark)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
