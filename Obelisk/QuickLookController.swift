import AppKit
import Carbon.HIToolbox
import ObeliskCore
import Observation

@MainActor
@Observable
final class QuickLookController {
    private var window: BookmarkQuickLookWindow?
    private var monitor: Any?
    private var currentBookmarkID: Bookmark.ID?
    private var lastPresentationEventTimestamp: TimeInterval?

    // 由 BookmarkManagerView 注入的稳定引用/binding，可在 monitor 闭包中安全读取当前值。
    var selection: () -> Set<Bookmark.ID> = { [] }
    var bookmarkLookup: (Bookmark.ID) -> Bookmark? = { _ in nil }
    var isSheetPresented: () -> Bool = { false }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        window?.close()
        window = nil
    }

    func dismiss() {
        window?.close()
        window = nil
        currentBookmarkID = nil
        lastPresentationEventTimestamp = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.numericPad)
        guard modifiers.isEmpty, event.keyCode == UInt16(kVK_Space) else {
            return event
        }

        // QuickLook 窗口本身聚焦时，space 关闭它（对齐 macOS 原生 QuickLook 行为）。
        // 打开窗口后，AppKit 可能会把同一次 Space 序列再投递给新 key window；
        // 它不是 key repeat，但会立刻把刚打开的窗口关掉。
        if let window, window.isVisible, NSApp.keyWindow === window {
            if event.isARepeat || isPresentationEcho(event) {
                return nil
            }
            dismiss()
            return nil
        }

        // 文本输入时不拦截 space。
        if Self.firstResponderIsTextField() {
            return event
        }
        // 有 sheet 弹出时不拦截。
        if isSheetPresented() {
            return event
        }
        guard !event.isARepeat else {
            return nil
        }
        // 仅单选时触发。
        let current = selection()
        guard current.count == 1, let id = current.first,
              let bookmark = bookmarkLookup(id) else {
            return event
        }

        toggle(for: bookmark, eventTimestamp: event.timestamp)
        return nil
    }

    private func toggle(for bookmark: Bookmark, eventTimestamp: TimeInterval) {
        if let window, window.isVisible {
            if currentBookmarkID == bookmark.id {
                // 同一书签：关闭
                dismiss()
            } else {
                // 不同书签：更新预览
                window.load(bookmark)
                currentBookmarkID = bookmark.id
                lastPresentationEventTimestamp = eventTimestamp
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            let window = BookmarkQuickLookWindow(bookmark: bookmark)
            self.window = window
            currentBookmarkID = bookmark.id
            lastPresentationEventTimestamp = eventTimestamp
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.maximizeAfterPresentation()
        }
    }

    private func isPresentationEcho(_ event: NSEvent) -> Bool {
        guard let lastPresentationEventTimestamp else { return false }
        return event.timestamp - lastPresentationEventTimestamp < 0.35
    }

    private static func firstResponderIsTextField() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        let responder = window.firstResponder
        return responder is NSTextView || responder is NSTextField || responder is NSSearchField
    }
}
