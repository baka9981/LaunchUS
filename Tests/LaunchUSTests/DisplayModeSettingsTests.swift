import Foundation
import Testing
@testable import LaunchUS

/// Full screen and window keep their own icon size and window size; the grid stays shared.
@MainActor
struct DisplayModeSettingsTests {
    private func defaults() -> UserDefaults {
        let name = "DisplayModeSettingsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func eachModeKeepsItsOwnIconSize() {
        let settings = Settings(defaults: defaults())
        settings.displayMode = .fullScreen
        settings.iconScale = 1.2
        settings.displayMode = .window
        #expect(settings.iconScale == 1)  // its own, untouched
        settings.iconScale = 0.8
        #expect(settings.iconScale(for: .fullScreen) == 1.2)
        #expect(settings.iconScale(for: .window) == 0.8)
        settings.displayMode = .fullScreen
        #expect(settings.iconScale == 1.2)
    }

    @Test func settingOneModeWithoutSwitching() {
        let settings = Settings(defaults: defaults())
        settings.displayMode = .fullScreen
        settings.setIconScale(0.7, for: .window)
        #expect(settings.iconScale == 1)
        #expect(settings.displayMode == .fullScreen)
    }

    @Test func savedValuesComeBack() {
        let d = defaults()
        let settings = Settings(defaults: d)
        settings.setIconScale(1.1, for: .fullScreen)
        settings.setIconScale(0.9, for: .window)
        settings.windowSize = 1.2
        let again = Settings(defaults: d)
        #expect(again.iconScale(for: .fullScreen) == 1.1)
        #expect(again.iconScale(for: .window) == 0.9)
        #expect(again.windowSize == 1.2)
    }

    @Test func oldIconSizeCarriesOverToBothModes() {
        let d = defaults()
        d.set(1.15, forKey: "iconScale")
        let settings = Settings(defaults: d)
        #expect(settings.iconScale(for: .fullScreen) == 1.15)
        #expect(settings.iconScale(for: .window) == 1.15)
    }

    @Test func windowSizeIsKeptInRange() {
        let d = defaults()
        d.set(5.0, forKey: "windowSize")
        #expect(Settings(defaults: d).windowSize == Settings.windowSizeRange.upperBound)
        d.set(0.1, forKey: "windowSize")
        #expect(Settings(defaults: d).windowSize == Settings.windowSizeRange.lowerBound)
    }

    @Test func displayTabLink() {
        #expect(SettingsTab.named("display") == .display)
        #expect(SettingsTab.named("triggers") == .general)
        #expect(SettingsTab.named("profiles") == .profiles)
        // The profile's own tabs come first and every tab is in exactly one group.
        #expect(SettingsTab.profileTabs.first == .display)
        #expect(Set(SettingsTab.profileTabs + SettingsTab.topTabs) == Set(SettingsTab.allCases))
        #expect(SettingsTab.profileTabs.allSatisfy(\.isProfileTab) && !SettingsTab.topTabs.contains(where: \.isProfileTab))
    }
}
