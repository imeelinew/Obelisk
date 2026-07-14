import Foundation

public struct UsageRecord: Codable, Equatable, Sendable {
    public var count: Int
    public var lastClickedAt: Date

    public init(count: Int, lastClickedAt: Date) {
        self.count = count
        self.lastClickedAt = lastClickedAt
    }
}
