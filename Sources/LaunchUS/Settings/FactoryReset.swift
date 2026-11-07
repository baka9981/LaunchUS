import AppKit

/// Settings › 高级 › 还原: back to a fresh install, then a relaunch.
@MainActor
enum FactoryReset {
    /// Moves the data folder (layout, folders, hidden apps, launch items, icons, backups, chats)
    /// to the Trash, so a regretted reset can still be undone from there, clears every setting
    /// except the app's language, and relaunches.
    static func run() throws {
        let fm = FileManager.default
        let data = LayoutStore.directory
        if fm.fileExists(atPath: data.path) {
            try fm.trashItem(at: data, resultingItemURL: nil)
        }
        let defaults = UserDefaults.app
        let language = defaults === UserDefaults.standard ? AppLanguage.current : .system
        for key in defaults.dictionaryRepresentation().keys where isOwn(key, in: defaults) {
            defaults.removeObject(forKey: key)
        }
        if language != .system { language.apply() }
        defaults.synchronize()
        AppRelauncher.relaunch()
    }

    /// Only keys LaunchUS saved itself: `dictionaryRepresentation` also lists global ones.
    private static func isOwn(_ key: String, in defaults: UserDefaults) -> Bool {
        if defaults === UserDefaults.standard, let id = Bundle.main.bundleIdentifier {
            return UserDefaults.standard.persistentDomain(forName: id)?[key] != nil
        }
        return true
    }
}
