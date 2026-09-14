import Foundation

public enum BookmarkCollectionColor: String, CaseIterable, Codable, Sendable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case pink
    case gray
}

public struct BookmarkCollection: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var sortOrder: Int
    public var color: BookmarkCollectionColor

    public init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int = 0,
        color: BookmarkCollectionColor = .blue
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.color = color
    }
}
