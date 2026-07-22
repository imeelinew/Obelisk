import AppKit
import SwiftUI

@MainActor
struct NativeContextMenuHost<Content: View>: View {
    let content: Content
    let menuProvider: (NSEvent) -> NSMenu?

    var body: some View {
        content
            .overlay {
                NativeContextMenuEventOverlay(menuProvider: menuProvider)
            }
    }
}

@MainActor
private struct NativeContextMenuEventOverlay: NSViewRepresentable {
    let menuProvider: (NSEvent) -> NSMenu?

    func makeNSView(context: Context) -> NativeContextMenuEventView {
        let view = NativeContextMenuEventView()
        view.menuProvider = menuProvider
        return view
    }

    func updateNSView(_ view: NativeContextMenuEventView, context: Context) {
        view.menuProvider = menuProvider
    }

    static func dismantleNSView(_ view: NativeContextMenuEventView, coordinator: Void) {
        view.menuProvider = nil
    }
}

/// A transparent event surface that participates in hit testing only for a
/// contextual click. Normal clicks and gestures continue to reach SwiftUI.
@MainActor
final class NativeContextMenuEventView: NSView {
    var menuProvider: ((NSEvent) -> NSMenu?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), Self.handlesContextMenuEvent(NSApp.currentEvent) else {
            return nil
        }
        return self
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        Self.handlesContextMenuEvent(event)
    }

    static func handlesContextMenuEvent(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        if event.type == .rightMouseDown {
            return true
        }
        return event.type == .leftMouseDown && event.modifierFlags.contains(.control)
    }
}
