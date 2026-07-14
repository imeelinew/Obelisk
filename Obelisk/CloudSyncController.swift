import Foundation
import ObeliskData
import ObeliskSync
import Observation
import PowerSync

@MainActor
@Observable
final class CloudSyncController {
    static let enabledKey = "cloudSyncEnabled"
    static let accountEmailKey = "cloudSyncAccountEmail"

    enum Phase: Equatable {
        case off
        case authenticationRequired
        case connecting
        case uploading
        case downloading
        case syncing
        case synced
        case offline
        case failed
    }

    private(set) var isEnabled = false
    private(set) var accountEmail: String?
    private(set) var pendingUploadCount = 0
    private(set) var connected = false
    private(set) var connecting = false
    private(set) var uploading = false
    private(set) var downloading = false
    private(set) var lastSyncedAt: Date?
    private(set) var syncError: String?
    private(set) var apiAvailable: Bool?
    private(set) var isPerformingAction = false
    private(set) var isTestingConnection = false

    let apiHost: String
    let powerSyncHost: String

    private let database: ObeliskDatabase
    private let authClient: ObeliskAuthClient
    private let defaults: UserDefaults
    private var session: ObeliskAuthSession?
    private var statusTask: Task<Void, Never>?
    private var pendingCountTask: Task<Void, Never>?

    init(
        database: ObeliskDatabase,
        authClient: ObeliskAuthClient,
        defaults: UserDefaults = .standard
    ) {
        self.database = database
        self.authClient = authClient
        self.defaults = defaults
        self.apiHost = authClient.configuration.apiURL.host
            ?? authClient.configuration.apiURL.absoluteString
        self.powerSyncHost = authClient.configuration.powerSyncURL.host
            ?? authClient.configuration.powerSyncURL.absoluteString
    }

    var phase: Phase {
        if !isEnabled { return .off }
        if syncError != nil { return .failed }
        if !isAuthenticated { return .authenticationRequired }
        if connecting { return .connecting }
        if uploading && downloading { return .syncing }
        if uploading { return .uploading }
        if downloading { return .downloading }
        if connected { return .synced }
        return .offline
    }

    var isAuthenticated: Bool {
        session != nil
    }

    var statusTitle: String {
        switch phase {
        case .off: return "已关闭"
        case .authenticationRequired: return "需要登录"
        case .connecting: return "正在连接"
        case .uploading: return "正在上传"
        case .downloading: return "正在下载"
        case .syncing: return "正在同步"
        case .synced: return "已同步"
        case .offline: return "等待连接"
        case .failed: return "同步失败"
        }
    }

    var apiStatusTitle: String {
        if isTestingConnection { return "测试中…" }
        switch apiAvailable {
        case true: return "可用"
        case false: return "不可用"
        case nil: return "未检测"
        }
    }

    var powerSyncStatusTitle: String {
        if !isEnabled { return "未启用" }
        if connecting { return "连接中" }
        return connected ? "已连接" : "未连接"
    }

    func start() async {
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        observeStatus()
        observePendingUploadCount()

        guard isEnabled else { return }
        await loadSession()
        if session != nil {
            await connect()
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        syncError = nil

        if enabled {
            if session == nil {
                await loadSession()
            }
            if session != nil {
                await connect()
            }
        } else {
            await disconnect()
        }
    }

    func login(email: String, password: String) async throws {
        isPerformingAction = true
        syncError = nil
        defer { isPerformingAction = false }

        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let authenticated = try await authClient.login(email: normalizedEmail, password: password)
        do {
            try database.bindToCloudAccount(authenticated.accountID)
        } catch {
            try? await authClient.signOut()
            throw error
        }
        session = authenticated
        accountEmail = normalizedEmail
        defaults.set(normalizedEmail, forKey: Self.accountEmailKey)
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
        apiAvailable = true
        await connect()
    }

    func signOut() async throws {
        isPerformingAction = true
        defer { isPerformingAction = false }

        await disconnect()
        try await authClient.signOut()
        session = nil
        accountEmail = nil
        isEnabled = false
        syncError = nil
        apiAvailable = nil
        defaults.set(false, forKey: Self.enabledKey)
        defaults.removeObject(forKey: Self.accountEmailKey)
    }

    func syncNow() async {
        guard isEnabled, session != nil else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        syncError = nil
        await disconnect()
        await connect()
    }

    func testConnection() async {
        isTestingConnection = true
        defer { isTestingConnection = false }
        do {
            try await authClient.testAPIConnection()
            apiAvailable = true
            syncError = nil
            if isEnabled, session != nil, !connected {
                await connect()
            }
        } catch {
            apiAvailable = false
            syncError = error.localizedDescription
        }
    }

    private func connect() async {
        guard let session else { return }
        do {
            try database.bindToCloudAccount(session.accountID)
            let connector = ObeliskPowerSyncConnector(auth: authClient)
            try await database.powerSync.connect(connector: connector)
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func loadSession() async {
        do {
            session = try await authClient.restoreSession()
            if session != nil {
                accountEmail = defaults.string(forKey: Self.accountEmailKey)
            }
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func disconnect() async {
        do {
            try await database.powerSync.disconnect()
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func observeStatus() {
        statusTask?.cancel()
        let status = database.powerSync.currentStatus
        statusTask = Task { [weak self] in
            for await update in status.asFlow() {
                guard !Task.isCancelled else { return }
                self?.connected = update.connected
                self?.connecting = update.connecting
                self?.uploading = update.uploading
                self?.downloading = update.downloading
                self?.lastSyncedAt = update.lastSyncedAt
                if let error = update.anyError {
                    self?.syncError = String(describing: error)
                } else if update.connected {
                    self?.apiAvailable = true
                    self?.syncError = nil
                }
            }
        }
    }

    private func observePendingUploadCount() {
        pendingCountTask?.cancel()
        let powerSync = database.powerSync
        pendingCountTask = Task { [weak self] in
            do {
                let changes = try powerSync.watch(
                    sql: "SELECT COUNT(*) FROM ps_crud",
                    parameters: []
                ) { cursor in
                    Int(try cursor.getInt64(index: 0))
                }
                for try await values in changes {
                    guard !Task.isCancelled else { return }
                    self?.pendingUploadCount = values.first ?? 0
                }
            } catch {
                self?.syncError = error.localizedDescription
            }
        }
    }
}
