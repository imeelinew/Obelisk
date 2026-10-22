import Foundation
import ObeliskCore
import ObeliskData
import os

/// Local requests and UI requests use exactly the same storage entry points
/// The UI never opens a database connection or owns a synchronization engine
public final class LibraryClient: @unchecked Sendable {
  private static let localAccess = DispatchQueue(
    label: "com.eli.Obelisk.library-access", qos: .userInitiated)
  private let store: BookmarkStore?
  private let connection: NSXPCConnection?
  public init(store: BookmarkStore) {
    self.store = store
    connection = nil
  }
  public init(connection: NSXPCConnection) {
    self.connection = connection
    store = nil
  }

  public func request<T: Decodable>(_ request: RuntimeRequest, as type: T.Type = T.self) throws -> T
  {
    if let store {
      return try RuntimeCoding.decode(type, from: Self.perform(request, store: store))
    }
    guard let connection else { throw RuntimeError.disconnected }
    let result = OSAllocatedUnfairLock<Result<Data, any Error>>(
      initialState: .failure(RuntimeError.disconnected))
    let proxy =
      connection.synchronousRemoteObjectProxyWithErrorHandler { error in
        result.withLock { $0 = .failure(error) }
      } as? any ObeliskHostEndpoint
    guard let proxy else { throw RuntimeError.disconnected }
    proxy.perform(try RuntimeCoding.encode(request)) { data, message in
      result.withLock { value in
        if let data {
          value = .success(data)
        } else {
          value = .failure(RuntimeError.remote(message ?? "无法连接 Obelisk"))
        }
      }
    }
    return try RuntimeCoding.decode(type, from: result.withLock { try $0.get() })
  }

  public func request<T: Decodable & Sendable>(_ request: RuntimeRequest, as type: T.Type = T.self)
    async throws -> T
  {
    if let store {
      return try RuntimeCoding.decode(type, from: Self.perform(request, store: store))
    }
    guard let connection else { throw RuntimeError.disconnected }
    let data: Data = try await withCheckedThrowingContinuation { continuation in
      // Both the reply and the transport error can arrive during invalidation
      let pending = OSAllocatedUnfairLock<CheckedContinuation<Data, any Error>?>(
        initialState: continuation)
      let finish: @Sendable (Result<Data, any Error>) -> Void = { result in
        pending.withLock { value in
          let current = value
          value = nil
          current?.resume(with: result)
        }
      }
      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ finish(.failure($0)) })
          as? any ObeliskHostEndpoint
      else {
        finish(.failure(RuntimeError.disconnected))
        return
      }
      do {
        proxy.perform(try RuntimeCoding.encode(request)) { data, message in
          if let data {
            finish(.success(data))
          } else {
            finish(.failure(RuntimeError.remote(message ?? "无法连接 Obelisk")))
          }
        }
      } catch { finish(.failure(error)) }
    }
    return try RuntimeCoding.decode(type, from: data)
  }

  public func snapshot() throws -> ObeliskLibrarySnapshot { try request(RuntimeRequest(.snapshot)) }
  @discardableResult public func add(
    title: String, url: String, isHidden: Bool = false, collectionID: UUID? = nil
  ) throws -> Bookmark {
    var r = RuntimeRequest(.add)
    r.title = title
    r.url = url
    r.flag = isHidden
    r.collectionID = collectionID
    return try request(r)
  }
  @discardableResult public func update(_ bookmark: Bookmark) throws -> Bookmark {
    var r = RuntimeRequest(.update)
    r.bookmark = bookmark
    return try request(r)
  }
  public func delete(ids: Set<UUID>) throws { try mutation(.delete, ids: ids) }
  public func restore(ids: Set<UUID>) throws { try mutation(.restore, ids: ids) }
  public func permanentlyDelete(ids: Set<UUID>) throws {
    try mutation(.permanentlyDelete, ids: ids)
  }
  public func setArchived(_ flag: Bool, ids: Set<UUID>) throws {
    var r = RuntimeRequest(.archive)
    r.flag = flag
    r.ids = Array(ids)
    let _: Bool = try request(r)
  }
  @discardableResult public func createCollection(name: String) throws -> BookmarkCollection {
    var r = RuntimeRequest(.createCollection)
    r.title = name
    return try request(r)
  }
  @discardableResult public func renameCollection(id: UUID, name: String) throws
    -> BookmarkCollection
  {
    var r = RuntimeRequest(.renameCollection)
    r.collectionID = id
    r.title = name
    return try request(r)
  }
  public func deleteCollection(id: UUID) throws {
    var r = RuntimeRequest(.deleteCollection)
    r.collectionID = id
    let _: Bool = try request(r)
  }
  @discardableResult public func setCollectionColor(id: UUID, color: BookmarkCollectionColor) throws
    -> BookmarkCollection
  {
    var r = RuntimeRequest(.collectionColor)
    r.collectionID = id
    r.color = color
    return try request(r)
  }
  public func reorderCollections(_ ids: [UUID]) throws {
    var r = RuntimeRequest(.reorderCollections)
    r.ids = ids
    let _: Bool = try request(r)
  }
  public func setCollection(_ id: UUID?, for ids: Set<UUID>) throws {
    var r = RuntimeRequest(.assignCollection)
    r.collectionID = id
    r.ids = Array(ids)
    let _: Bool = try request(r)
  }
  @discardableResult public func applyTitleOptimizations(_ titles: [UUID: String]) throws -> Int {
    var r = RuntimeRequest(.optimizeTitles)
    r.titles = titles
    return try request(r)
  }
  @discardableResult public func applyOriginalTitles(
    _ titles: [UUID: String], forceApplyDisplay: Bool = false
  ) throws -> Int {
    var r = RuntimeRequest(.originalTitles)
    r.titles = titles
    r.flag = forceApplyDisplay
    return try request(r)
  }
  @discardableResult public func markTitleOptimizationFailed(ids: Set<UUID>) throws -> Int {
    var r = RuntimeRequest(.failedTitles)
    r.ids = Array(ids)
    return try request(r)
  }
  @discardableResult public func revertTitleOptimizations(ids: Set<UUID>) throws -> Int {
    var r = RuntimeRequest(.revertTitles)
    r.ids = Array(ids)
    return try request(r)
  }
  public func recordUsage(bookmarkID: UUID, at: Date) throws {
    var r = RuntimeRequest(.usage)
    r.ids = [bookmarkID]
    r.date = at
    let _: Bool = try request(r)
  }
  private func mutation(_ op: RuntimeRequest.Operation, ids: Set<UUID>) throws {
    var r = RuntimeRequest(op)
    r.ids = Array(ids)
    let _: Bool = try request(r)
  }

  public static func perform(_ r: RuntimeRequest, store: BookmarkStore) throws -> Data {
    try localAccess.sync { try performSerialized(r, store: store) }
  }

  private static func performSerialized(_ r: RuntimeRequest, store: BookmarkStore) throws -> Data {
    guard r.ids.count <= 100_000, r.titles.count <= 100_000 else {
      throw RuntimeError.invalidRequest
    }
    switch r.operation {
    case .snapshot: return try RuntimeCoding.encode(store.snapshot())
    case .add:
      return try RuntimeCoding.encode(
        store.add(title: r.title, url: r.url, isHidden: r.flag, collectionID: r.collectionID))
    case .update:
      guard let b = r.bookmark else { throw RuntimeError.invalidRequest }
      return try RuntimeCoding.encode(store.update(b))
    case .delete: try store.delete(ids: Set(r.ids))
    case .restore: try store.restore(ids: Set(r.ids))
    case .permanentlyDelete: try store.permanentlyDelete(ids: Set(r.ids))
    case .archive: try store.setArchived(r.flag, ids: Set(r.ids))
    case .createCollection: return try RuntimeCoding.encode(store.createCollection(name: r.title))
    case .renameCollection:
      guard let id = r.collectionID else { throw RuntimeError.invalidRequest }
      return try RuntimeCoding.encode(store.renameCollection(id: id, name: r.title))
    case .deleteCollection:
      guard let id = r.collectionID else { throw RuntimeError.invalidRequest }
      try store.deleteCollection(id: id)
    case .collectionColor:
      guard let id = r.collectionID, let color = r.color else { throw RuntimeError.invalidRequest }
      return try RuntimeCoding.encode(store.setCollectionColor(id: id, color: color))
    case .reorderCollections: try store.reorderCollections(r.ids)
    case .assignCollection: try store.setCollection(r.collectionID, for: Set(r.ids))
    case .optimizeTitles: return try RuntimeCoding.encode(store.applyTitleOptimizations(r.titles))
    case .originalTitles:
      return try RuntimeCoding.encode(
        store.applyOriginalTitles(r.titles, forceApplyDisplay: r.flag))
    case .failedTitles:
      return try RuntimeCoding.encode(store.markTitleOptimizationFailed(ids: Set(r.ids)))
    case .revertTitles:
      return try RuntimeCoding.encode(store.revertTitleOptimizations(ids: Set(r.ids)))
    case .usage:
      guard r.ids.count == 1, let id = r.ids.first else { throw RuntimeError.invalidRequest }
      try store.database.recordUsage(bookmarkID: id, at: r.date)
    default: throw RuntimeError.invalidRequest
    }
    return try RuntimeCoding.encode(true)
  }
}
