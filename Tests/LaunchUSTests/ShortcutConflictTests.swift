import AppKit
import Carbon.HIToolbox
import Testing
@testable import LaunchUS

@MainActor
@Suite struct ShortcutConflictTests {
    private func spec(_ code: Int, _ mods: Int) -> HotKeySpec { HotKeySpec(keyCode: code, modifiers: mods, display: "") }
    private func message(_ s: HotKeySpec, owner: String? = nil, others: [String: HotKeySpec] = [:]) -> String? {
        ShortcutConflicts.message(s, owner: owner, others: others) { $0 == "a" ? "Safari" : nil }
    }

    @Test func everyAppCommands() {
        #expect(message(spec(kVK_ANSI_C, cmdKey))?.contains("拷贝") == true)
        #expect(message(spec(kVK_ANSI_Q, cmdKey))?.contains("退出") == true)
    }

    @Test func fixedSystemShortcuts() {
        #expect(message(spec(kVK_Tab, cmdKey))?.contains("切换 App") == true)
        #expect(message(spec(kVK_ANSI_Q, cmdKey | controlKey))?.contains("锁定屏幕") == true)
    }

    @Test func duplicatesInsideLaunchUS() {
        let s = spec(kVK_ANSI_K, cmdKey | optionKey | controlKey | shiftKey)
        #expect(message(s, owner: "b", others: ["a": s, "b": s])?.contains("Safari") == true)
        // Its own entry doesn't count.
        #expect(message(s, owner: "a", others: ["a": s])?.contains("Safari") != true)
    }

    @Test func comboIgnoresDisplayText() {
        #expect(ShortcutConflicts.Combo(HotKeySpec(keyCode: 1, modifiers: cmdKey, display: "x"))
                == ShortcutConflicts.Combo(1, [.command]))
    }

    @Test func readsSystemShortcuts() {
        // Defaults fill in what was never changed, so there are always some.
        #expect(!ShortcutConflicts.systemShortcuts().isEmpty)
    }
}

struct SystemPinchTests {
    private func defaults(_ values: [String: Any]) -> UserDefaults {
        let name = "pinch-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        values.forEach { d.set($1, forKey: $0) }
        return d
    }

    @Test func threeFingersNeverConflict() {
        #expect(SystemPinch.conflicts(fingers: 3, dock: defaults([:]), trackpads: [defaults([:])]).isEmpty)
    }

    @Test func defaultsConflictWithBoth() {
        #expect(SystemPinch.conflicts(fingers: 4, dock: defaults([:]), trackpads: [defaults([:])]).count == 2)
    }

    @Test func switchedOffGesturesDontConflict() {
        let dock = defaults(["showLaunchpadGestureEnabled": false, "showDesktopGestureEnabled": true])
        #expect(SystemPinch.conflicts(fingers: 5, dock: dock, trackpads: [defaults([:])]).count == 1)
        let pad = defaults(["TrackpadFourFingerPinchGesture": 0, "TrackpadFiveFingerPinchGesture": 2])
        #expect(SystemPinch.conflicts(fingers: 4, dock: defaults([:]), trackpads: [pad]).isEmpty)
        #expect(SystemPinch.conflicts(fingers: TrackpadPinch.fourOrFive, dock: defaults([:]), trackpads: [pad]).count == 2)
    }
}
