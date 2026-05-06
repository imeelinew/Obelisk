import AppKit
import Carbon.HIToolbox

/// Registers a Carbon-level global hotkey. Carbon's `RegisterEventHotKey`
/// works without Accessibility permission, intercepts the keystroke before
/// it reaches the focused app, and is still supported on macOS 26.
@MainActor
final class GlobalHotkeys {
    // `nonisolated(unsafe)` because these are accessed from the nonisolated
    // deinit and Carbon callback. Hotkeys are registered once during launch and
    // callbacks hop back to the main queue before invoking Swift closures.
    nonisolated(unsafe) private var hotKeyRefs: [EventHotKeyRef] = []
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var registeredIDs = Set<UInt32>()
    private var handlers: [UInt32: () -> Void] = [:]
    /// `OSType` four-char signature ("UBMK") to namespace our hotkey ID.
    private static let signature: OSType = 0x55_42_4D_4B  // 'U' 'B' 'M' 'K'

    init() {
        installHandler()
    }

    deinit {
        for hotKeyRef in hotKeyRefs {
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
                guard pressedID.signature == GlobalHotkeys.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let hotKeyID = pressedID.id

                // Hop to main actor to call back into Swift code.
                let token = userData
                DispatchQueue.main.async {
                    let me = Unmanaged<GlobalHotkeys>.fromOpaque(token).takeUnretainedValue()
                    me.handlers[hotKeyID]?()
                }

                let me = Unmanaged<GlobalHotkeys>.fromOpaque(userData).takeUnretainedValue()
                return me.registeredIDs.contains(hotKeyID) ? noErr : OSStatus(eventNotHandledErr)
            },
            1,
            &spec,
            userData,
            &eventHandler
        )
    }

    /// Carbon virtual key code (e.g. `kVK_ANSI_B = 11`) plus modifier bits
    /// (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`, OR-combined).
    func register(keyCode: UInt32, modifiers: UInt32, hotKeyID: UInt32, onPress: @escaping () -> Void) {
        let id = EventHotKeyID(signature: Self.signature, id: hotKeyID)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr, let hotKeyRef {
            hotKeyRefs.append(hotKeyRef)
            registeredIDs.insert(hotKeyID)
            handlers[hotKeyID] = onPress
        } else {
            // Most likely a hotkey conflict. Personal-use app: log and move on.
            NSLog("UniBookmark: failed to register global hotkey id=\(hotKeyID), status=\(status)")
        }
    }
}
