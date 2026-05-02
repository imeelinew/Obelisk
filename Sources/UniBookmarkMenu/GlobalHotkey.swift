import AppKit
import Carbon.HIToolbox

/// Registers a Carbon-level global hotkey. Carbon's `RegisterEventHotKey`
/// works without Accessibility permission, intercepts the keystroke before
/// it reaches the focused app, and is still supported on macOS 26.
@MainActor
final class GlobalHotkey {
    var onPress: (() -> Void)?

    // `nonisolated(unsafe)` because these are accessed from the nonisolated
    // deinit. They're written only at init/deinit time, and the Carbon C
    // callback reads them indirectly via the event-target lookup, never
    // through these stored properties — so there's no real data race.
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    private let hotKeyID: UInt32 = 1
    /// `OSType` four-char signature ("UBMK") to namespace our hotkey ID.
    private let signature: OSType = 0x55_42_4D_4B  // 'U' 'B' 'M' 'K'

    /// Carbon virtual key code (e.g. `kVK_ANSI_B = 11`) plus modifier bits
    /// (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`, OR-combined).
    init(keyCode: UInt32, modifiers: UInt32) {
        installHandler()
        register(keyCode: keyCode, modifiers: modifiers)
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private func installHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let eventRef, let userData else { return noErr }

                var pressedID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                guard status == noErr else { return noErr }

                // Hop to main actor to call back into Swift code.
                let token = userData
                DispatchQueue.main.async {
                    let me = Unmanaged<GlobalHotkey>.fromOpaque(token).takeUnretainedValue()
                    if pressedID.id == me.hotKeyID {
                        me.onPress?()
                    }
                }
                return noErr
            },
            1,
            &spec,
            userData,
            &eventHandler
        )
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        let id = EventHotKeyID(signature: signature, id: hotKeyID)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            // Most likely a hotkey conflict. Personal-use app: log and move on.
            NSLog("UniBookmark: failed to register global hotkey, status=\(status)")
        }
    }
}
