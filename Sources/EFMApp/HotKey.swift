import AppKit
import Carbon.HIToolbox

/// System-wide hotkey via Carbon `RegisterEventHotKey` (no Accessibility permission needed).
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var instances: [UInt32: GlobalHotKey] = [:]
    private static var nextId: UInt32 = 1
    private let id: UInt32

    /// Default: ⌘⇧Space.
    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(cmdKey | shiftKey), action: @escaping () -> Void) {
        self.action = action
        id = GlobalHotKey.nextId
        GlobalHotKey.nextId += 1
        GlobalHotKey.instances[id] = self

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard status == noErr else { return status }
            if let target = GlobalHotKey.instances[hk.id] {
                DispatchQueue.main.async { target.action() }
                return noErr
            }
            return OSStatus(eventNotHandledErr)
        }, 1, &spec, nil, &handler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4546_4D48) /* 'EFMH' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            NSLog("EFM: RegisterEventHotKey failed (%d) — the shortcut may be taken by another app", status)
        }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
        GlobalHotKey.instances[id] = nil
    }

    deinit { unregister() }
}
