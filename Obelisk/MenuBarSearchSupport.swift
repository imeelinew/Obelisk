import AppKit
import Carbon.HIToolbox
import os

private let inputSourceLog = Logger(subsystem: "com.eli.Obelisk", category: "InputSource")

@MainActor
enum MenuBarSearchKeyCommand: Equatable {
    case close
    case open
    case passThrough

    static func command(for event: NSEvent, hasMarkedText: Bool) -> MenuBarSearchKeyCommand {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.numericPad)
        guard modifiers.isEmpty, !hasMarkedText else { return .passThrough }

        switch event.keyCode {
        case UInt16(kVK_Escape):
            return .close
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            return .open
        default:
            return .passThrough
        }
    }
}

@MainActor
final class InputSourceSwitcher {
    func switchToUSEnglish() {
        guard let inputSource = preferredEnglishInputSource() else {
            inputSourceLog.error("No enabled ASCII-capable keyboard input source found")
            return
        }

        let status = TISSelectInputSource(inputSource)
        if status != noErr {
            let inputSourceID = stringProperty(inputSource, kTISPropertyInputSourceID)
            inputSourceLog.error("Failed to select input source \(inputSourceID, privacy: .public): \(status)")
        }
    }

    private func preferredEnglishInputSource() -> TISInputSource? {
        let preferredIDs = [
            "com.apple.keylayout.ABC",
            "com.apple.keylayout.US",
            "com.apple.keylayout.USInternational-PC"
        ]

        for id in preferredIDs {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            guard
                let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
                let source = sources.first,
                isSelectableASCIIKeyboardLayout(source)
            else {
                continue
            }
            return source
        }

        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        return sources.first(where: isSelectableASCIIKeyboardLayout)
    }

    private func isSelectableASCIIKeyboardLayout(_ source: TISInputSource) -> Bool {
        stringProperty(source, kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String)
            && stringProperty(source, kTISPropertyInputSourceType) == (kTISTypeKeyboardLayout as String)
            && boolProperty(source, kTISPropertyInputSourceIsEnabled)
            && boolProperty(source, kTISPropertyInputSourceIsSelectCapable)
            && boolProperty(source, kTISPropertyInputSourceIsASCIICapable)
    }

    private func stringProperty(_ source: TISInputSource, _ key: CFString) -> String {
        guard let rawValue = TISGetInputSourceProperty(source, key) else { return "" }
        return Unmanaged<CFString>.fromOpaque(rawValue).takeUnretainedValue() as String
    }

    private func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let rawValue = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(rawValue).takeUnretainedValue())
    }
}
