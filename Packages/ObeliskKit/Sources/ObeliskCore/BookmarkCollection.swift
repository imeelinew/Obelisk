import Foundation

public struct BookmarkCollection: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var sortOrder: Int
    public var showInMenu: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int = 0,
        showInMenu: Bool = false
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.showInMenu = showInMenu
    }
}
