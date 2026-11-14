// Global hotkey via Carbon's RegisterEventHotKey.
//
// Carbon is still the only public API that registers a system-wide hotkey
// without requiring Accessibility permission, so it is the right tool here:
// the hotkey must work before the user has granted anything.
//
// The shortcut is stored in `Preferences`, so the preferences window can change
// it and the change survives a relaunch.

import AppKit
import Carbon.HIToolbox
import Foundation

struct HotKeyShortcut: Equatable {
    /// Virtual key code (Carbon `kVK_*`).
    var keyCode: UInt32
    /// Carbon modifier mask.
    var modifiers: UInt32
    /// Human-readable rendering, for example "⌥V".
    var label: String

    /// Option-V, matching a typical existing CopyQ setup.
    static let defaultShortcut = HotKeyShortcut(
        keyCode: HotKeyKey.v,
        modifiers: HotKeyModifiers.option,
        label: "\u{2325}V"
    )

    /// Suggested alternatives offered in the preferences window.
    static let presets: [HotKeyShortcut] = [
        HotKeyShortcut(keyCode: HotKeyKey.v, modifiers: HotKeyModifiers.option, label: "\u{2325}V"),
        HotKeyShortcut(keyCode: HotKeyKey.v, modifiers: HotKeyModifiers.command | HotKeyModifiers.shift, label: "\u{2318}\u{21E7}V"),
        HotKeyShortcut(keyCode: HotKeyKey.v, modifiers: HotKeyModifiers.control | HotKeyModifiers.option, label: "\u{2303}\u{2325}V"),
        HotKeyShortcut(keyCode: HotKeyKey.space, modifiers: HotKeyModifiers.command | HotKeyModifiers.shift, label: "\u{2318}\u{21E7}Space"),
        HotKeyShortcut(keyCode: HotKeyKey.c, modifiers: HotKeyModifiers.option, label: "\u{2325}C"),
        HotKeyShortcut(keyCode: HotKeyKey.b, modifiers: HotKeyModifiers.option, label: "\u{2325}B"),
    ]

    init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    init(preferences: Preferences) {
        keyCode = preferences.hotKeyKeyCode
        modifiers = preferences.hotKeyModifiers
        label = preferences.hotKeyDisplayLabel
    }

    /// The global Paste as Plain Text shortcut, separate from the summon one.
    static func plainText(from preferences: Preferences) -> HotKeyShortcut {
        HotKeyShortcut(
            keyCode: preferences.plainTextHotKeyKeyCode,
            modifiers: preferences.plainTextHotKeyModifiers,
            label: preferences.plainTextHotKeyDisplayLabel
        )
    }

    /// A shortcut needs at least one modifier; otherwise it would swallow an
    /// ordinary key press system-wide.
    var isUsable: Bool {
        modifiers & (HotKeyModifiers.command | HotKeyModifiers.option | HotKeyModifiers.control) != 0
            || modifiers & HotKeyModifiers.shift != 0
    }

    /// Whether two shortcuts describe the same physical keystroke.
    /// The label is presentation only: the same combination can be rendered as
    /// ⇧⌘V or ⌘⇧V, and a conflict check must not miss it because of that.
    func isSameKeystroke(as other: HotKeyShortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    func apply(to preferences: inout Preferences) {
        preferences.hotKeyKeyCode = keyCode
        preferences.hotKeyModifiers = modifiers
        preferences.hotKeyDisplayLabel = label
    }

    func applyPlainText(to preferences: inout Preferences) {
        preferences.plainTextHotKeyKeyCode = keyCode
        preferences.plainTextHotKeyModifiers = modifiers
        preferences.plainTextHotKeyDisplayLabel = label
    }

    /// Builds a shortcut from a recorded key event.
    static func from(event: NSEvent) -> HotKeyShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= HotKeyModifiers.command }
        if flags.contains(.shift) { modifiers |= HotKeyModifiers.shift }
        if flags.contains(.option) { modifiers |= HotKeyModifiers.option }
        if flags.contains(.control) { modifiers |= HotKeyModifiers.control }
        guard modifiers != 0 else { return nil }
        let label = HotKeyShortcut.label(for: event, modifiers: modifiers)
        return HotKeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label)
    }

    /// Renders the modifiers plus the key the user actually pressed, which is
    /// correct for any keyboard layout.
    private static func label(for event: NSEvent, modifiers: UInt32) -> String {
        var parts = ""
        if modifiers & HotKeyModifiers.control != 0 { parts += "\u{2303}" }
        if modifiers & HotKeyModifiers.option != 0 { parts += "\u{2325}" }
        if modifiers & HotKeyModifiers.shift != 0 { parts += "\u{21E7}" }
        if modifiers & HotKeyModifiers.command != 0 { parts += "\u{2318}" }

        let key = event.charactersIgnoringModifiers?.uppercased() ?? ""
        let display: String
        if key.isEmpty {
            display = Self.specialKeyName(event.keyCode)
        } else if key == " " {
            display = "Space"
        } else {
            display = key
        }
        return parts + display
    }

    private static func specialKeyName(_ keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "\u{21A9}"
        case kVK_Tab: return "\u{21E5}"
        case kVK_Escape: return "\u{238B}"
        case kVK_Delete: return "\u{232B}"
        case kVK_LeftArrow: return "\u{2190}"
        case kVK_RightArrow: return "\u{2192}"
        case kVK_UpArrow: return "\u{2191}"
        case kVK_DownArrow: return "\u{2193}"
        default: return "Key \(keyCode)"
        }
    }
}

/// The global shortcuts this app owns. The raw value is the Carbon hotkey ID.
enum HotKeyAction: UInt32 {
    case summon = 1
    case pastePlainText = 2
}

/// Owns the Carbon event handler and the registered hotkeys.
///
/// Both the summon shortcut and the Paste as Plain Text shortcut use one
/// handler. The hotkey ID in the event selects the action, so registering a
/// second shortcut can never fire the first one's handler.
final class HotKeyManager {
    private var hotKeyRefs: [HotKeyAction: EventHotKeyRef] = [:]
    private var registeredShortcuts: [HotKeyAction: HotKeyShortcut] = [:]
    private var eventHandler: EventHandlerRef?
    private var handlers: [HotKeyAction: () -> Void] = [:]

    func shortcut(for action: HotKeyAction) -> HotKeyShortcut? {
        registeredShortcuts[action]
    }

    func isRegistered(_ action: HotKeyAction) -> Bool {
        hotKeyRefs[action] != nil
    }

    /// Four-character signature identifying this app's hotkey events ("CQm1").
    private static let signature: OSType = {
        let bytes: [UInt8] = [0x43, 0x51, 0x6D, 0x31]
        return bytes.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }()

    /// Registers `shortcut` for `action`, replacing any previous registration
    /// for the same action. Returns false when the system refuses it.
    @discardableResult
    func register(
        _ shortcut: HotKeyShortcut,
        as action: HotKeyAction,
        handler: @escaping () -> Void
    ) -> Bool {
        unregister(action)
        handlers[action] = handler
        installEventHandlerIfNeeded()
        guard eventHandler != nil else {
            handlers[action] = nil
            return false
        }

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr, let hotKeyRef else {
            NSLog(
                "CopyQmac: RegisterEventHotKey failed (\(registerStatus)) for \(action); \(shortcut.label) may be taken"
            )
            handlers[action] = nil
            return false
        }
        hotKeyRefs[action] = hotKeyRef
        registeredShortcuts[action] = shortcut
        return true
    }

    func unregister(_ action: HotKeyAction) {
        if let hotKeyRef = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(hotKeyRef)
        }
        registeredShortcuts.removeValue(forKey: action)
        handlers[action] = nil
    }

    func unregisterAll() {
        for hotKeyRef in hotKeyRefs.values { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRefs.removeAll()
        registeredShortcuts.removeAll()
        handlers.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit { unregisterAll() }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == HotKeyManager.signature,
                      let action = HotKeyAction(rawValue: hotKeyID.id)
                else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                guard let handler = manager.handlers[action] else {
                    return OSStatus(eventNotHandledErr)
                }
                handler()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        if installStatus != noErr {
            NSLog("CopyQmac: InstallEventHandler failed (\(installStatus))")
            eventHandler = nil
        }
    }
}
