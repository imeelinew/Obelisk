import AppKit
import SwiftUI

@MainActor
struct NativeContextMenuHost<Content: View>: NSViewRepresentable {
    let content: Content
    let menuProvider: (NSEvent) -> NSMenu?

    func makeNSView(context: Context) -> NativeContextMenuHostingView<Content> {
        let hostingView = NativeContextMenuHostingView(rootView: content)
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.menuProvider = menuProvider
        return hostingView
    }

    func updateNSView(_ hostingView: NativeContextMenuHostingView<Content>, context: Context) {
        hostingView.rootView = content
        hostingView.menuProvider = menuProvider
    }

    static func dismantleNSView(
        _ hostingView: NativeContextMenuHostingView<Content>,
        coordinator: Void
    ) {
        hostingView.menuProvider = nil
    }
}

@MainActor
final class NativeContextMenuHostingView<Content: View>: NSHostingView<Content> {
    var menuProvider: ((NSEvent) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(event)
    }
}
