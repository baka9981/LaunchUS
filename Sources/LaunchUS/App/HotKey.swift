import AppKit
import Carbon.HIToolbox
import Foundation

/// Global hotkey via Carbon's RegisterEventHotKey (no Accessibility permission needed).
@MainActor
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// Returns nil if the combination is already taken by another app.
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        HotKey.installHandlerIfNeeded()
        id = HotKey.nextID
        HotKey.nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x4350_4144), id: id) // 'CPAD'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        self.ref = ref
        HotKey.actions[id] = action
    }

    isolated deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            if err == noErr {
                let id = hotKeyID.id
                DispatchQueue.main.async { HotKey.actions[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Owns the launcher's global shortcut so it can be swapped or paused (while recording a new one).
@MainActor
enum HotKeyCenter {
    private static var hotKey: HotKey?
    private static var spec: HotKeySpec?
    private static var action: (() -> Void)?

    /// False when the shortcut is taken by another app.
    private(set) static var isRegistered = false

    /// The shortcut LaunchUS holds right now, if any.
    static var heldSpec: HotKeySpec? { hotKey != nil ? spec : nil }

    /// nil: no shortcut.
    static func register(_ spec: HotKeySpec?, action: @escaping () -> Void) {
        self.spec = spec
        self.action = action
        apply()
    }

    static var paused = false {
        didSet { if paused != oldValue { apply() } }
    }

    private static func apply() {
        hotKey = nil
        isRegistered = false
        guard !paused, let spec, let action else { return }
        hotKey = HotKey(keyCode: spec.keyCode, modifiers: spec.modifiers, action: action)
        isRegistered = hotKey != nil
    }
}

/// A set of shortcuts that each do something with an ID: open an app (set in the app's editor)
/// or open a layout profile (each profile's own, in its 通用 › 打开 LaunchUS).
@MainActor
final class HotKeyGroup {
    static let apps = HotKeyGroup()
    static let profiles = HotKeyGroup()
    static var all: [HotKeyGroup] { [apps, profiles] }

    /// Called with the ID when its shortcut is pressed.
    var action: ((String) -> Void)?
    /// IDs whose shortcut is taken (by another app, LaunchUS's own, or another one here).
    private(set) var failed: Set<String> = []
    private var keys: [String: HotKey] = [:]
    private var specs: [String: HotKeySpec] = [:]

    /// LaunchUS holds one of them that matches.
    func holds(where match: (HotKeySpec) -> Bool) -> Bool {
        keys.keys.contains { id in specs[id].map(match) ?? false }
    }

    func update(_ new: [String: HotKeySpec]) {
        guard new != specs else { return }
        specs = new
        apply()
    }

    /// While a shortcut is being recorded, so pressing an existing one records it instead.
    var paused = false {
        didSet { if paused != oldValue { apply() } }
    }

    private func apply() {
        keys = [:]
        failed = []
        guard !paused else { return }
        for (id, spec) in specs.sorted(by: { $0.key < $1.key }) {
            if let key = HotKey(keyCode: spec.keyCode, modifiers: spec.modifiers, action: { [weak self] in self?.action?(id) }) {
                keys[id] = key
            } else {
                failed.insert(id)
            }
        }
    }
}

/// The system's own shortcuts (Spotlight, input sources, screenshots…), switched off while a
/// shortcut is being recorded so they reach the recorder. Needs Accessibility; without it the
/// system keeps them and the conflict warning explains instead.
@MainActor
enum SystemHotKeys {
    private static var token: UnsafeMutableRawPointer?

    static var paused = false {
        didSet {
            guard paused != oldValue else { return }
            if paused {
                token = PushSymbolicHotKeyMode(OptionBits(kHIHotKeyModeAllDisabled))
            } else if let token {
                PopSymbolicHotKeyMode(token)
                self.token = nil
            }
        }
    }
}

enum HotKeyFormat {
    static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19",
    ]

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    static func carbon(_ flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return m
    }

    static func display(flags: NSEvent.ModifierFlags, keyCode: Int, characters: String?) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + (functionKeys[keyCode] ?? named[keyCode] ?? (characters ?? "?").uppercased())
    }
}
