import AppKit
import ExtensionFoundation
import ExtensionKit
import ObeliskRuntime
import SwiftUI

@main
final class BookmarkUIExtension: AppExtension {
  required init() {}
  @AppExtensionPoint.Bind var extensionPoint: AppExtensionPoint {
    AppExtensionPoint.Identifier(host: "com.eli.Obelisk", name: "BookmarkManager")
  }
  var configuration: AppExtensionSceneConfiguration {
    AppExtensionSceneConfiguration(
      PrimitiveAppExtensionScene(id: "manager") {
        BookmarkUIRoot()
      } onConnection: { connection in
        let bridge = UIConnection(connection: connection)
        connection.exportedInterface = NSXPCInterface(with: ObeliskUIEndpoint.self)
        connection.exportedObject = bridge
        connection.remoteObjectInterface = NSXPCInterface(with: ObeliskHostEndpoint.self)
        connection.resume()
        return true
      }
    )
  }
}

private struct BookmarkUIRoot: View {
  @State private var runtime = UIRuntime.shared
  var body: some View {
    Group {
      if let model = runtime.model, let sync = runtime.sync, let icons = runtime.icons {
        BookmarkUIContent(
          rootView: BookmarkManagerView(
            model: model, cloudSync: sync, faviconLoader: icons, addRequest: runtime.addRequest),
          topInset: runtime.windowTopInset)
      } else {
        Color(nsColor: .textBackgroundColor)
      }
    }
  }
}

/// Apply the containing window's safe area at the AppKit hosting boundary
/// NavigationSplitView's native sidebar does not inherit SwiftUI safeAreaPadding
private struct BookmarkUIContent: NSViewRepresentable {
  let rootView: BookmarkManagerView
  let topInset: CGFloat

  func makeNSView(context: Context) -> NSHostingView<BookmarkManagerView> {
    let view = NSHostingView(rootView: rootView)
    view.sizingOptions = []
    view.additionalSafeAreaInsets.top = topInset
    return view
  }

  func updateNSView(_ view: NSHostingView<BookmarkManagerView>, context: Context) {
    view.rootView = rootView
    if view.additionalSafeAreaInsets.top != topInset {
      view.additionalSafeAreaInsets.top = topInset
    }
  }
}

private final class UIConnection: NSObject, ObeliskUIEndpoint, @unchecked Sendable {
  let connection: NSXPCConnection
  init(connection: NSXPCConnection) { self.connection = connection }
  func connect(topInset: Double, reply: @escaping @Sendable (String?) -> Void) {
    Task { @MainActor in
      do {
        try UIRuntime.shared.connect(connection, topInset: topInset)
        reply(nil)
      } catch { reply(error.localizedDescription) }
    }
  }
  func shutdown(reply: @escaping @Sendable () -> Void) {
    Task { @MainActor in
      await UIRuntime.shared.flush()
      reply()
      // A completed UI session has no work to keep alive in this process
      DispatchQueue.main.async { exit(EXIT_SUCCESS) }
    }
  }
  func receive(_ data: Data) {
    Task { @MainActor in
      guard let event = try? RuntimeCoding.decode(RuntimeEvent.self, from: data) else { return }
      UIRuntime.shared.receive(event)
    }
  }
}
