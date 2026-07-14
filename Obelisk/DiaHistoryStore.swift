import CryptoKit
import Foundation
import ObeliskData
import SQLite3

enum BrowserHistoryBrowser: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case dia
    case chrome
    case edge
    case brave
    case arc
    case vivaldi
    case opera
    case chromium
    case firefox
    case safari

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dia: return "Dia"
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave"
        case .arc: return "Arc"
        case .vivaldi: return "Vivaldi"
        case .opera: return "Opera"
        case .chromium: return "Chromium"
        case .firefox: return "Firefox"
        case .safari: return "Safari"
        }
    }

    var optionTitle: String {
        isImplemented ? title : "\(title)（尚未完成）"
    }

    var fallbackSystemImage: String {
        switch self {
        case .dia: return "sparkles"
        case .chrome, .chromium: return "circle.hexagongrid"
        case .edge: return "wave.3.right"
        case .brave: return "shield"
        case .arc: return "arc.forward"
        case .vivaldi: return "v.circle"
        case .opera: return "o.circle"
        case .firefox: return "flame"
        case .safari: return "safari"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .dia: return "company.thebrowser.dia"
        case .chrome: return "com.google.Chrome"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        case .arc: return "company.thebrowser.Browser"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .opera: return "com.operasoftware.Opera"
        case .chromium: return "org.chromium.Chromium"
        case .firefox: return "org.mozilla.firefox"
        case .safari: return "com.apple.Safari"
        }
    }

    var bundledIconResourceName: String? {
        switch self {
        case .edge: return "microsoftedge"
        case .brave: return "brave"
        case .arc: return "arc"
        case .vivaldi: return "vivaldi"
        case .opera: return "opera"
        default: return nil
        }
    }

    /// Dia and the mainstream Chromium-family browsers share the same
    /// read-only `urls` history schema. Safari uses its own history database.
    /// Firefox remains visible in the source picker but is not queried yet.
    var isImplemented: Bool {
        switch self {
        case .dia, .chrome, .edge, .brave, .arc, .vivaldi, .opera, .chromium, .safari:
            return true
        case .firefox:
            return false
        }
    }

    fileprivate var historyRootComponents: [[String]] {
        switch self {
        case .dia:
            return [
                ["Dia", "User Data"],
                ["Dia", "User Data", "User Data"],
            ]
        case .chrome:
            return [["Google", "Chrome"]]
        case .edge:
            return [["Microsoft Edge"]]
        case .brave:
            return [["BraveSoftware", "Brave-Browser"]]
        case .arc:
            return [["Arc", "User Data"]]
        case .vivaldi:
            return [["Vivaldi"]]
        case .opera:
            return [["com.operasoftware.Opera"]]
        case .chromium:
            return [["Chromium"]]
        case .firefox, .safari:
            return []
        }
    }
}

enum BrowserHistoryPreferences {
    static let enabledSourcesStorageKey = "browserHistoryEnabledSources"
    static let menuRecordLimitStorageKey = "menuBrowserHistoryLimit"
    static let defaultMenuRecordLimit = 10

    static func enabledBrowsers(defaults: UserDefaults = .standard) -> Set<BrowserHistoryBrowser> {
        let rawValue = defaults.string(forKey: enabledSourcesStorageKey)
            ?? BrowserHistoryBrowser.dia.rawValue
        return Set(
            rawValue
                .split(separator: ",")
                .compactMap { BrowserHistoryBrowser(rawValue: String($0)) }
                .filter(\.isImplemented)
        )
    }

    static func menuRecordLimit(defaults: UserDefaults = .standard) -> Int {
        max(
            0,
            defaults.object(forKey: menuRecordLimitStorageKey) as? Int
                ?? defaultMenuRecordLimit
        )
    }
}

struct BrowserHistoryRecord: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let url: String
    let visitedAt: Date
    let browser: BrowserHistoryBrowser
    let profileName: String
}

struct BrowserHistorySection: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let records: [BrowserHistoryRecord]

    var count: Int { records.count }
}

enum BrowserHistoryStoreError: LocalizedError {
    case noSourceSelected
    case historyDatabaseNotFound
    case safariPermissionDenied
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSourceSelected:
            return "请先选择一个浏览器"
        case .historyDatabaseNotFound:
            return "找不到所选浏览器的历史数据库"
        case .safariPermissionDenied:
            return "无法读取 Safari 浏览历史。请在“系统设置 > 隐私与安全性 > 完整磁盘访问权限”中允许 Obelisk，然后重新启动 Obelisk。"
        case .openFailed(let message):
            return "无法打开浏览历史：\(message)"
        case .queryFailed(let message):
            return "读取浏览历史失败：\(message)"
        }
    }

    var requiresFullDiskAccess: Bool {
        if case .safariPermissionDenied = self { return true }
        return false
    }
}

/// Read-only, bounded view over browser-owned history databases.
/// Obelisk never writes to these files and keeps only the newest unique URLs
/// needed by the "最近浏览" page.
final class BrowserHistoryStore {
    static let defaultDayLimit = 30
    static let defaultRecordLimit = 1_000

    private let browsers: Set<BrowserHistoryBrowser>
    private let fileManager: FileManager
    private let applicationSupportDirectory: URL
    private let safariDirectory: URL

    init(
        browsers: Set<BrowserHistoryBrowser>,
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil,
        safariDirectory: URL? = nil
    ) {
        self.browsers = browsers.filter(\.isImplemented)
        self.fileManager = fileManager
        let libraryDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? libraryDirectory.appendingPathComponent("Application Support", isDirectory: true)
        self.safariDirectory = safariDirectory
            ?? libraryDirectory.appendingPathComponent("Safari", isDirectory: true)
    }

    func loadRecentSections(
        now: Date = Date(),
        dayLimit: Int = defaultDayLimit,
        recordLimit: Int = defaultRecordLimit
    ) throws -> [BrowserHistorySection] {
        guard !browsers.isEmpty else {
            throw BrowserHistoryStoreError.noSourceSelected
        }

        let calendar = Calendar.autoupdatingCurrent
        let safeDayLimit = max(1, dayLimit)
        let safeRecordLimit = max(1, recordLimit)
        let lowerDate = calendar.date(byAdding: .day, value: -safeDayLimit, to: now) ?? .distantPast

        var discoveredDatabase = false
        var records: [BrowserHistoryRecord] = []
        var firstReadError: Error?

        for browser in BrowserHistoryBrowser.allCases where browsers.contains(browser) {
            if browser == .safari {
                let historyURL = safariDirectory.appendingPathComponent("History.db")
                if !fileManager.fileExists(atPath: historyURL.path) {
                    do {
                        _ = try fileManager.attributesOfItem(atPath: historyURL.path)
                    } catch {
                        if Self.isPermissionError(error) {
                            discoveredDatabase = true
                            firstReadError = BrowserHistoryStoreError.safariPermissionDenied
                        }
                        continue
                    }
                }
                discoveredDatabase = true
                do {
                    records.append(contentsOf: try loadSafariRecords(
                        historyURL: historyURL,
                        lowerDate: lowerDate,
                        limit: safeRecordLimit
                    ))
                } catch {
                    if (error as? BrowserHistoryStoreError)?.requiresFullDiskAccess == true {
                        firstReadError = error
                    } else {
                        firstReadError = firstReadError ?? error
                    }
                }
                continue
            }

            let historyURLs = discoveredHistoryFileURLs(for: browser)
            discoveredDatabase = discoveredDatabase || !historyURLs.isEmpty

            for historyURL in historyURLs {
                do {
                    records.append(contentsOf: try loadRecords(
                        browser: browser,
                        historyURL: historyURL,
                        lowerTimestamp: Self.chromiumTimestamp(for: lowerDate),
                        limit: safeRecordLimit
                    ))
                } catch {
                    firstReadError = firstReadError ?? error
                }
            }
        }

        guard discoveredDatabase else {
            throw BrowserHistoryStoreError.historyDatabaseNotFound
        }
        if let storeError = firstReadError as? BrowserHistoryStoreError,
           storeError.requiresFullDiskAccess {
            throw storeError
        }
        if records.isEmpty, let firstReadError {
            throw firstReadError
        }

        records.sort {
            if $0.visitedAt != $1.visitedAt {
                return $0.visitedAt > $1.visitedAt
            }
            return $0.id.uuidString > $1.id.uuidString
        }

        var seenURLs = Set<String>()
        let recentRecords = records.compactMap { record -> BrowserHistoryRecord? in
            let normalizedURL = BookmarkStore.normalizedURL(record.url)
            guard seenURLs.insert(normalizedURL).inserted else { return nil }
            return record
        }.prefix(safeRecordLimit)

        return Self.sections(for: Array(recentRecords), now: now, calendar: calendar)
    }

    private func discoveredHistoryFileURLs(for browser: BrowserHistoryBrowser) -> [URL] {
        var candidates: [URL] = []
        for components in browser.historyRootComponents {
            let root = components.reduce(applicationSupportDirectory) {
                $0.appendingPathComponent($1, isDirectory: true)
            }

            candidates.append(root.appendingPathComponent("History"))
            candidates.append(root.appendingPathComponent("Default", isDirectory: true).appendingPathComponent("History"))

            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for child in children where Self.isBrowserProfileDirectory(child) {
                candidates.append(child.appendingPathComponent("History"))
            }
        }

        var seen = Set<String>()
        return candidates.filter { url in
            fileManager.fileExists(atPath: url.path)
                && seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    private static func isBrowserProfileDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == "Default"
            || name == "Guest Profile"
            || name.hasPrefix("Profile ")
            || name.hasPrefix("Person ")
    }

    private func loadRecords(
        browser: BrowserHistoryBrowser,
        historyURL: URL,
        lowerTimestamp: Int64,
        limit: Int
    ) throws -> [BrowserHistoryRecord] {
        try withDatabase(at: historyURL) { database in
            let sql = """
            SELECT id, url, title, last_visit_time
            FROM urls
            WHERE url LIKE 'http%'
              AND last_visit_time >= ?
            ORDER BY last_visit_time DESC, id DESC
            LIMIT ?;
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw BrowserHistoryStoreError.queryFailed(Self.errorMessage(for: database))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, lowerTimestamp)
            sqlite3_bind_int(statement, 2, Int32(limit))

            let profileName = Self.profileName(for: historyURL)
            var records: [BrowserHistoryRecord] = []
            while true {
                try Task.checkCancellation()
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else {
                    throw BrowserHistoryStoreError.queryFailed(Self.errorMessage(for: database))
                }
                guard let urlText = sqlite3_column_text(statement, 1) else { continue }

                let rowID = sqlite3_column_int64(statement, 0)
                let url = String(cString: urlText)
                let titleText = sqlite3_column_text(statement, 2)
                let title = titleText.map { String(cString: $0) } ?? ""
                let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url : title
                let timestamp = sqlite3_column_int64(statement, 3)

                records.append(BrowserHistoryRecord(
                    id: Self.recordID(
                        browser: browser,
                        profileName: profileName,
                        rowID: rowID,
                        url: url
                    ),
                    title: resolvedTitle,
                    url: url,
                    visitedAt: Self.date(fromChromiumTimestamp: timestamp),
                    browser: browser,
                    profileName: profileName
                ))
            }
            return records
        }
    }

    private func loadSafariRecords(
        historyURL: URL,
        lowerDate: Date,
        limit: Int
    ) throws -> [BrowserHistoryRecord] {
        try withDatabase(
            at: historyURL,
            permissionDeniedError: .safariPermissionDenied
        ) { database in
            let sql = """
            SELECT visits.id, items.url, visits.title, visits.visit_time
            FROM history_visits AS visits
            JOIN history_items AS items ON items.id = visits.history_item
            WHERE items.url LIKE 'http%'
              AND visits.visit_time >= ?
              AND visits.load_successful = 1
              AND visits.synthesized = 0
            ORDER BY visits.visit_time DESC, visits.id DESC
            LIMIT ?;
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw BrowserHistoryStoreError.queryFailed(Self.errorMessage(for: database))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_double(statement, 1, lowerDate.timeIntervalSinceReferenceDate)
            sqlite3_bind_int(statement, 2, Int32(limit))

            var records: [BrowserHistoryRecord] = []
            while true {
                try Task.checkCancellation()
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else {
                    throw BrowserHistoryStoreError.queryFailed(Self.errorMessage(for: database))
                }
                guard let urlText = sqlite3_column_text(statement, 1) else { continue }

                let rowID = sqlite3_column_int64(statement, 0)
                let url = String(cString: urlText)
                let titleText = sqlite3_column_text(statement, 2)
                let title = titleText.map { String(cString: $0) } ?? ""
                let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url : title
                let timestamp = sqlite3_column_double(statement, 3)

                records.append(BrowserHistoryRecord(
                    id: Self.recordID(
                        browser: .safari,
                        profileName: "Safari",
                        rowID: rowID,
                        url: url
                    ),
                    title: resolvedTitle,
                    url: url,
                    visitedAt: Date(timeIntervalSinceReferenceDate: timestamp),
                    browser: .safari,
                    profileName: "Safari"
                ))
            }
            return records
        }
    }

    private func withDatabase<T>(
        at historyURL: URL,
        permissionDeniedError: BrowserHistoryStoreError = .openFailed("没有读取权限"),
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        do {
            do {
                return try withOpenDatabase(at: historyURL, body: body)
            } catch DatabaseReadFailure.locked {
                return try withCopiedSnapshot(of: historyURL, body: body)
            }
        } catch DatabaseReadFailure.permissionDenied {
            throw permissionDeniedError
        }
    }

    private func withOpenDatabase<T>(at historyURL: URL, body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let escapedPath = historyURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? historyURL.path
        let openResult = sqlite3_open_v2(
            "file:\(escapedPath)?mode=ro",
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map(Self.errorMessage(for:)) ?? "unknown SQLite error"
            let systemError = database.map(sqlite3_system_errno) ?? 0
            if let database { sqlite3_close(database) }
            let primaryCode = openResult & 0xFF
            if systemError == EACCES
                || systemError == EPERM
                || (primaryCode == SQLITE_CANTOPEN && fileManager.fileExists(atPath: historyURL.path)) {
                throw DatabaseReadFailure.permissionDenied
            }
            if Self.isLockedSQLiteCode(openResult) {
                throw DatabaseReadFailure.locked
            }
            throw BrowserHistoryStoreError.openFailed(message)
        }
        sqlite3_busy_timeout(database, 750)

        do {
            let value = try body(database)
            sqlite3_close(database)
            return value
        } catch {
            let errorCode = sqlite3_extended_errcode(database)
            sqlite3_close(database)
            if Self.isPermissionSQLiteCode(errorCode) {
                throw DatabaseReadFailure.permissionDenied
            }
            if Self.isLockedSQLiteCode(errorCode) {
                throw DatabaseReadFailure.locked
            }
            throw error
        }
    }

    /// Chromium browsers can hold an exclusive SQLite lock while running.
    /// In that case, copy the database and any journal sidecars to a private
    /// temporary directory, query that snapshot, and delete it immediately.
    /// The browser-owned files are never opened for writing.
    private func withCopiedSnapshot<T>(
        of historyURL: URL,
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        let snapshotDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ObeliskHistorySnapshot-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: snapshotDirectory) }

        let snapshotURL = snapshotDirectory.appendingPathComponent("History")
        do {
            try fileManager.copyItem(at: historyURL, to: snapshotURL)
            for suffix in ["-wal", "-shm", "-journal"] {
                let source = URL(fileURLWithPath: historyURL.path + suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let destination = URL(fileURLWithPath: snapshotURL.path + suffix)
                try? fileManager.copyItem(at: source, to: destination)
            }
        } catch {
            if Self.isPermissionError(error) {
                throw DatabaseReadFailure.permissionDenied
            }
            throw BrowserHistoryStoreError.openFailed(error.localizedDescription)
        }

        return try withOpenDatabase(at: snapshotURL, body: body)
    }

    private static func sections(
        for records: [BrowserHistoryRecord],
        now: Date,
        calendar: Calendar
    ) -> [BrowserHistorySection] {
        var order: [String] = []
        var titles: [String: String] = [:]
        var grouped: [String: [BrowserHistoryRecord]] = [:]

        for record in records {
            let key = sectionKey(for: record.visitedAt, now: now, calendar: calendar)
            if grouped[key.id] == nil {
                order.append(key.id)
                titles[key.id] = key.title
            }
            grouped[key.id, default: []].append(record)
        }

        return order.compactMap { id in
            guard let records = grouped[id], let title = titles[id] else { return nil }
            return BrowserHistorySection(id: id, title: title, records: records)
        }
    }

    private static func sectionKey(
        for date: Date,
        now: Date,
        calendar: Calendar
    ) -> (id: String, title: String) {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        if day == today { return ("today", "今天") }
        if day == calendar.date(byAdding: .day, value: -1, to: today) { return ("yesterday", "昨天") }

        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        if day >= weekStart { return ("earlier-this-week", "本周早些时候") }
        let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart) ?? weekStart
        if day >= lastWeekStart { return ("last-week", "上周") }

        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? today
        if day >= monthStart { return ("earlier-this-month", "本月早些时候") }

        let components = calendar.dateComponents([.year, .month], from: date)
        let id = "month-\(components.year ?? 0)-\(components.month ?? 0)"
        return (id, "\(components.year ?? 0) 年 \(components.month ?? 0) 月")
    }

    private static func profileName(for historyURL: URL) -> String {
        let name = historyURL.deletingLastPathComponent().lastPathComponent
        switch name {
        case "Default", "User Data", "com.operasoftware.Opera":
            return "默认"
        default:
            return name
        }
    }

    private static func recordID(
        browser: BrowserHistoryBrowser,
        profileName: String,
        rowID: Int64,
        url: String
    ) -> UUID {
        let material = "\(browser.rawValue)|\(profileName)|\(rowID)|\(url)"
        var bytes = Array(SHA256.hash(data: Data(material.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func chromiumTimestamp(for date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
    }

    private static func date(fromChromiumTimestamp timestamp: Int64) -> Date {
        Date(timeIntervalSince1970: Double(timestamp) / 1_000_000 - 11_644_473_600)
    }

    private static func errorMessage(for database: OpaquePointer) -> String {
        guard let message = sqlite3_errmsg(database) else { return "unknown SQLite error" }
        return String(cString: message)
    }

    private static func isLockedSQLiteCode(_ code: Int32) -> Bool {
        let primaryCode = code & 0xFF
        return primaryCode == SQLITE_BUSY || primaryCode == SQLITE_LOCKED
    }

    static func isPermissionSQLiteCode(_ code: Int32) -> Bool {
        let primaryCode = code & 0xFF
        return primaryCode == SQLITE_AUTH || primaryCode == SQLITE_PERM
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        }
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileReadNoPermissionError
                || nsError.code == NSFileWriteNoPermissionError
        }
        return false
    }

    private enum DatabaseReadFailure: Error {
        case locked
        case permissionDenied
    }
}
