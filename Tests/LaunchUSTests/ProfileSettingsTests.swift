import Foundation
import Testing
@testable import LaunchUS

/// Each layout profile keeps its own settings, including how it opens.
@MainActor
struct ProfileSettingsTests {
    private func settings() -> Settings {
        let name = "ProfileSettingsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return Settings(defaults: d)
    }

    @Test func settingsComeBackWhenRestored() {
        let s = settings()
        s.displayMode = .window
        s.columns = 6
        s.rows = 4
        s.browseStyle = .scroll
        s.hideNames = true
        s.iconScale = 0.9
        s.liquidGlass = false
        s.sortOrder = .name
        let window = ProfileSettings.capture(s)

        s.displayMode = .fullScreen
        s.columns = 8
        s.liquidGlass = true
        s.sortOrder = .custom
        #expect(ProfileSettings.capture(s) != window)

        ProfileSettings.restore(window, to: s)
        #expect(s.displayMode == .window)
        #expect((s.columns, s.rows) == (6, 4))
        #expect(s.iconScale == 0.9)
        #expect(!s.liquidGlass)
        #expect(s.sortOrder == .name)
        #expect(ProfileSettings.capture(s) == window)
    }

    @Test func restoreKeepsValuesInRangeAndSkipsUnknown() {
        let s = settings()
        ProfileSettings.restore(["columns": "[40]", "rows": "[0]", "nonsense": "[1]", "hideNames": "oops"], to: s)
        #expect((s.columns, s.rows) == (10, 3))
        #expect(!s.hideNames)
    }

    @Test func modeIsReadAndWritten() {
        var values: [String: String] = [:]
        #expect(ProfileSettings.mode(in: values) == nil)
        ProfileSettings.setMode(.window, in: &values)
        #expect(ProfileSettings.mode(in: values) == .window)
    }

    @Test func groupsNeverCarryTheMode() {
        for group in ProfileSettings.Group.allCases {
            #expect(!ProfileSettings.keys(in: group).contains(ProfileSettings.modeKey))
        }
        #expect(ProfileSettings.keys(in: .organize).contains("sortOrder"))
        #expect(ProfileSettings.keys(in: .behavior).contains("searchEngine") && !ProfileSettings.keys(in: .general).contains("searchEngine"))
        #expect(Set(ProfileSettings.fields.map(\.key)).count == ProfileSettings.fields.count)
    }

    @Test func oldProfilesFileStillLoads() throws {
        let json = #"{"current":"工作","saved":{"":[]},"looks":{},"shared":{"appearance":[["","工作"]]}}"#
        let file = try JSONDecoder().decode(LayoutProfiles.File.self, from: Data(json.utf8))
        #expect(file.current == "工作")
        #expect(file.settings.isEmpty)
    }

    @Test func fileRoundTrips() throws {
        var file = LayoutProfiles.File()
        file.settings["工作"] = ["columns": "[6]"]
        let back = try JSONDecoder().decode(LayoutProfiles.File.self, from: JSONEncoder().encode(file))
        #expect(back == file)
    }

    @Test func openingIsPerProfile() {
        let s = settings()
        s.hotKey = HotKeySpec(keyCode: 0, modifiers: 4096, display: "⌃A")
        s.trackpadPinch = true
        s.pinchFingers = 3
        s.hotCorner = .topLeft
        s.searchFiles = false
        let work = ProfileSettings.capture(s)

        s.hotKey = nil
        s.trackpadPinch = false
        s.hotCorner = .off
        s.searchFiles = true
        ProfileSettings.restore(work, to: s)
        #expect(s.hotKey?.display == "⌃A")
        #expect(s.trackpadPinch && s.pinchFingers == 3 && s.hotCorner == .topLeft)
        #expect(!s.searchFiles)
    }

    @Test func clearedShortcutStaysCleared() {
        let name = "ProfileSettingsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        #expect(Settings(defaults: d).hotKey == .default)
        Settings(defaults: d).hotKey = nil
        #expect(Settings(defaults: d).hotKey == nil)

        var values = ProfileSettings.capture(Settings(defaults: d))
        #expect(ProfileSettings.value("hotKey", in: values, as: HotKeySpec?.self) == .some(nil))
        values["hotKey"] = nil
        #expect(ProfileSettings.value("hotKey", in: values, as: HotKeySpec?.self) == nil)
    }

    @Test func newProfileStartsWithoutWaysToOpen() {
        let s = settings()
        s.f4Key = true
        s.trackpadPinch = true
        s.hotCorner = .bottomRight
        var values = ProfileSettings.capture(s)
        ProfileSettings.clearOpening(in: &values)
        ProfileSettings.restore(values, to: s)
        #expect(s.hotKey == nil && !s.f4Key && !s.trackpadPinch && s.hotCorner == .off)
    }

    @Test func appSettingsAreTheProfilesToo() {
        let s = settings()
        s.startAtLogin = true
        s.language = .japanese
        s.showMenuBarIcon = true
        s.menuBarIcon = .dots
        s.showDockIcon = true
        s.dockMenu = .recent
        s.appIcon = .rocket
        s.extraAppFolders = ["/Volumes/Apps"]
        let work = ProfileSettings.capture(s)

        s.startAtLogin = false
        s.language = .system
        s.showMenuBarIcon = false
        s.showDockIcon = false
        s.appIcon = .grid
        s.extraAppFolders = []
        ProfileSettings.restore(work, to: s)
        #expect(s.startAtLogin && s.language == .japanese)
        #expect(s.showMenuBarIcon && s.menuBarIcon == .dots)
        #expect(s.showDockIcon && s.dockMenu == .recent && s.appIcon == .rocket)
        #expect(s.extraAppFolders == ["/Volumes/Apps"])
        #expect(ProfileSettings.keys(in: .apps) == ["extraAppFolders"])
    }

    @Test func newProfileHasNoLoginItemOrMenuBarIconOfItsOwn() {
        let s = settings()
        s.startAtLogin = true
        s.showMenuBarIcon = true
        var values = ProfileSettings.capture(s)
        ProfileSettings.clearOpening(in: &values)
        ProfileSettings.restore(values, to: s)
        #expect(!s.startAtLogin && !s.showMenuBarIcon)
    }

    @Test func olderProfilesStartWithoutLoginItemOrMenuBarIcon() {
        var file = LayoutProfiles.File()
        file.current = ""
        file.saved["工作"] = []
        file.saved["游戏"] = []
        file.settings["游戏"] = ["columns": "[6]", "showMenuBarIcon": "[true]"]
        #expect(ProfileSettings.addPresenceKeys(&file, names: ["", "工作", "游戏"]))
        #expect(file.settings[""] == nil)
        #expect(ProfileSettings.value("startAtLogin", in: file.settings["工作"], as: Bool.self) == false)
        #expect(ProfileSettings.value("showMenuBarIcon", in: file.settings["工作"], as: Bool.self) == false)
        #expect(ProfileSettings.value("showMenuBarIcon", in: file.settings["游戏"], as: Bool.self) == true)
        #expect(file.settings["游戏"]?["columns"] == "[6]")
        #expect(!ProfileSettings.addPresenceKeys(&file, names: ["", "工作", "游戏"]))
    }

    @Test func backupListsItsProfilesWithTheirHiddenApps() {
        var meta: [String: AppMeta] = [:]
        var hidden = AppMeta()
        hidden.hidden = true
        meta["a"] = hidden
        var old = LayoutBackup(pages: [[.app("b")]], meta: meta)
        old.profile = "工作"
        old.profiles = ["游戏": [[.app("c")]], "": []]
        let found = old.allProfiles
        #expect(found.map(\.name) == ["工作", "", "游戏"])
        #expect(ProfileSettings.hiddenApps(in: found[0].settings) == ["a"])
        #expect(found[2].settings == nil)

        var values: [String: String] = ["columns": "[6]"]
        ProfileSettings.setHiddenApps(["c"], in: &values)
        var new = LayoutBackup(pages: [], meta: meta)
        new.profile = ""
        new.settings = ["": values]
        #expect(new.allProfiles.count == 1)
        #expect(ProfileSettings.hiddenApps(in: new.allProfiles[0].settings) == ["c"])
    }
}
