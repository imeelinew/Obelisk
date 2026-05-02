import AppKit
import SwiftUI

@MainActor
final class BookmarkManagerWindowController: NSObject, NSWindowDelegate {
    private let model: BookmarksModel
    private let faviconLoader: FaviconLoader
    private var window: NSWindow?

    init(model: BookmarksModel, faviconLoader: FaviconLoader) {
        self.model = model
        self.faviconLoader = faviconLoader
    }

    func show() {
        if let window {
            model.reload()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: BookmarkManagerView(model: model, faviconLoader: faviconLoader)
        )

        let win = NSWindow(contentViewController: hosting)
        win.title = "UniBookmark"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        win.titlebarAppearsTransparent = false
        win.toolbarStyle = .unified
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 560, height: 420))
        win.center()
        win.delegate = self
        window = win

        model.reload()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        // Hide the dock icon again so we behave like a pure menu-bar app.
        NSApp.setActivationPolicy(.accessory)
    }
}
