import AppKit
@preconcurrency import KeyboardShortcuts
import LocalAuthentication
import ObeliskCore
import ObeliskData
import ObeliskRuntime
import ObeliskSync
import Observation
import ServiceManagement
import os

@MainActor
final class RuntimeHost: NSObject, ObeliskHostEndpoint {
  nonisolated let store: BookmarkStore
  nonisolated private let requests = DispatchQueue(
    label: "com.eli.Obelisk.host-requests", qos: .userInitiated)
  nonisolated private let syncSnapshot: OSAllocatedUnfairLock<Data>
  let sync: CloudSyncController
  let icons: FaviconLoader
  var onWindowState: ((RuntimeWindowState) -> Void)?
  var onRelaunch: (() -> Void)?
  var send: ((RuntimeEvent) -> Void)?
  private var databaseWatch: Task<Void, Never>?
  private var syncTracking = true
  private var optimizationTail: Task<TitleOptimizationOutcome, Never>?

  init(store: BookmarkStore, sync: CloudSyncController, icons: FaviconLoader) {
    self.store = store
    syncSnapshot = OSAllocatedUnfairLock(
      initialState: (try? RuntimeCoding.encode(RuntimeSyncState(sync))) ?? Data())
    self.sync = sync
    self.icons = icons
    super.init()
    observeSync()
    databaseWatch = Task { [weak self, database = store.database] in
      do {
        for try await _ in database.libraryChanges() {
          guard !Task.isCancelled else { return }
          self?.send?(RuntimeEvent(.library))
        }
      } catch {
        Logger(subsystem: "com.eli.Obelisk", category: "Runtime").error(
          "Library observation stopped: \(error.localizedDescription)")
      }
    }
  }

  func stop() {
    databaseWatch?.cancel()
    syncTracking = false
  }

  nonisolated func perform(_ data: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
    guard data.count <= 16 * 1_024 * 1_024 else {
      reply(nil, "无效的应用请求")
      return
    }
    do {
      let request = try RuntimeCoding.decode(RuntimeRequest.self, from: data)
      if request.isLibraryRequest {
        requests.async { [self] in
          do {
            if request.operation == .add || request.operation == .update {
              let url = request.bookmark?.url ?? request.url
              let hidden = request.bookmark?.isHidden ?? request.flag
              guard hidden || !HiddenBookmarkKeywordExclusion.matches(url: url) else {
                throw RuntimeError.remote(HiddenBookmarkKeywordExclusion.blockedBookmarkMessage)
              }
            }
            reply(try LibraryClient.perform(request, store: store), nil)
            if request.operation != .snapshot { Task { @MainActor in sync.resume() } }
          } catch { reply(nil, error.localizedDescription) }
        }
        return
      }
      // These synchronous reads do not require the host's AppKit run loop
      // Remote menu tracking can temporarily occupy that run loop
      switch request.operation {
      case .syncState:
        reply(syncSnapshot.withLock { $0 }, nil)
        return
      case .syncKey:
        reply(try RuntimeCoding.encode(try SyncAccessKeyStore().load() ?? ""), nil)
        return
      case .preferences:
        reply(try RuntimeCoding.encode(Self.preferencesData()), nil)
        return
      case .intelligenceProfiles:
        reply(try RuntimeCoding.encode(LLMConfigStore().loadProfiles()), nil)
        return
      case .saveIntelligenceProfiles:
        guard let data = request.data else { throw RuntimeError.invalidRequest }
        try LLMConfigStore().save(RuntimeCoding.decode(LLMProfilesSettings.self, from: data))
        reply(try RuntimeCoding.encode(true), nil)
        return
      case .loginEnabled:
        reply(try RuntimeCoding.encode(SMAppService.mainApp.status == .enabled), nil)
        return
      default: break
      }
      Task { @MainActor in
        do { reply(try await handle(request), nil) } catch {
          reply(nil, error.localizedDescription)
        }
      }
    } catch { reply(nil, error.localizedDescription) }
  }

  private func observeSync() {
    guard syncTracking else { return }
    let state = withObservationTracking {
      RuntimeSyncState(sync)
    } onChange: { [weak self] in
      Task { @MainActor in self?.observeSync() }
    }
    if let data = try? RuntimeCoding.encode(state) {
      syncSnapshot.withLock { $0 = data }
      send?(RuntimeEvent(.sync, data: data))
    }
  }

  func optimize(ids: Set<UUID>) async -> TitleOptimizationOutcome {
    let previous = optimizationTail
    let task = Task { [self] in
      _ = await previous?.value
      let model = BookmarksModel(store: LibraryClient(store: store))
      return await model.optimizeTitleDetails(bookmarkIds: ids)
    }
    optimizationTail = task
    let result = await task.value
    return result
  }

  private func handle(_ r: RuntimeRequest) async throws -> Data {
    switch r.operation {
    case .syncEnabled: await sync.setEnabled(r.flag)
    case .syncSave: try await sync.saveService(serverURL: r.url, accessKey: r.title)
    case .syncRetry: await sync.retry()
    case .syncTest: return try RuntimeCoding.encode(await sync.testConnection())
    case .setPreferences:
      guard let data = r.data,
        let patch = try PropertyListSerialization.propertyList(from: data, format: nil)
          as? [String: Any],
        let values = patch["values"] as? [String: Any], let removed = patch["removed"] as? [String]
      else { throw RuntimeError.invalidRequest }
      let protected = ["cloudSyncEnabled", "cloudSyncServerURL", "cloudSyncLastSyncedAt"]
      let shortcutNames: [KeyboardShortcuts.Name] = [
        .addBookmark, .addHiddenBookmark, .toggleHiddenBookmarksSidebar,
      ]
      for (key, value) in values
      where !protected.contains(key) && !key.hasPrefix("NS") && !key.hasPrefix("SU") {
        if let name = shortcutNames.first(where: { key == "KeyboardShortcuts_" + $0.rawValue }) {
          if let string = value as? String, let data = string.data(using: .utf8) {
            KeyboardShortcuts.setShortcut(
              try JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: data), for: name)
          } else {
            KeyboardShortcuts.setShortcut(nil, for: name)
          }
        } else {
          UserDefaults.standard.set(value, forKey: key)
        }
      }
      for key in removed
      where !protected.contains(key) && !key.hasPrefix("NS") && !key.hasPrefix("SU") {
        if let name = shortcutNames.first(where: { key == "KeyboardShortcuts_" + $0.rawValue }) {
          KeyboardShortcuts.reset(name)
        } else {
          UserDefaults.standard.removeObject(forKey: key)
        }
      }
    case .shortcutMonitoring: KeyboardShortcuts.isEnabled = r.flag
    case .favicon:
      return try RuntimeCoding.encode(icons.cachedData(for: r.url))
    case .refreshFavicon: icons.invalidateDiskData(for: r.url)
    case .saveFavicon:
      if let data = r.data {
        try icons.storeDownloadedData(data, key: r.title)
      } else {
        try icons.storeFailure(key: r.title)
      }
    case .optimize: return try RuntimeCoding.encode(await optimize(ids: Set(r.ids)))
    case .benchmark:
      guard let data = r.data else { throw RuntimeError.invalidRequest }
      _ = try await TitleOptimizer().benchmark(
        config: RuntimeCoding.decode(LLMConfig.self, from: data))
    case .setLoginEnabled: try await LoginItemController.setEnabled(r.flag)
    case .authenticate:
      return try RuntimeCoding.encode(await AuthenticationGate.authenticate(reason: r.title))
    case .openURL:
      guard let url = URL(string: r.url),
        ["http", "https", "x-apple.systempreferences"].contains(url.scheme?.lowercased() ?? "")
      else { throw RuntimeError.invalidRequest }
      return try RuntimeCoding.encode(NSWorkspace.shared.open(url))
    case .openPrivateURL:
      return try RuntimeCoding.encode(await PrivateBrowserOpener.openIncognito(urlString: r.url))
    case .relaunch: onRelaunch?()
    case .windowState:
      guard let data = r.data else { throw RuntimeError.invalidRequest }
      onWindowState?(try RuntimeCoding.decode(RuntimeWindowState.self, from: data))
    default: throw RuntimeError.invalidRequest
    }
    return try RuntimeCoding.encode(true)
  }

  nonisolated static func preferencesData() -> Data {
    let defaults = UserDefaults.standard
    var domain = defaults.persistentDomain(forName: "com.eli.Obelisk") ?? [:]
    for (key, value) in defaults.volatileDomain(forName: UserDefaults.argumentDomain) {
      domain[key] = value
    }
    return
      (try? PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0))
      ?? Data()
  }
}
