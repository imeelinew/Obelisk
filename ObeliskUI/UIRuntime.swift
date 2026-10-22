import AppKit
import Foundation
@preconcurrency import KeyboardShortcuts
import ObeliskRuntime
import ObeliskSync
import Observation

@MainActor @Observable
final class UIRuntime {
  static let shared = UIRuntime()
  var model: BookmarksModel?
  var sync: CloudSyncClient?
  var icons: FaviconLoader?
  var windowTopInset: Double = 0
  let addRequest = AddBookmarkRequest()
  @ObservationIgnored private(set) var client: LibraryClient?
  @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
  @ObservationIgnored private var recorderObserver: NSObjectProtocol?
  @ObservationIgnored private var preferences: [String: Any] = [:]
  @ObservationIgnored private var preferenceSave: Task<Void, Never>?
  @ObservationIgnored private var preferenceWriteCount = 0
  @ObservationIgnored var onAction: ((String) -> Void)?
  @ObservationIgnored private var contentRendered = false
  @ObservationIgnored private var presentationReply: (@Sendable (String?) -> Void)?

  func replyWhenContentRendered(_ reply: @escaping @Sendable (String?) -> Void) {
    if contentRendered {
      reply(nil)
    } else {
      presentationReply = reply
    }
  }

  func contentDidRender() {
    guard !contentRendered else { return }
    contentRendered = true
    let reply = presentationReply
    presentationReply = nil
    reply?(nil)
  }

  func connect(_ connection: NSXPCConnection, topInset: Double) throws {
    windowTopInset = topInset
    let client = LibraryClient(connection: connection)
    self.client = client
    let data: Data = try client.request(RuntimeRequest(.preferences))
    try applyPreferences(data)
    KeyboardShortcuts.isEnabled = false
    ObeliskAppDefaults.register()
    sync = try CloudSyncClient(client: client)
    icons = FaviconLoader(rootDirectory: FileManager.default.temporaryDirectory, client: client)
    model = BookmarksModel(store: client)
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
    ) { _ in
      Task { @MainActor in UIRuntime.shared.savePreferences() }
    }
    recorderObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name("KeyboardShortcuts_recorderActiveStatusDidChange"), object: nil,
      queue: .main
    ) { notification in
      let active = notification.userInfo?["isActive"] as? Bool ?? false
      Task { @MainActor in
        guard let client = UIRuntime.shared.client else { return }
        var r = RuntimeRequest(.shortcutMonitoring)
        r.flag = !active
        let _: Bool? = try? await client.request(r)
      }
    }

  }

  func receive(_ event: RuntimeEvent) {
    switch event.kind {
    case .library: model?.reload()
    case .sync: if let data = event.data { try? sync?.apply(data) }
    case .preferences:
      savePreferences()
      if preferenceWriteCount == 0, let data = event.data { try? applyPreferences(data) }
    case .add: addRequest.request(url: nil, title: nil, isHidden: false)
    case .action: if let value = event.value { onAction?(value) }
    case .favicon: icons?.invalidate(key: event.value)
    case .windowTopInset:
      if let data = event.data, let inset = try? RuntimeCoding.decode(Double.self, from: data) {
        windowTopInset = inset
      }
    }
  }

  private func applyPreferences(_ data: Data) throws {
    guard
      let values = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let domain = Bundle.main.bundleIdentifier
    else { throw RuntimeError.invalidRequest }
    preferences = values
    UserDefaults.standard.setPersistentDomain(values, forName: domain)
  }

  func flush() async {
    savePreferences()
    await preferenceSave?.value
  }

  private func savePreferences() {
    guard let client, let domain = Bundle.main.bundleIdentifier else { return }
    let current = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
    let values = current.filter { key, value in
      guard let previous = preferences[key] else { return true }
      return !NSDictionary(dictionary: [key: value]).isEqual(to: [key: previous])
    }
    let removed = preferences.keys.filter { current[$0] == nil }
    guard !values.isEmpty || !removed.isEmpty else { return }
    preferences = current
    guard
      let data = try? PropertyListSerialization.data(
        fromPropertyList: ["values": values, "removed": removed], format: .binary, options: 0)
    else { return }
    var r = RuntimeRequest(.setPreferences)
    r.data = data
    let previous = preferenceSave
    preferenceWriteCount += 1
    preferenceSave = Task {
      await previous?.value
      let _: Bool? = try? await client.request(r)
      preferenceWriteCount -= 1
      if preferenceWriteCount == 0,
        let data: Data = try? await client.request(RuntimeRequest(.preferences))
      {
        try? applyPreferences(data)
      }
    }
  }

  func publishWindowState(_ state: RuntimeWindowState) {
    guard let client, let data = try? RuntimeCoding.encode(state) else { return }
    var r = RuntimeRequest(.windowState)
    r.data = data
    Task { let _: Bool? = try? await client.request(r) }
  }
}
