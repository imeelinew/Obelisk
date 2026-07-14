import Foundation

public struct Bookmark: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: String
    public var createdAt: Date
    public var titleOptimized: Bool
    public var isHidden: Bool
    public var archivedAt: Date?
    public var isPinned: Bool
    public var originalTitle: String?

    public init(
        id: UUID = UUID(),
        title: String,
        url: String,
        createdAt: Date = Date(),
        titleOptimized: Bool = false,
        isHidden: Bool = false,
        archivedAt: Date? = nil,
        isPinned: Bool = false,
        originalTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.titleOptimized = titleOptimized
        self.isHidden = isHidden
        self.archivedAt = archivedAt
        self.isPinned = isPinned
        self.originalTitle = originalTitle
    }
}
