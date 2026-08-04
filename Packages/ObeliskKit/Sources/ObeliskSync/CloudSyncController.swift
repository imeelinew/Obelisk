import Foundation
import Network
import Observation
import ObeliskData

/// Push/pull sync engine over the Worker API.
///
/// Local writes land in `outbox`; the engine uploads full row state, the
/// server merges per-field HLC versions, and pulls apply remote pages back
/// with the same merge rules. Every row is handled independently, so one bad
/// row can never block the queue. All triggers funnel into one serialized
/// sync pass: outbox growth, a 30-second timer, app activation, and network
/// recovery.
@MainActor
@Observable
public final class CloudSyncController {
    public enum Phase: Equatable, Sendable {
        case off
        case notConfigured
        case waiting
        case syncing
        case synced
        case failed
    }

    public private(set) var phase: Phase = .off
    public private(set) var pendingUploadCount = 0
    public private(set) var lastSyncedAt: Date?
    public private(set) var syncError: String?
    public private(set) var isTestingConnection = false
    public private(set) var isPerformingAction = false
    public private(set) var serverURLString: String
    public private(set) var hasAccessKey = false

    public var isEnabled: Bool {
        defaults.bool(forKey: Self.enabledKey)
    }

    public var isConfigured: Bool {
        serverURL != nil && hasAccessKey
    }

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

    private static let enabledKey = "cloudSyncEnabled"
    private static let serverURLKey = "cloudSyncServerURL"
    private static let lastSyncedKey = "cloudSyncLastSyncedAt"

    private let database: ObeliskDatabase
    private let defaults: UserDefaults
    private let accessKeyStore: any SyncAccessKeyStoring
    private let engine: SyncEngine

    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var wantsAnotherPass = false
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var networkWasSatisfied = true

    public init(
        database: ObeliskDatabase,
        defaults: UserDefaults = .standard,
        accessKeyStore: any SyncAccessKeyStoring = SyncAccessKeyStore()
    ) {
        self.database = database
        self.defaults = defaults
        self.accessKeyStore = accessKeyStore
        self.engine = SyncEngine(database: database)
        self.serverURLString = defaults.string(forKey: Self.serverURLKey) ?? ""
        let lastSynced = defaults.double(forKey: Self.lastSyncedKey)
        self.lastSyncedAt = lastSynced > 0 ? Date(timeIntervalSince1970: lastSynced) : nil
    }

    private var serverURL: URL? {
        let trimmed = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            let url = URL(string: trimmed),
            url.scheme == "https" || url.scheme == "http"
        else {
            return nil
        }
        return url
    }

    // MARK: - Lifecycle

    public func start() async {
        hasAccessKey = (try? accessKeyStore.load()) != nil
        pendingUploadCount = (try? database.loadPendingUploadCount()) ?? 0
        await reloadEngineCredentials()
        refreshPhase()
        startObservingOutbox()
        startNetworkMonitor()
        applyEnabledState()
    }

    public func setEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Self.enabledKey)
        syncError = nil
        applyEnabledState()
    }

    /// Saves the service address and access key, then starts a full sync.
    /// An empty key keeps the previously saved one.
    public func saveService(serverURL: String, accessKey: String) async throws {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmedURL),
            url.scheme == "https" || url.scheme == "http"
        else {
            throw ObeliskSyncError.server("服务地址必须是 http(s) URL")
        }
        let effectiveKey = trimmedKey.isEmpty ? ((try? accessKeyStore.load()) ?? "") : trimmedKey
        guard !effectiveKey.isEmpty else {
            throw ObeliskSyncError.notConfigured
        }

        isPerformingAction = true
        defer { isPerformingAction = false }

        // Validate address and key before persisting anything. A cursor past
        // any real sequence returns an empty page cheaply.
        _ = try await ObeliskSyncClient(baseURL: url, accessKey: effectiveKey)
            .changes(since: Int64(9_007_199_254_740_991))

        defaults.set(trimmedURL, forKey: Self.serverURLKey)
        serverURLString = trimmedURL
        try accessKeyStore.save(effectiveKey)
        hasAccessKey = true
        syncError = nil
        try database.resetSyncCursor()
        await reloadEngineCredentials()
        applyEnabledState()
    }

    public func resume() {
        guard isEnabled, isConfigured else { return }
        requestSync()
    }

    public func retry() async {
        syncError = nil
        refreshPhase()
        requestSync()
    }

    public func testConnection() async {
        guard let url = serverURL else {
            syncError = ObeliskSyncError.notConfigured.errorDescription
            return
        }
        isTestingConnection = true
        defer { isTestingConnection = false }
        do {
            let key = (try? accessKeyStore.load()) ?? ""
            let client = ObeliskSyncClient(baseURL: url, accessKey: key)
            try await client.testConnection()
            // Health check passes without auth; exercise the key as well.
            _ = try await client.changes(since: Int64(9_007_199_254_740_991))
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
        refreshPhase()
    }

    // MARK: - Engine wiring

    private func applyEnabledState() {
        refreshPhase()
        guard isEnabled, isConfigured else {
            timerTask?.cancel()
            timerTask = nil
            return
        }
        if (try? database.syncCursor()) ?? 0 == 0 {
            // First contact with this server: upload the complete local
            // library so the merge can converge both sides.
            try? database.enqueueFullPush()
        }
        startTimer()
        requestSync()
    }

    private func reloadEngineCredentials() async {
        let client: ObeliskSyncClient?
        if let url = serverURL, let key = try? accessKeyStore.load() {
            client = ObeliskSyncClient(baseURL: url, accessKey: key)
        } else {
            client = nil
        }
        await engine.setClient(client)
    }

    private func startObservingOutbox() {
        observationTask?.cancel()
        observationTask = Task { [weak self, database] in
            do {
                for try await count in database.pendingUploadCounts() {
                    guard let self else { return }
                    self.pendingUploadCount = count
                    self.refreshPhase()
                    if count > 0, self.isEnabled, self.isConfigured {
                        self.requestSync()
                    }
                }
            } catch {
                // Observation only stops when the database closes.
            }
        }
    }

    private func startTimer() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.isEnabled, self.isConfigured else { continue }
                self.requestSync()
            }
        }
    }

    private func startNetworkMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let recovered = satisfied && !self.networkWasSatisfied
                self.networkWasSatisfied = satisfied
                if recovered, self.isEnabled, self.isConfigured {
                    self.requestSync()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "obelisk.sync.network-monitor"))
    }

    private func requestSync() {
        guard isEnabled, isConfigured else { return }
        if syncTask != nil {
            wantsAnotherPass = true
            return
        }
        syncTask = Task { [weak self] in
            await self?.runSyncLoop()
        }
    }

    private func runSyncLoop() async {
        defer {
            syncTask = nil
            refreshPhase()
        }
        repeat {
            wantsAnotherPass = false
            phase = .syncing
            let outcome = await engine.performSync()
            pendingUploadCount = (try? database.loadPendingUploadCount()) ?? pendingUploadCount
            switch outcome {
            case .success(let rejectedMessage):
                lastSyncedAt = Date()
                defaults.set(lastSyncedAt!.timeIntervalSince1970, forKey: Self.lastSyncedKey)
                syncError = rejectedMessage
            case .failure(let message):
                syncError = message
            case .skipped:
                break
            }
            refreshPhase()
        } while wantsAnotherPass && isEnabled
    }

    private func refreshPhase() {
        if !isEnabled {
            phase = .off
        } else if !isConfigured {
            phase = .notConfigured
        } else if syncTask != nil {
            phase = .syncing
        } else if syncError != nil {
            phase = .failed
        } else if pendingUploadCount > 0 {
            phase = .waiting
        } else if lastSyncedAt != nil {
            phase = .synced
        } else {
            phase = .waiting
        }
    }
}

/// Off-main-actor worker that performs one full push + pull pass. Database
/// calls are synchronous SQLite operations and must not block the UI.
actor SyncEngine {
    enum Outcome: Sendable {
        case success(rejectedMessage: String?)
        case failure(String)
        case skipped
    }

    private let database: ObeliskDatabase
    private var client: ObeliskSyncClient?

    init(database: ObeliskDatabase) {
        self.database = database
    }

    func setClient(_ client: ObeliskSyncClient?) {
        self.client = client
    }

    func performSync() async -> Outcome {
        guard let client else { return .skipped }
        do {
            let rejectedMessage = try await push(client)
            try await pull(client)
            return .success(rejectedMessage: rejectedMessage)
        } catch is CancellationError {
            return .skipped
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func push(_ client: ObeliskSyncClient) async throws -> String? {
        var rejectedMessage: String?
        // Rows rejected in this pass are skipped until the next sync so a
        // failing row is attempted at most once per pass.
        var rejectedKeys = Set<String>()
        while true {
            let batch = try database.outboxBatch()
                .filter { !rejectedKeys.contains("\($0.tableName)/\($0.rowID)") }
            guard !batch.isEmpty else { break }
            var progressed = false

            var rowEntries: [SyncOutboxEntry] = []
            var payloads: [SyncPushRow] = []
            for entry in batch {
                if entry.tableName == ObeliskDatabase.historyOutboxTable {
                    let records = try database.localHistoryRecords()
                    try await client.reconcileHistory(deviceID: database.deviceID, records: records)
                    try database.completeOutboxEntries([entry])
                    progressed = true
                } else if let payload = try database.pushRow(for: entry) {
                    rowEntries.append(entry)
                    payloads.append(payload)
                } else {
                    // Row vanished locally; nothing to upload.
                    try database.completeOutboxEntries([entry])
                    progressed = true
                }
            }

            if !payloads.isEmpty {
                let response = try await client.push(payloads)
                var resultsByKey: [String: ObeliskSyncClient.PushRowResult] = [:]
                for result in response.results {
                    resultsByKey["\(result.table)/\(result.id.lowercased())"] = result
                }
                var completed: [SyncOutboxEntry] = []
                for entry in rowEntries {
                    guard let result = resultsByKey["\(entry.tableName)/\(entry.rowID)"] else {
                        continue
                    }
                    if result.isApplied {
                        completed.append(entry)
                        progressed = true
                    } else {
                        let message = result.error ?? "row rejected"
                        try database.recordOutboxFailure(entry, message: message)
                        rejectedKeys.insert("\(entry.tableName)/\(entry.rowID)")
                        rejectedMessage = "部分数据被服务器拒绝：\(message)"
                    }
                }
                try database.completeOutboxEntries(completed)
            }

            guard progressed else { break }
        }
        return rejectedMessage
    }

    private func pull(_ client: ObeliskSyncClient) async throws {
        var cursor = try database.syncCursor()
        while true {
            let page = try await client.changes(since: cursor)
            try database.applyRemoteChanges(page)
            try database.setSyncCursor(page.cursor)
            cursor = page.cursor
            guard page.hasMore else { break }
        }
    }
}
