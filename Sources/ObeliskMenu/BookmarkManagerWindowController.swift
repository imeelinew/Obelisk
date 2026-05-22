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
        win.isReleasedWhenClosed = false
        let contentSize = NSSize(width: 720, height: 600)
        let minimumContentSize = NSSize(width: 650, height: 540)
        win.setContentSize(contentSize)
        win.minSize = win.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize)).size
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
