import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let addBookmark = Self("addBookmark", default: .init(.b, modifiers: [.option]))
    static let addHiddenBookmark = Self("addHiddenBookmark", default: .init(.h, modifiers: [.option]))
    static let undoAdd = Self("undoAdd", default: .init(.z, modifiers: [.option]))
    static let menuBarSearch = Self("menuBarSearch", default: .init(.s, modifiers: [.option]))
}
