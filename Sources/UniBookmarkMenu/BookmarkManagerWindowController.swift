import AppKit
import SwiftUI

@MainActor
final class BookmarkManagerWindowController: NSObject, NSWindowDelegate {
    private let model: BookmarksModel
    private let faviconLoader: FaviconLoader
    private let addRequest: AddBookmarkRequest
    private var window: NSWindow?

    init(model: BookmarksModel, faviconLoader: FaviconLoader, addRequest: AddBookmarkRequest) {
        self.model = model
        self.faviconLoader = faviconLoader
        self.addRequest = addRequest
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
                addRequest: addRequest
            )
        )

        let win = NSWindow(contentViewController: hosting)
        win.title = "设置"
        win.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        win.titlebarAppearsTransparent = false
        win.toolbarStyle = .unified
        win.isReleasedWhenClosed = false
        let contentSize = NSSize(width: 650, height: 550)
        win.setContentSize(contentSize)
        win.minSize = win.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        win.maxSize = win.minSize
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
