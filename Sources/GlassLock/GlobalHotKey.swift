import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Carbon hot keys work while other apps are
/// frontmost and need no Accessibility permission.
@MainActor
final class GlobalHotKey {
    /// Ctrl+Cmd+L.
    static let lockKeyCode = UInt32(kVK_ANSI_L)
    static let lockModifiers = UInt32(controlKey | cmdKey)

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// Returns nil if the shortcut could not be registered (e.g. another app already owns it).
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installed == noErr else {
            Log.write("hotkey: handler install failed (\(installed))")
            return nil
        }
        let id = EventHotKeyID(signature: OSType(0x474C_4B4C), id: 1) // 'GLKL'
        let registered = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            Log.write("hotkey: register failed (\(registered)) — shortcut may be taken by another app")
            RemoveEventHandler(handlerRef)
            return nil
        }
    }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
