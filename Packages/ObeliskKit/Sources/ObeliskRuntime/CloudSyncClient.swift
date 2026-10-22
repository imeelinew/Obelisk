import Foundation
import ObeliskSync
import Observation

@MainActor @Observable
public final class CloudSyncClient {
  private var state: RuntimeSyncState
  @ObservationIgnored private let client: LibraryClient
  public init(client: LibraryClient) throws {
    self.client = client
    state = try client.request(RuntimeRequest(.syncState))
  }
  public var phase: CloudSyncController.Phase { state.phase }
  public var pendingUploadCount: Int { state.pendingUploadCount }
  public var lastSyncedAt: Date? { state.lastSyncedAt }
  public var syncError: String? { state.syncError }
  public var isTestingConnection: Bool { state.isTestingConnection }
  public var isPerformingAction: Bool { state.isPerformingAction }
  public var serverURLString: String { state.serverURLString }
  public var hasAccessKey: Bool { state.hasAccessKey }
  public var isEnabled: Bool { state.isEnabled }
  public var statusTitle: String {
    switch phase {
    case .off: "已关闭"
    case .notConfigured: "未配置"
    case .waiting: "等待同步"
    case .syncing: "正在同步"
    case .synced: "已同步"
    case .failed: "同步失败"
    }
  }
  public func apply(_ data: Data) throws {
    state = try RuntimeCoding.decode(RuntimeSyncState.self, from: data)
  }
  public func savedAccessKey() -> String { (try? client.request(RuntimeRequest(.syncKey))) ?? "" }
  public func setEnabled(_ enabled: Bool) async {
    var r = RuntimeRequest(.syncEnabled)
    r.flag = enabled
    do {
      let _: Bool = try await client.request(r)
      try await refresh()
    } catch { state.syncError = error.localizedDescription }
  }
  public func retry() async {
    do {
      let _: Bool = try await client.request(RuntimeRequest(.syncRetry))
      try await refresh()
    } catch { state.syncError = error.localizedDescription }
  }
  public func testConnection() async -> String? {
    state.isTestingConnection = true
    defer { state.isTestingConnection = false }
    do {
      let result: String? = try await client.request(RuntimeRequest(.syncTest))
      try await refresh()
      return result
    } catch { return error.localizedDescription }
  }
  public func saveService(serverURL: String, accessKey: String) async throws {
    state.isPerformingAction = true
    defer { state.isPerformingAction = false }
    var r = RuntimeRequest(.syncSave)
    r.url = serverURL
    r.title = accessKey
    let _: Bool = try await client.request(r)
    try await refresh()
  }
  private func refresh() async throws {
    state = try await client.request(RuntimeRequest(.syncState))
  }
}
