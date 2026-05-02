import Foundation
import Observation
import UniBookmarkCore

@MainActor
@Observable
final class BookmarksModel {
    private(set) var bookmarks: [Bookmark] = []
    var errorMessage: String?

    private let store: BookmarkStore

    init(store: BookmarkStore) {
        self.store = store
        reload()
    }

    func reload() {
        do {
            bookmarks = try store.bookmarks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func add(title: String, url: String) -> Bool {
        do {
            try store.add(title: title, url: url)
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func update(_ bookmark: Bookmark) -> Bool {
        do {
            try store.update(bookmark)
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete(id: UUID) {
        do {
            try store.delete(id: id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
