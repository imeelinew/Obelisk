import AppKit
import SwiftUI

@MainActor
final class BookmarkManagerWindowController: NSObject, NSWindowDelegate {
    private let model: BookmarksModel
    private let faviconLoader: FaviconLoader
    private let addRequest: AddBookmarkRequest
    private let onStorageRootChanged: (URL) -> Void
    private let onWindowClosed: () -> Void
    private var window: NSWindow?

    init(
        model: BookmarksModel,
        faviconLoader: FaviconLoader,
        addRequest: AddBookmarkRequest,
        onStorageRootChanged: @escaping (URL) -> Void,
        onWindowClosed: @escaping () -> Void
    ) {
        self.model = model
        self.faviconLoader = faviconLoader
        self.addRequest = addRequest
        self.onStorageRootChanged = onStorageRootChanged
        self.onWindowClosed = onWindowClosed
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
        // ARC owns the window through `self.window`. Letting AppKit release it as
        // well can over-release the SwiftUI hosting hierarchy when the close
        // button drains the current event's autorelease pool.
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

    func windowDidClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow {
            closingWindow.delegate = nil
        }
        window = nil
        onWindowClosed()
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? newFrame
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        true
    }
}
