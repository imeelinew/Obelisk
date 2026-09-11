import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let addBookmark = Self("addBookmark", default: .init(.b, modifiers: [.option]))
    static let addHiddenBookmark = Self("addHiddenBookmark", default: .init(.h, modifiers: [.option]))
    static let toggleHiddenBookmarksSidebar = Self(
        "toggleHiddenBookmarksSidebar",
        default: .init(.h, modifiers: [.command, .shift])
    )
}
