import AppKit
import SwiftUI

@MainActor
final class BookmarkManagerWindowController: NSObject, NSWindowDelegate {
    private let model: BookmarksModel
    private let faviconLoader: FaviconLoader
    private let addRequest: AddBookmarkRequest
    private let onStorageRootChanged: (URL) -> Void
    private var window: NSWindow?

    init(
        model: BookmarksModel,
        faviconLoader: FaviconLoader,
        addRequest: AddBookmarkRequest,
        onStorageRootChanged: @escaping (URL) -> Void
    ) {
        self.model = model
        self.faviconLoader = faviconLoader
        self.addRequest = addRequest
        self.onStorageRootChanged = onStorageRootChanged
    }

    func show() {
        if let window {
            model.reload()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: BookmarkManagerView(
                model: model,
                faviconLoader: faviconLoader,
                addRequest: addRequest,
                onStorageRootChanged: onStorageRootChanged
            )
        )

        let win = NSWindow(contentViewController: hosting)
        win.title = BookmarkManagerView.SettingsPage.bookmarks.title
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        win.collectionBehavior = [.fullScreenNone, .fullScreenDisallowsTiling]
        win.isReleasedWhenClosed = false
        let defaultWindowFrameSize = NSSize(width: 950, height: 830)
        let minimumContentSize = NSSize(width: 950, height: 830)
        win.minSize = win.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize)).size
        win.setFrame(NSRect(origin: win.frame.origin, size: defaultWindowFrameSize), display: false)
        win.center()
        win.delegate = self
        window = win

        model.reload()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        // 退回 accessory：Dock 图标消失，但 statusItem 菜单栏图标独立保留。
        NSApp.setActivationPolicy(.accessory)
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? newFrame
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        true
    }
}
