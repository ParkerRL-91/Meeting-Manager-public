import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey (works when the app is unfocused) via Carbon's
/// `RegisterEventHotKey`. No TCC permission required — unlike an event tap,
/// this is a registered hotkey, not keystroke monitoring. PRJ-017 F4 uses it
/// for "record a thought" from anywhere.
///
/// One installed handler dispatches to all live instances by id. Hold a strong
/// reference for the hotkey's lifetime; `deinit` unregisters it.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32
    private let handler: () -> Void

    private static var nextID: UInt32 = 1
    private static var instances: [UInt32: GlobalHotKey] = [:]
    private static var eventHandlerInstalled = false

    /// - Parameters:
    ///   - keyCode: a Carbon virtual key code (e.g. `kVK_ANSI_R`).
    ///   - modifiers: Carbon modifier mask (e.g. `cmdKey | optionKey`).
    ///   - handler: invoked on the main thread when the hotkey fires.
    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.id = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1
        self.handler = handler
        GlobalHotKey.instances[id] = self
        GlobalHotKey.installEventHandlerIfNeeded()
        register(keyCode: keyCode, modifiers: modifiers)
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        GlobalHotKey.instances[id] = nil
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        var hotKeyID = EventHotKeyID(signature: OSType(0x4D4D4752 /* "MMGR" */), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
        } else {
            NSLog("GlobalHotKey: RegisterEventHotKey failed (\(status)) for id \(id)")
        }
        _ = hotKeyID  // silence unused-write warning on some toolchains
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr else { return err }
            let capturedID = hotKeyID.id
            DispatchQueue.main.async {
                GlobalHotKey.instances[capturedID]?.handler()
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
