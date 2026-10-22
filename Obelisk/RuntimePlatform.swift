import AppKit
import ObeliskRuntime

@MainActor
enum RuntimePlatform {
  @discardableResult static func open(_ url: URL) async -> Bool {
    #if OBELISK_UI
      var r = RuntimeRequest(.openURL)
      r.url = url.absoluteString
      return (try? await UIRuntime.shared.client?.request(r)) ?? false
    #else
      return NSWorkspace.shared.open(url)
    #endif
  }
}
