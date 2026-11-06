import Foundation
import Testing
@testable import LaunchUS

struct SettingsPanesTests {
    /// The panes on this Mac, named as for a Simplified Chinese system.
    private let panes = SettingsPanes.load(from: SettingsPanes.folder, languages: ["zh-Hans"])

    @Test func readsTheSystemPanes() throws {
        let bluetooth = try #require(panes.first { $0.id == "settings:com.apple.BluetoothSettings" })
        #expect(bluetooth.name == "蓝牙")
        #expect(bluetooth.url.absoluteString == "x-apple.systempreferences:com.apple.BluetoothSettings")
        #expect(SettingsPanes.isPane(bluetooth.id))
        // Internal bundle names never show.
        #expect(!panes.contains { $0.name.contains("Extension") })
    }

    @Test func findsByLocalNameEnglishAndPinyin() {
        #expect(SettingsPanes.search("蓝牙", in: panes).first?.name == "蓝牙")
        #expect(SettingsPanes.search("bluetooth", in: panes).first?.name == "蓝牙")
        #expect(SettingsPanes.search("chukong", in: panes).first?.name == "触控板")
        #expect(SettingsPanes.search("trackpad", in: panes).first?.name == "触控板")
        #expect(SettingsPanes.search("电池", in: panes).first?.name == "电池")
    }

    @Test func skipsSingleLettersAndTags() {
        #expect(SettingsPanes.search("b", in: panes).isEmpty)
        #expect(SettingsPanes.search("#工作", in: panes).isEmpty)
        #expect(SettingsPanes.search("   ", in: panes).isEmpty)
    }
}
