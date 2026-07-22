import AppKit
import Carbon.HIToolbox
import ObeliskCore

enum BookmarkOperationTargetResolver {
    static func bookmarks(
        in candidates: [Bookmark],
        matching bookmarkIDs: Set<Bookmark.ID>
    ) -> [Bookmark] {
        var resolvedIDs = Set<Bookmark.ID>()
        return candidates.filter { bookmark in
            bookmarkIDs.contains(bookmark.id) && resolvedIDs.insert(bookmark.id).inserted
        }
    }
}

enum BookmarkKeyboardCommand: Equatable {
    case copy
    case edit
    case cancel
    case advanceSelection
    case delete
    case open
}

enum BookmarkKeyboardCommandResolver {
    static func resolve(
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> BookmarkKeyboardCommand? {
        let normalizedModifiers = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.numericPad)

        if normalizedModifiers == .command, characters == "c" {
            return .copy
        }
        if normalizedModifiers == .command, characters == "e" {
            return .edit
        }
        guard normalizedModifiers.isEmpty else { return nil }

        switch Int(keyCode) {
        case kVK_Escape:
            return .cancel
        case kVK_Tab:
            return .advanceSelection
        case kVK_Delete, kVK_ForwardDelete:
            return .delete
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return .open
        default:
            return nil
        }
    }
}
