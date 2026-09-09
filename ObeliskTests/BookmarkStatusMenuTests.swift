import AppKit
import ObeliskCore
import ObeliskData
import Testing
@testable import Obelisk

@MainActor
struct BookmarkStatusMenuTests {
    @Test func bookmarkActionsTargetTheMenuOwnerAfterDelegateExtraction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskMenuTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BookmarkStore.open(rootDirectory: root, deviceID: UUID())
        let bookmark = try store.add(title: "Example", url: "https://example.com", isHidden: false)
        let model = BookmarksModel(store: store)
        let owner = BookmarkStatusMenuController(
            model: model,
            faviconLoader: FaviconLoader(rootDirectory: root)
        )
        let menu = owner.rebuildMenu()
        let items = menu.items.flatMap { [$0] + ($0.submenu?.items ?? []) }
        let bookmarkItems = items.filter { ($0.representedObject as? Bookmark)?.id == bookmark.id }
        #expect(!bookmarkItems.isEmpty)
        for item in bookmarkItems {
            #expect(item.target === owner)
            let action = try #require(item.action)
            #expect(owner.responds(to: action))
        }
        #expect(menu.items.last?.target === owner)
    }
}
