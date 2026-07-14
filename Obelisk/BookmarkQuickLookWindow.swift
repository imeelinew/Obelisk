import AppKit
import ObeliskCore
import WebKit

@MainActor
final class BookmarkQuickLookWindow: NSWindow, WKNavigationDelegate, WKUIDelegate {
    private let webView: WKWebView
    private let loadingIndicator = NSProgressIndicator()

    init(bookmark: Bookmark) {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        self.webView = webView

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = bookmark.title
        titlebarAppearsTransparent = false
        titleVisibility = .visible
        isReleasedWhenClosed = false
        isOpaque = true
        backgroundColor = .windowBackgroundColor
        minSize = NSSize(width: 480, height: 360)

        webView.navigationDelegate = self
        webView.uiDelegate = self

        let container = NSView()
        contentView = container
        container.addSubview(webView)
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .large
        loadingIndicator.isDisplayedWhenStopped = false
        container.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            loadingIndicator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        load(bookmark)
        center()
    }

    func load(_ bookmark: Bookmark) {
        guard let url = URL(string: bookmark.url) else { return }
        title = bookmark.title
        loadingIndicator.startAnimation(nil)
        webView.load(URLRequest(url: url))
    }

    func maximizeAfterPresentation() {
        DispatchQueue.main.async { [weak self] in
            guard let self, isVisible else { return }
            let targetFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            if let targetFrame {
                setFrame(targetFrame, display: true, animate: true)
            }
        }
    }

    // ESC 关闭窗口（对齐 macOS QuickLook 行为）。
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func close() {
        webView.stopLoading()
        super.close()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingIndicator.stopAnimation(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadingIndicator.stopAnimation(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadingIndicator.stopAnimation(nil)
    }

    // 只展示：允许页面加载、重定向和子资源，阻止用户触发的新导航。
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        guard isMainFrame else {
            decisionHandler(.allow)
            return
        }

        switch navigationAction.navigationType {
        case .linkActivated, .formSubmitted, .formResubmitted, .backForward:
            decisionHandler(.cancel)
        case .other, .reload:
            decisionHandler(.allow)
        @unknown default:
            decisionHandler(.allow)
        }
    }

    // MARK: - WKUIDelegate

    // 新窗口/弹窗一律阻止（只展示模式下不允许打开新窗口）。
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}
