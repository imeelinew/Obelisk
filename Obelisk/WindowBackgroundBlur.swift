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
