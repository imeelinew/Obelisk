import Foundation

public enum BrowserHistoryBrowser: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case dia
    case chrome
    case safari

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dia: return "Dia"
        case .chrome: return "Google Chrome"
        case .safari: return "Safari"
        }
    }

    public var fallbackSystemImage: String {
        switch self {
        case .dia: return "sparkles"
        case .chrome: return "circle.hexagongrid"
        case .safari: return "safari"
        }
    }
}

public struct BrowserHistorySettings: Equatable, Sendable {
    public static let sharedID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    public static let defaultEnabledBrowsers: Set<BrowserHistoryBrowser> = [.dia]

    public var enabledBrowsers: Set<BrowserHistoryBrowser>

    public init(enabledBrowsers: Set<BrowserHistoryBrowser>) {
        self.enabledBrowsers = enabledBrowsers
    }

    public init(encodedEnabledSources: String) {
        self.init(enabledBrowsers: Set(
            encodedEnabledSources
                .split(separator: ",")
                .compactMap { BrowserHistoryBrowser(rawValue: String($0)) }
        ))
    }

    public var encodedEnabledSources: String {
        BrowserHistoryBrowser.allCases
            .filter { enabledBrowsers.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
    }
}

public struct BrowserHistoryRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let url: String
    public let visitedAt: Date
    public let browser: BrowserHistoryBrowser
    public let profileName: String

    public init(
        id: UUID,
        title: String,
        url: String,
        visitedAt: Date,
        browser: BrowserHistoryBrowser,
        profileName: String
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.visitedAt = visitedAt
        self.browser = browser
        self.profileName = profileName
    }
}

public struct BrowserHistorySection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let records: [BrowserHistoryRecord]

    public init(id: String, title: String, records: [BrowserHistoryRecord]) {
        self.id = id
        self.title = title
        self.records = records
    }

    public var count: Int { records.count }
}

public enum BrowserHistoryGrouping {
    public static let dayLimit = 30
    public static let recordLimit = 1_000

    public static func sections(
        for records: [BrowserHistoryRecord],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [BrowserHistorySection] {
        var order: [String] = []
        var titles: [String: String] = [:]
        var grouped: [String: [BrowserHistoryRecord]] = [:]

        let orderedRecords = records.sorted {
            if $0.visitedAt != $1.visitedAt {
                return $0.visitedAt > $1.visitedAt
            }
            return $0.id.uuidString > $1.id.uuidString
        }

        for record in orderedRecords {
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
        if day == calendar.date(byAdding: .day, value: -1, to: today) {
            return ("yesterday", "昨天")
        }

        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        if day >= weekStart { return ("earlier-this-week", "本周早些时候") }
        let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart) ?? weekStart
        if day >= lastWeekStart { return ("last-week", "上周") }

        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? today
        if day >= monthStart { return ("earlier-this-month", "本月早些时候") }

        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        return ("month-\(year)-\(month)", "\(year) 年 \(month) 月")
    }
}
