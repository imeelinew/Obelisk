import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalHotkeys {
    private let lock = NSLock()
    nonisolated(unsafe) private var hotKeyRefs: [EventHotKeyRef] = []
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var registeredIDs = Set<UInt32>()
    private var handlers: [UInt32: () -> Void] = [:]
    private static let signature: OSType = 0x55_42_4D_4B

    init() {
        installHandler()
    }

    deinit {
        lock.lock()
        let refs = hotKeyRefs
        let handler = eventHandler
        lock.unlock()
        for hotKeyRef in refs {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handler {
            RemoveEventHandler(handler)
        }
    }

    private func installHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()

        var handler: EventHandlerRef?
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userDataPtr -> OSStatus in
                guard let eventRef, let userDataPtr else { return noErr }

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

                let token = userDataPtr
                DispatchQueue.main.async {
                    let me = Unmanaged<GlobalHotkeys>.fromOpaque(token).takeUnretainedValue()
                    me.handlers[hotKeyID]?()
                }

                let me = Unmanaged<GlobalHotkeys>.fromOpaque(userDataPtr).takeUnretainedValue()
                me.lock.lock()
                let found = me.registeredIDs.contains(hotKeyID)
                me.lock.unlock()
                return found ? noErr : OSStatus(eventNotHandledErr)
            },
            1,
            &spec,
            userData,
            &handler
        )

        lock.lock()
        eventHandler = handler
        lock.unlock()
    }

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
            lock.lock()
            hotKeyRefs.append(hotKeyRef)
            registeredIDs.insert(hotKeyID)
            lock.unlock()
            handlers[hotKeyID] = onPress
        } else {
            NSLog("Obelisk: failed to register global hotkey id=\(hotKeyID), status=\(status)")
        }
    }
}
