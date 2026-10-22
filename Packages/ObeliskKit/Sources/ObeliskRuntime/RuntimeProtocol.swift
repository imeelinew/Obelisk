import Foundation
import ObeliskCore
import ObeliskData
import ObeliskSync

/// The transport is private to the containing app and its embedded UI extension
/// Only property-list values and canonical domain values cross this boundary
@objc public protocol ObeliskHostEndpoint {
  func perform(_ request: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
}

@objc public protocol ObeliskUIEndpoint {
  func connect(topInset: Double, reply: @escaping @Sendable (String?) -> Void)
  func shutdown(reply: @escaping @Sendable () -> Void)
  func receive(_ event: Data)
}

public struct RuntimeRequest: Codable, Sendable {
  public enum Operation: String, Codable, Sendable {
    case snapshot, add, update, delete, restore, permanentlyDelete, archive
    case createCollection, renameCollection, deleteCollection, collectionColor
    case reorderCollections, assignCollection, optimizeTitles, revertTitles, originalTitles,
      failedTitles, usage
    case syncState, syncEnabled, syncSave, syncRetry, syncTest, syncKey
    case preferences, setPreferences, favicon, refreshFavicon, saveFavicon
    case intelligenceProfiles, saveIntelligenceProfiles, optimize, benchmark
    case shortcutMonitoring, loginEnabled, setLoginEnabled, authenticate, openURL, openPrivateURL,
      relaunch, windowState
  }
  public var isLibraryRequest: Bool {
    switch operation {
    case .snapshot, .add, .update, .delete, .restore, .permanentlyDelete, .archive,
      .createCollection, .renameCollection, .deleteCollection, .collectionColor,
      .reorderCollections, .assignCollection, .optimizeTitles, .revertTitles,
      .originalTitles, .failedTitles, .usage:
      true
    default: false
    }
  }
  public var operation: Operation
  public var ids: [UUID] = []
  public var collectionID: UUID?
  public var bookmark: Bookmark?
  public var title = ""
  public var url = ""
  public var flag = false
  public var date = Date()
  public var color: BookmarkCollectionColor?
  public var titles: [UUID: String] = [:]
  public var data: Data?
  public init(_ operation: Operation) { self.operation = operation }
}

public struct RuntimeEvent: Codable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case library, sync, preferences, add, action, favicon, windowTopInset
  }
  public var kind: Kind
  public var data: Data?
  public var value: String?
  public init(_ kind: Kind, data: Data? = nil, value: String? = nil) {
    self.kind = kind
    self.data = data
    self.value = value
  }
}

public struct RuntimeSyncState: Codable, Sendable {
  public var phase: CloudSyncController.Phase
  public var pendingUploadCount: Int
  public var lastSyncedAt: Date?
  public var syncError: String?
  public var isTestingConnection: Bool
  public var isPerformingAction: Bool
  public var serverURLString: String
  public var hasAccessKey: Bool
  public var isEnabled: Bool
  @MainActor public init(_ controller: CloudSyncController) {
    phase = controller.phase
    pendingUploadCount = controller.pendingUploadCount
    lastSyncedAt = controller.lastSyncedAt
    syncError = controller.syncError
    isTestingConnection = controller.isTestingConnection
    isPerformingAction = controller.isPerformingAction
    serverURLString = controller.serverURLString
    hasAccessKey = controller.hasAccessKey
    isEnabled = controller.isEnabled
  }
}

public struct RuntimeWindowState: Codable, Sendable {
  public var title: String
  public var canAdd: Bool
  public var addIsHidden: Bool
  public var canEmptyTrash: Bool
  public var showsTrash: Bool
  public var transparent: Bool
  public var detailLeading: Double
  public init(
    title: String, canAdd: Bool, addIsHidden: Bool, canEmptyTrash: Bool, showsTrash: Bool,
    transparent: Bool, detailLeading: Double
  ) {
    self.title = title
    self.canAdd = canAdd
    self.addIsHidden = addIsHidden
    self.canEmptyTrash = canEmptyTrash
    self.showsTrash = showsTrash
    self.transparent = transparent
    self.detailLeading = detailLeading
  }
}

public enum RuntimeError: LocalizedError {
  case disconnected
  case invalidRequest
  case remote(String)
  public var errorDescription: String? {
    switch self {
    case .disconnected: "无法连接 Obelisk"
    case .invalidRequest: "无效的应用请求"
    case .remote(let message): message
    }
  }
}

public enum RuntimeCoding {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    try JSONEncoder().encode(value)
  }
  public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try JSONDecoder().decode(type, from: data)
  }
}

public struct RuntimeFavicon: Codable, Sendable {
  public var data: Data?
  public var shouldFetch: Bool
  public init(data: Data?, shouldFetch: Bool) {
    self.data = data
    self.shouldFetch = shouldFetch
  }
}
