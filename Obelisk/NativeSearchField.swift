import AppKit
import Carbon.HIToolbox
import SwiftUI

struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusesOnAppear = false
    var focusRequest = 0
    var onEscape: (() -> Void)?
    var onTab: (() -> Void)?
    var onEnter: ((String) -> Void)?
    var onDownArrow: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onEscape: onEscape,
            onTab: onTab,
            onEnter: onEnter,
            onDownArrow: onDownArrow
        )
    }

    func makeNSView(context: Context) -> NativeGlassSearchFieldView {
        let searchField = FocusableSearchField()
        searchField.cell = NativeGlassSearchFieldCell(textCell: "")
        searchField.focusesOnAppear = focusesOnAppear
        searchField.focusRequest = focusRequest
        searchField.onEscape = onEscape
        searchField.onTab = onTab
        searchField.onEnter = onEnter
        searchField.onDownArrow = onDownArrow
        searchField.placeholderString = placeholder
        searchField.delegate = context.coordinator
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: NSFont.systemFontSize)
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.searchFieldAction(_:))
        return NativeGlassSearchFieldView(searchField: searchField)
    }

    func updateNSView(_ glassView: NativeGlassSearchFieldView, context: Context) {
        let searchField = glassView.searchField
        if let searchField = searchField as? FocusableSearchField {
            searchField.focusesOnAppear = focusesOnAppear
            searchField.focusRequest = focusRequest
            searchField.onEscape = onEscape
            searchField.onTab = onTab
            searchField.onEnter = onEnter
            searchField.onDownArrow = onDownArrow
            searchField.focusIfNeeded()
        }
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
        searchField.placeholderString = placeholder
        context.coordinator.text = $text
        context.coordinator.onEscape = onEscape
        context.coordinator.onTab = onTab
        context.coordinator.onEnter = onEnter
        context.coordinator.onDownArrow = onDownArrow
    }

    private final class FocusableSearchField: NSSearchField {
        var focusesOnAppear = false
        var onEscape: (() -> Void)?
        var onTab: (() -> Void)?
        var onEnter: ((String) -> Void)?
        var onDownArrow: (() -> Void)?
        var focusRequest = 0
        private var didFocus = false
        private var handledFocusRequest = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusIfNeeded()
        }

        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.numericPad)
            guard modifiers.isEmpty else {
                super.keyDown(with: event)
                return
            }

            switch event.keyCode {
            case UInt16(kVK_Escape):
                guard let onEscape else { break }
                onEscape()
                return
            case UInt16(kVK_Tab):
                guard let onTab else { break }
                onTab()
                return
            case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
                guard let onEnter else { break }
                onEnter(stringValue)
                return
            case UInt16(kVK_DownArrow):
                guard let onDownArrow else { break }
                onDownArrow()
                return
            default:
                break
            }

            super.keyDown(with: event)
        }

        func focusIfNeeded() {
            guard window != nil else { return }
            let shouldFocusOnAppear = focusesOnAppear && !didFocus
            let shouldFocusForRequest = focusRequest > 0 && focusRequest != handledFocusRequest
            guard shouldFocusOnAppear || shouldFocusForRequest else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                let shouldFocusOnAppear = self.focusesOnAppear && !self.didFocus
                let shouldFocusForRequest = self.focusRequest > 0 &&
                    self.focusRequest != self.handledFocusRequest
                guard shouldFocusOnAppear || shouldFocusForRequest else { return }

                window.makeKey()
                if window.makeFirstResponder(self) {
                    self.didFocus = true
                    if self.focusRequest > 0 {
                        self.handledFocusRequest = self.focusRequest
                    }
                }
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onEscape: (() -> Void)?
        var onTab: (() -> Void)?
        var onEnter: ((String) -> Void)?
        var onDownArrow: (() -> Void)?

        init(
            text: Binding<String>,
            onEscape: (() -> Void)?,
            onTab: (() -> Void)?,
            onEnter: ((String) -> Void)?,
            onDownArrow: (() -> Void)?
        ) {
            self.text = text
            self.onEscape = onEscape
            self.onTab = onTab
            self.onEnter = onEnter
            self.onDownArrow = onDownArrow
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            text.wrappedValue = searchField.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            text.wrappedValue = textView.string
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                onEscape?()
                return true
            case #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.insertTabIgnoringFieldEditor(_:)):
                guard let onTab else { return false }
                onTab()
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                guard let onEnter else { return false }
                onEnter(textView.string)
                return true
            case #selector(NSResponder.moveDown(_:)):
                guard let onDownArrow else { return false }
                onDownArrow()
                return true
            default:
                return false
            }
        }

        @MainActor @objc func searchFieldAction(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
            guard let event = NSApp.currentEvent, event.type == .keyDown else { return }
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.numericPad)
            guard modifiers.isEmpty else { return }
            if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                onEnter?(sender.stringValue)
            }
        }
    }
}

@MainActor
final class NativeGlassSearchFieldCell: NSSearchFieldCell {
    override init(textCell string: String) {
        super.init(textCell: string)
        isEditable = true
        isSelectable = true
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObject: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: searchTextRect(forBounds: rect),
            in: controlView,
            editor: textObject,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObject: NSText,
        delegate: Any?,
        start selectionStart: Int,
        length selectionLength: Int
    ) {
        super.select(
            withFrame: searchTextRect(forBounds: rect),
            in: controlView,
            editor: textObject,
            delegate: delegate,
            start: selectionStart,
            length: selectionLength
        )
    }
}

@MainActor
final class NativeGlassSearchFieldView: NSGlassEffectView {
    let searchField: NSSearchField

    init(searchField: NSSearchField) {
        self.searchField = searchField
        super.init(frame: .zero)

        style = .regular
        cornerRadius = 13
        if #available(macOS 27.0, *) {
            effectIsInteractive = true
        }

        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 9),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -9),
            searchField.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        self.contentView = contentView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
