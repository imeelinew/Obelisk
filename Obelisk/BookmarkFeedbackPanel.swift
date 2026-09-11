import AppKit
import SwiftUI

enum BookmarkFeedbackKind: Equatable {
    case success
    case hidden
    case intelligence
    case error

    var dismissalDelay: TimeInterval { 5 }
}

struct BookmarkFeedbackPresentation: Equatable {
    let title: String
    let subtitle: String
    let kind: BookmarkFeedbackKind
}

enum BookmarkFeedbackPanelLayout {
    static let contentWidth: CGFloat = 280
}

/// The exact notification content used by the former menu-bar popover.
@MainActor
struct BookmarkAddedNotificationView: View {
    let title: String
    let subtitle: String
    let kind: BookmarkFeedbackKind

    private var iconName: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .hidden: "eye.slash.circle.fill"
        case .intelligence: IntelligenceSymbolIcon.symbolName
        case .error: "xmark.circle.fill"
        }
    }

    private var iconGradient: LinearGradient {
        switch kind {
        case .success:
            LinearGradient(
                colors: [
                    Color(red: 0.18, green: 0.78, blue: 0.35),
                    Color(red: 0.12, green: 0.64, blue: 0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .hidden:
            LinearGradient(
                colors: [
                    Color.primary.opacity(0.42),
                    Color.primary.opacity(0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .intelligence:
            LinearGradient(
                colors: [Color.clear, Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        case .error:
            LinearGradient(
                colors: [
                    Color(red: 0.94, green: 0.27, blue: 0.22),
                    Color(red: 0.82, green: 0.18, blue: 0.15)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            iconView

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(verbatim: subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: BookmarkFeedbackPanelLayout.contentWidth, alignment: .leading)
    }

    @ViewBuilder
    private var iconView: some View {
        if kind == .intelligence {
            IntelligenceSymbolIcon(size: 26, weight: .medium)
                .frame(width: 32, height: 32)
        } else {
            Image(systemName: iconName)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(iconGradient)
                .frame(width: 32, height: 32)
        }
    }
}

@MainActor
final class BookmarkFeedbackPanelController {
    private let anchorView: () -> NSView?
    private var popover: NSPopover?
    private var dismissWorkItem: DispatchWorkItem?

    init(anchorView: @escaping () -> NSView?) {
        self.anchorView = anchorView
    }

    func show(_ presentation: BookmarkFeedbackPresentation) {
        dismiss()
        guard let anchorView = anchorView() else { return }

        let contentView = BookmarkAddedNotificationView(
            title: presentation.title,
            subtitle: presentation.subtitle,
            kind: presentation.kind
        )
        let hosting = NSHostingController(rootView: contentView)
        hosting.view.frame = NSRect(
            x: 0,
            y: 0,
            width: BookmarkFeedbackPanelLayout.contentWidth,
            height: 200
        )
        hosting.view.layoutSubtreeIfNeeded()
        let fitted = hosting.view.fittingSize

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentViewController = hosting
        popover.contentSize = NSSize(
            width: BookmarkFeedbackPanelLayout.contentWidth,
            height: fitted.height
        )
        self.popover = popover

        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + presentation.kind.dismissalDelay,
            execute: workItem
        )
    }

    func hide() {
        dismiss()
    }

    private func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        popover?.performClose(nil)
        popover?.close()
        popover = nil
    }
}
