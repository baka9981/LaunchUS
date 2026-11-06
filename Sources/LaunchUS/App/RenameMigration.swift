import Foundation

/// The app used to be called LaunchNew. On the first launch under the new name this copies
/// what the old one left behind — preferences, the data folder and the iCloud Drive folder —
/// so the layout and settings carry over. The old copies are left as they were.
enum RenameMigration {
    static let oldBundleID = "local.launchnew.LaunchNew"
    static let oldFolderName = "LaunchNew"
    static let doneKey = "renamedFromLaunchNew"

    /// Runs once, before anything reads the settings.
    static func runIfNeeded() {
        guard Bundle.main.bundleIdentifier == "local.launchus.LaunchUS" else { return }
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldPreferences = UserDefaults.standard.persistentDomain(forName: oldBundleID)
        var folderPairs = [(old: support.appendingPathComponent(oldFolderName, isDirectory: true), new: LayoutStore.directory)]
        // Only look in iCloud Drive when the old app synced there: just checking asks for access.
        if oldPreferences?["iCloudSync"] as? Bool == true {
            folderPairs.append((ICloudSync.driveRoot.appendingPathComponent(oldFolderName, isDirectory: true), ICloudSync.folder))
        }
        run(defaults: .standard,
            oldPreferences: oldPreferences,
            ownPreferences: UserDefaults.standard.persistentDomain(forName: "local.launchus.LaunchUS"),
            folderPairs: folderPairs)
    }

    /// Copies the old preferences unless this app already has its own, and each old folder
    /// whose new one doesn't exist yet.
    static func run(defaults: UserDefaults, oldPreferences: [String: Any]?, ownPreferences: [String: Any]?,
                    folderPairs: [(old: URL, new: URL)]) {
        guard !defaults.bool(forKey: doneKey) else { return }
        let fm = FileManager.default
        if let oldPreferences, !oldPreferences.isEmpty, !hasOwnSettings(ownPreferences) {
            for (key, value) in oldPreferences { defaults.set(value, forKey: key) }
        }
        for (old, new) in folderPairs where fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
            try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: old, to: new)
        }
        defaults.set(true, forKey: doneKey)
    }

    /// Whether this app has saved anything of its own (system keys such as NSWindow frames don't count).
    private static func hasOwnSettings(_ domain: [String: Any]?) -> Bool {
        (domain ?? [:]).keys.contains { $0 != doneKey && !$0.hasPrefix("NS") && !$0.hasPrefix("SU") && !$0.hasPrefix("Apple") }
    }
}
