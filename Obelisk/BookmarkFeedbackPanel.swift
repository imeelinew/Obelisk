import AppKit
import QuartzCore

enum BookmarkFeedbackKind: Equatable {
  case success, hidden, intelligence, error
  var dismissalDelay: TimeInterval { 5 }
}
struct BookmarkFeedbackPresentation: Equatable {
  let title: String
  let subtitle: String
  let kind: BookmarkFeedbackKind
}

/// Quick-add feedback stays in AppKit so it never starts the UI extension
@MainActor
final class BookmarkFeedbackPanelController {
  private let anchorView: () -> NSView?
  private var popover: NSPopover?
  private var dismissWorkItem: DispatchWorkItem?
  init(anchorView: @escaping () -> NSView?) { self.anchorView = anchorView }
  func show(_ presentation: BookmarkFeedbackPresentation) {
    dismiss()
    guard let anchor = anchorView() else { return }
    let content = NSViewController()
    let icon = FeedbackSymbolView(kind: presentation.kind)
    let title = NSTextField(labelWithString: presentation.title)
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    let subtitle = NSTextField(wrappingLabelWithString: presentation.subtitle)
    subtitle.font = .systemFont(ofSize: 12)
    subtitle.textColor = .secondaryLabelColor
    subtitle.maximumNumberOfLines = 2
    subtitle.lineBreakMode = .byTruncatingTail
    let labels = NSStackView(views: [title, subtitle])
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 3
    let row = NSStackView(views: [icon, labels])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 32),
      icon.heightAnchor.constraint(equalToConstant: 32),
      row.widthAnchor.constraint(equalToConstant: 280),
    ])
    content.view = row
    row.layoutSubtreeIfNeeded()
    let popover = NSPopover()
    popover.behavior = .applicationDefined
    popover.animates = true
    popover.contentViewController = content
    popover.contentSize = row.fittingSize
    self.popover = popover
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    let work = DispatchWorkItem { [weak self] in self?.dismiss() }
    dismissWorkItem = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + presentation.kind.dismissalDelay, execute: work)
  }
  func hide() { dismiss() }
  private func dismiss() {
    dismissWorkItem?.cancel()
    dismissWorkItem = nil
    popover?.performClose(nil)
    popover?.close()
    popover = nil
  }
}

private final class FeedbackSymbolView: NSView {
  private let kind: BookmarkFeedbackKind
  init(kind: BookmarkFeedbackKind) {
    self.kind = kind
    super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
  }
  required init?(coder: NSCoder) { nil }
  override func draw(_ dirtyRect: NSRect) {
    if kind == .intelligence {
      NSImage(named: "FeedbackIntelligence")?.draw(in: bounds)
      return
    }
    let name: String
    let colors: [NSColor]
    switch kind {
    case .success:
      name = "checkmark.circle.fill"
      colors = [
        .init(red: 0.18, green: 0.78, blue: 0.35, alpha: 1),
        .init(red: 0.12, green: 0.64, blue: 0.28, alpha: 1),
      ]
    case .hidden:
      name = "eye.slash.circle.fill"
      colors = [.labelColor.withAlphaComponent(0.42), .labelColor.withAlphaComponent(0.28)]
    case .intelligence:
      return
    case .error:
      name = "xmark.circle.fill"
      colors = [
        .init(red: 0.94, green: 0.27, blue: 0.22, alpha: 1),
        .init(red: 0.82, green: 0.18, blue: 0.15, alpha: 1),
      ]
    }
    guard
      let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 26, weight: .medium))
    else { return }
    let tinted = NSImage(size: bounds.size, flipped: false) { rect in
      guard let context = NSGraphicsContext.current else { return false }
      image.draw(in: rect.insetBy(dx: 3, dy: 3))
      context.compositingOperation = .sourceIn
      NSGradient(colors: colors)?.draw(in: rect, angle: -90)
      return true
    }
    tinted.draw(in: bounds)
  }
}
