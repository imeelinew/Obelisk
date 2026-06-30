import AppKit
import SwiftUI

/// 桥接 NSVisualEffectView 给 SwiftUI 用作窗口级毛玻璃背景。
///
/// 关键点：
/// - `blendingMode = .behindWindow` —— 模糊的是**窗口后面**（桌面/其它窗口），
///   而不是窗口内部内容；这是真正"透出去"的前提。
/// - 调用方需要先把宿主 NSWindow 设成 `isOpaque = false` 且
///   `backgroundColor = .clear`，否则不透明的窗口背景会盖住效果。
struct WindowBackgroundBlur: NSViewRepresentable {
    /// 0 = 视图完全透明（直接看到桌面）；1 = 材质满强度（默认毛玻璃外观）。
    var materialAlpha: Double
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        view.alphaValue = CGFloat(materialAlpha)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.alphaValue = CGFloat(max(0, min(1, materialAlpha)))
    }
}

/// 一个零尺寸 SwiftUI background，根据 `enabled` 动态把宿主 NSWindow 切到
/// "透明 + 标题栏透明" 或 "默认不透明" 状态。
///
/// 这里之所以走 NSViewRepresentable 而不是在 WindowController 里写死，
/// 是因为透明开关用 @AppStorage 持久化，运行时可被切换；只有让窗口配置
/// 跟着 SwiftUI 状态走，关闭 toggle 时才能真正回到 vanilla 外观。
struct WindowTransparencyConfigurator: NSViewRepresentable {
    var enabled: Bool

    func makeNSView(context: Context) -> NSView {
        Probe()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            apply(to: window)
        }
    }

    private func apply(to window: NSWindow) {
        if enabled {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
        } else {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.titlebarAppearsTransparent = false
        }
        // 触发标题栏/边框立即重绘，避免切换瞬间残留旧外观。
        window.invalidateShadow()
        window.contentView?.needsDisplay = true
    }

    /// 仅用于挂上 view hierarchy 拿到 `window` 引用，本身不画任何东西。
    private final class Probe: NSView {
        override var isOpaque: Bool { false }
        override func draw(_ dirtyRect: NSRect) {}
    }
}

/// Clears NSTableView / scroll view backgrounds so sidebar lists sit on window blur.
struct TransparentListBackgroundInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            view?.nearestTableView()?.applyTransparentListBackground()
        }
    }
}

/// Applies AppKit's native source-list style to SwiftUI sidebar lists.
struct SidebarSourceListStyleInstaller: NSViewRepresentable {
    var enabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view, enabled, coordinator = context.coordinator] in
            guard let tableView = view?.nearestTableView() else { return }
            coordinator.configure(tableView, enabled: enabled)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var tableView: NSTableView?
        private var enabled = false

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func configure(_ tableView: NSTableView, enabled: Bool) {
            if self.tableView !== tableView {
                removeObservers()
                self.tableView = tableView
                installObservers(for: tableView)
            }

            self.enabled = enabled
            refresh()
        }

        private func installObservers(for tableView: NSTableView) {
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(handleRefreshNotification),
                name: NSTableView.selectionDidChangeNotification,
                object: tableView
            )
            center.addObserver(
                self,
                selector: #selector(handleRefreshNotification),
                name: NSWindow.didBecomeKeyNotification,
                object: tableView.window
            )
            center.addObserver(
                self,
                selector: #selector(handleRefreshNotification),
                name: NSWindow.didResignKeyNotification,
                object: tableView.window
            )
            center.addObserver(
                self,
                selector: #selector(handleRefreshNotification),
                name: NSApplication.didBecomeActiveNotification,
                object: NSApp
            )
        }

        private func removeObservers() {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func handleRefreshNotification() {
            scheduleRefresh()
        }

        private func scheduleRefresh() {
            DispatchQueue.main.async { [weak self] in
                self?.refresh()
            }
        }

        private func refresh() {
            guard let tableView else { return }
            tableView.applySidebarSourceListStyle(enabled: enabled)
            tableView.applyVisibleRowEmphasis(isEmphasized: !enabled)
            DispatchQueue.main.async { [weak self] in
                guard let self, let tableView = self.tableView else { return }
                tableView.applyVisibleRowEmphasis(isEmphasized: !self.enabled)
            }
        }
    }
}

private extension NSView {
    func nearestTableView() -> NSTableView? {
        var candidate: NSView? = self
        while let view = candidate {
            if let tableView = view.firstDescendant(ofType: NSTableView.self) {
                return tableView
            }
            candidate = view.superview
        }
        return nil
    }

    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let typed = self as? T {
            return typed
        }

        for subview in subviews {
            if let typed = subview.firstDescendant(ofType: type) {
                return typed
            }
        }

        return nil
    }
}

private extension NSTableView {
    func applyTransparentListBackground() {
        backgroundColor = .clear
        enclosingScrollView?.drawsBackground = false
    }

    func applySidebarSourceListStyle(enabled: Bool) {
        if enabled {
            style = .sourceList
        } else {
            style = .automatic
            selectionHighlightStyle = .regular
        }
    }

    func applyVisibleRowEmphasis(isEmphasized: Bool) {
        let visibleRows = rows(in: visibleRect)
        guard visibleRows.location != NSNotFound else { return }

        for row in visibleRows.location..<(visibleRows.location + visibleRows.length) {
            guard let rowView = rowView(atRow: row, makeIfNecessary: false) else {
                continue
            }
            rowView.isEmphasized = isEmphasized
            rowView.needsDisplay = true
        }
    }
}
