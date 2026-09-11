import Foundation

public enum TitleOptimizationState: String, Codable, CaseIterable, Sendable {
    case notAttempted = "not_attempted"
    case succeeded
    case failed
}

public struct Bookmark: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: String
    public var createdAt: Date
    public var titleOptimizationState: TitleOptimizationState
    public var isHidden: Bool
    public var archivedAt: Date?
    public var originalTitle: String?

    public init(
        id: UUID = UUID(),
        title: String,
        url: String,
        createdAt: Date = Date(),
        titleOptimizationState: TitleOptimizationState = .notAttempted,
        isHidden: Bool = false,
        archivedAt: Date? = nil,
        originalTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.titleOptimizationState = titleOptimizationState
        self.isHidden = isHidden
        self.archivedAt = archivedAt
        self.originalTitle = originalTitle
    }
}
