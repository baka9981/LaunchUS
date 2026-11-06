import AppKit
import Testing
@testable import LaunchUS

@MainActor
struct MenuRedesignTests {
    @Test func alternateWithoutShortcutDiffersOnlyByOption() {
        let menu = NSMenu()
        let base = menu.add("在访达中显示") {}
        let alt = menu.addAlternate("显示简介") {}
        #expect(alt.isAlternate)
        #expect(base.keyEquivalentModifierMask == [])
        #expect(alt.keyEquivalentModifierMask == .option)
        #expect(alt.keyEquivalent == base.keyEquivalent)
    }

    @Test func alternateWithShortcutAddsOption() {
        let menu = NSMenu()
        let base = menu.add("退出", key: "q") {}
        let alt = menu.addAlternate("重启", key: "q") {}
        #expect(base.keyEquivalentModifierMask == .command)
        #expect(alt.keyEquivalentModifierMask == [.command, .option])
    }

    @Test func settingsLinksAcceptOldTabNames() {
        #expect(SettingsTab.named("about") == .advanced)
        #expect(SettingsTab.named("Appearance") == .appearance)
        #expect(SettingsTab.named("organize") == .organize)
        #expect(SettingsTab.named("nope") == nil)
    }
}
