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
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
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
        } else {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        }
        // 标题栏永远透明：窗口是手工创建的 NSWindow + NSHostingController，
        // SwiftUI 的 toolbarBackgroundVisibility 在这里不生效；只有让标题栏
        // 不自绘背景，BookmarkPageBackground 才能在所有内容页延伸到顶部，
        // 而不是只有顶部恰好是滚动列表的「全部」页看起来正常。
        window.titlebarAppearsTransparent = true
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
