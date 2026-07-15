import Foundation
import ObeliskData
import Observation
import PowerSync

@MainActor
@Observable
public final class CloudSyncController {
    public static let enabledKey = "cloudSyncEnabled"
    public static let accountEmailKey = "cloudSyncAccountEmail"

    public enum Phase: Equatable {
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

    public private(set) var isEnabled = false
    public private(set) var accountEmail: String?
    public private(set) var pendingUploadCount = 0
    public private(set) var connected = false
    public private(set) var connecting = false
    public private(set) var uploading = false
    public private(set) var downloading = false
    public private(set) var lastSyncedAt: Date?
    public private(set) var syncError: String?
    public private(set) var apiAvailable: Bool?
    public private(set) var isPerformingAction = false
    public private(set) var isTestingConnection = false

    public let apiHost: String
    public let powerSyncHost: String

    private let database: ObeliskDatabase
    private let authClient: ObeliskAuthClient
    private let defaults: UserDefaults
    private var session: ObeliskAuthSession?
    private var statusTask: Task<Void, Never>?
    private var pendingCountTask: Task<Void, Never>?
    private var connectionStarted = false

    public init(
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

    public var phase: Phase {
        if !isEnabled { return .off }
        if syncError != nil { return .failed }
        if !isAuthenticated { return .authenticationRequired }
        if connecting { return .connecting }
        if uploading && downloading { return .syncing }
        if uploading { return .uploading }
        if downloading { return .downloading }
        if connected && pendingUploadCount > 0 { return .uploading }
        if connected { return .synced }
        return .offline
    }

    public var isAuthenticated: Bool {
        session != nil
    }

    public var statusTitle: String {
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

    public var apiStatusTitle: String {
        if isTestingConnection { return "测试中…" }
        switch apiAvailable {
        case true: return "可用"
        case false: return "不可用"
        case nil: return "未检测"
        }
    }

    public var powerSyncStatusTitle: String {
        if !isEnabled { return "未启用" }
        if connecting { return "连接中" }
        return connected ? "已连接" : "未连接"
    }

    public func start() async {
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        observeStatus()
        observePendingUploadCount()

        guard isEnabled else { return }
        await loadSession()
        if session != nil {
            await connectIfNeeded()
        }
    }

    public func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        syncError = nil

        if enabled {
            if session == nil {
                await loadSession()
            }
            if session != nil {
                await connectIfNeeded()
            }
        } else {
            await disconnect()
        }
    }

    public func login(email: String, password: String) async throws {
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
        await connectIfNeeded()
    }

    public func signOut() async throws {
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

    public func resume() async {
        guard isEnabled else { return }
        if session == nil {
            await loadSession()
        }
        guard session != nil else { return }
        syncError = nil
        await connectIfNeeded()
    }

    public func retry() async {
        guard isEnabled else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        await resume()
    }

    @discardableResult
    public func finishPendingUploads(timeout: Duration = .seconds(20)) async -> Bool {
        guard isEnabled else { return true }
        if session == nil {
            await loadSession()
        }
        guard session != nil else { return false }
        await resume()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        do {
            while clock.now < deadline {
                let count = try database.loadPendingUploadCount()
                pendingUploadCount = count
                if count == 0 { return true }
                try await Task.sleep(for: .milliseconds(100))
            }
            pendingUploadCount = try database.loadPendingUploadCount()
            return pendingUploadCount == 0
        } catch is CancellationError {
            return false
        } catch {
            syncError = error.localizedDescription
            return false
        }
    }

    public func testConnection() async {
        isTestingConnection = true
        defer { isTestingConnection = false }
        do {
            try await authClient.testAPIConnection()
            apiAvailable = true
            syncError = nil
            if isEnabled, session != nil {
                await connectIfNeeded()
            }
        } catch {
            apiAvailable = false
            syncError = error.localizedDescription
        }
    }

    private func connectIfNeeded() async {
        guard let session, !connectionStarted else { return }
        connectionStarted = true
        do {
            try database.bindToCloudAccount(session.accountID)
            let connector = ObeliskPowerSyncConnector(auth: authClient)
            try await database.powerSync.connect(connector: connector)
        } catch {
            connectionStarted = false
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
            connectionStarted = false
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
                if let error = update.anyError, !Self.isExpectedCancellation(error) {
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
        let database = database
        pendingCountTask = Task { [weak self] in
            do {
                for try await count in database.pendingUploadCounts() {
                    guard !Task.isCancelled else { return }
                    self?.pendingUploadCount = count
                }
            } catch {
                self?.syncError = error.localizedDescription
            }
        }
    }

    private static func isExpectedCancellation(_ error: Any) -> Bool {
        if error is CancellationError {
            return true
        }
        guard let error = error as? NSError else { return false }
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }
}
