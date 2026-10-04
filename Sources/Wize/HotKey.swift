import AppKit
import Carbon.HIToolbox

/// A recorded keyboard shortcut (virtual key code + modifiers), persisted in UserDefaults.
struct Shortcut: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags
    var key: String // display character, e.g. "E"

    /// ⌃⌥E: a global ⌘E would steal ⌘E (Eject, Use Selection for Find…) from every app.
    static let defaultEditSize = Shortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: [.control, .option], key: "E")

    var label: String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + key
    }

    var carbonModifiers: UInt32 {
        (modifiers.contains(.command) ? UInt32(cmdKey) : 0) | (modifiers.contains(.option) ? UInt32(optionKey) : 0)
            | (modifiers.contains(.control) ? UInt32(controlKey) : 0) | (modifiers.contains(.shift) ? UInt32(shiftKey) : 0)
    }

    /// From a key-down while recording; nil unless ⌘, ⌃ or ⌥ is held (a bare key can't be a global shortcut).
    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !mods.intersection([.command, .control, .option]).isEmpty,
              let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods, key: chars.uppercased())
    }

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    static var editSize: Shortcut {
        get {
            let d = UserDefaults.standard
            guard let key = d.string(forKey: "editShortcutKey") else { return defaultEditSize }
            return Shortcut(keyCode: UInt32(d.integer(forKey: "editShortcutCode")),
                            modifiers: NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: "editShortcutMods"))),
                            key: key)
        }
        set {
            let d = UserDefaults.standard
            d.set(Int(newValue.keyCode), forKey: "editShortcutCode")
            d.set(Int(newValue.modifiers.rawValue), forKey: "editShortcutMods")
            d.set(newValue.key, forKey: "editShortcutKey")
        }
    }
}

/// One global hotkey via Carbon's RegisterEventHotKey: needs no permission and doesn't see other keystrokes.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, refcon in
            guard let refcon else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() } // delivered on the main event loop
            return noErr
        }, 1, &spec, refcon, &handler)
    }

    func register(_ shortcut: Shortcut) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        let id = EventHotKeyID(signature: OSType(0x575A_4531), id: 1) // "WZE1"
        RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}
