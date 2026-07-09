import Foundation
import SQLite3

struct DiaHistoryRecord: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let url: String
    let visitedAt: Date
}

struct DiaHistorySectionSummary: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let lowerBound: Int64
    let upperBound: Int64
    let count: Int
}

enum DiaHistoryStoreError: LocalizedError {
    case historyDatabaseNotFound
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .historyDatabaseNotFound:
            return "找不到 Dia 浏览历史数据库"
        case .openFailed(let message):
            return "无法打开 Dia 浏览历史: \(message)"
        case .queryFailed(let message):
            return "读取 Dia 浏览历史失败: \(message)"
        }
    }
}

final class DiaHistoryStore {
    private let fileManager: FileManager
    private let historyFileURL: URL?

    init(
        historyFileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.historyFileURL = historyFileURL
    }

    func loadSectionSummaries(now: Date = Date()) throws -> [DiaHistorySectionSummary] {
        try withDatabase { database in
            guard let minTimestamp = try minHistoryTimestamp(in: database) else {
                return []
            }

            var sections: [DiaHistorySectionSummary] = []
            for candidate in Self.sectionCandidates(minTimestamp: minTimestamp, now: now) {
                let count = try countRecords(in: database, lowerBound: candidate.lowerBound, upperBound: candidate.upperBound)
                guard count > 0 else { continue }
                sections.append(DiaHistorySectionSummary(
                    id: candidate.id,
                    title: candidate.title,
                    lowerBound: candidate.lowerBound,
                    upperBound: candidate.upperBound,
                    count: count
                ))
            }
            return sections
        }
    }

    func loadPage(
        section: DiaHistorySectionSummary,
        pageIndex: Int,
        pageSize: Int
    ) throws -> [DiaHistoryRecord] {
        let offset = max(0, pageIndex) * max(1, pageSize)
        let limit = max(1, pageSize)

        return try withDatabase { database in
            let sql = """
            SELECT id, url, title, last_visit_time
            FROM urls
            WHERE hidden = 0
              AND url LIKE 'http%'
              AND last_visit_time >= ?
              AND last_visit_time < ?
            ORDER BY last_visit_time DESC, id DESC
            LIMIT ? OFFSET ?;
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw DiaHistoryStoreError.queryFailed(Self.errorMessage(for: database))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, section.lowerBound)
            sqlite3_bind_int64(statement, 2, section.upperBound)
            sqlite3_bind_int(statement, 3, Int32(limit))
            sqlite3_bind_int(statement, 4, Int32(offset))

            var records: [DiaHistoryRecord] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE {
                    break
                }
                guard step == SQLITE_ROW else {
                    throw DiaHistoryStoreError.queryFailed(Self.errorMessage(for: database))
                }
                guard let urlText = sqlite3_column_text(statement, 1) else {
                    continue
                }

                let id = sqlite3_column_int64(statement, 0)
                let url = String(cString: urlText)
                let titleText = sqlite3_column_text(statement, 2)
                let title = titleText.map { String(cString: $0) } ?? ""
                let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url : title
                let timestamp = sqlite3_column_int64(statement, 3)

                records.append(DiaHistoryRecord(
                    id: Self.recordID(forHistoryID: id),
                    title: resolvedTitle,
                    url: url,
                    visitedAt: Self.date(fromChromiumTimestamp: timestamp)
                ))
            }
            return records
        }
    }

    private struct SectionCandidate {
        let id: String
        let title: String
        let lowerBound: Int64
        let upperBound: Int64
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let historyURL = try resolvedHistoryFileURL()

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            sqliteURI(for: historyURL),
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map(Self.errorMessage(for:)) ?? "unknown SQLite error"
            if let database {
                sqlite3_close(database)
            }
            throw DiaHistoryStoreError.openFailed(message)
        }
        defer { sqlite3_close(database) }

        return try body(database)
    }

    private func minHistoryTimestamp(in database: OpaquePointer) throws -> Int64? {
        let sql = """
        SELECT MIN(last_visit_time)
        FROM urls
        WHERE hidden = 0
          AND url LIKE 'http%';
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DiaHistoryStoreError.queryFailed(Self.errorMessage(for: database))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DiaHistoryStoreError.queryFailed(Self.errorMessage(for: database))
        }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func countRecords(in database: OpaquePointer, lowerBound: Int64, upperBound: Int64) throws -> Int {
        let sql = """
        SELECT COUNT(*)
        FROM urls
        WHERE hidden = 0
          AND url LIKE 'http%'
          AND last_visit_time >= ?
          AND last_visit_time < ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DiaHistoryStoreError.queryFailed(Self.errorMessage(for: database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, lowerBound)
        sqlite3_bind_int64(statement, 2, upperBound)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DiaHistoryStoreError.queryFailed(Self.errorMessage(for: database))
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func resolvedHistoryFileURL() throws -> URL {
        if let historyFileURL, fileManager.fileExists(atPath: historyFileURL.path) {
            return historyFileURL
        }

        for candidate in Self.defaultHistoryFileURLs() where fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        throw DiaHistoryStoreError.historyDatabaseNotFound
    }

    private func sqliteURI(for url: URL) -> String {
        let escapedPath = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        return "file:\(escapedPath)?immutable=1"
    }

    private static func sectionCandidates(minTimestamp: Int64, now: Date) -> [SectionCandidate] {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart) ?? weekStart
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? today

        var candidates: [SectionCandidate] = []
        appendSection("today", "今天", today, tomorrow, minTimestamp, to: &candidates)
        appendSection("yesterday", "昨天", yesterday, today, minTimestamp, to: &candidates)
        appendSection("earlier-this-week", "本周早些时候", weekStart, yesterday, minTimestamp, to: &candidates)
        appendSection("last-week", "上周", lastWeekStart, weekStart, minTimestamp, to: &candidates)
        appendSection("earlier-this-month", "本月早些时候", monthStart, lastWeekStart, minTimestamp, to: &candidates)

        let coveredLowerBound = candidates.map(\.lowerBound).min() ?? chromiumTimestamp(for: tomorrow)
        var upperDate = date(fromChromiumTimestamp: coveredLowerBound)
        let minDate = date(fromChromiumTimestamp: minTimestamp)
        while upperDate > minDate {
            let monthDate = calendar.date(byAdding: .second, value: -1, to: upperDate) ?? upperDate
            guard let lowerDate = calendar.dateInterval(of: .month, for: monthDate)?.start,
                  lowerDate < upperDate
            else {
                break
            }
            let title = monthTitle(for: lowerDate, calendar: calendar)
            let id = "month-\(Self.chromiumTimestamp(for: lowerDate))-\(Self.chromiumTimestamp(for: upperDate))"
            appendSection(id, title, lowerDate, upperDate, minTimestamp, to: &candidates)
            upperDate = lowerDate
        }

        return candidates
    }

    private static func appendSection(
        _ id: String,
        _ title: String,
        _ lowerDate: Date,
        _ upperDate: Date,
        _ minTimestamp: Int64,
        to candidates: inout [SectionCandidate]
    ) {
        let lower = chromiumTimestamp(for: lowerDate)
        let upper = chromiumTimestamp(for: upperDate)
        guard lower < upper, upper > minTimestamp else { return }
        candidates.append(SectionCandidate(
            id: id,
            title: title,
            lowerBound: max(lower, minTimestamp),
            upperBound: upper
        ))
    }

    private static func monthTitle(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return "\(components.year ?? 0) 年 \(components.month ?? 0) 月"
    }

    private static func defaultHistoryFileURLs() -> [URL] {
        let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Dia", isDirectory: true)

        return [
            applicationSupport
                .appendingPathComponent("User Data", isDirectory: true)
                .appendingPathComponent("Default", isDirectory: true)
                .appendingPathComponent("History"),
            applicationSupport
                .appendingPathComponent("User Data", isDirectory: true)
                .appendingPathComponent("User Data", isDirectory: true)
                .appendingPathComponent("Default", isDirectory: true)
                .appendingPathComponent("History"),
        ]
    }

    private static func recordID(forHistoryID id: Int64) -> UUID {
        let suffix = UInt64(bitPattern: id) & 0xFFFFFFFFFFFF
        return UUID(uuidString: String(format: "D1A00000-0000-4000-8000-%012llX", suffix)) ?? UUID()
    }

    private static func chromiumTimestamp(for date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
    }

    private static func date(fromChromiumTimestamp timestamp: Int64) -> Date {
        Date(timeIntervalSince1970: Double(timestamp) / 1_000_000 - 11_644_473_600)
    }

    private static func errorMessage(for database: OpaquePointer) -> String {
        guard let message = sqlite3_errmsg(database) else {
            return "unknown SQLite error"
        }
        return String(cString: message)
    }
}
