import Foundation

/// System Settings panes, offered after the apps in search: "蓝牙" or "bluetooth" opens the
/// Bluetooth pane. Read from the settings extensions macOS ships, so the names follow the
/// system language and panes added by a macOS update show up by themselves. Only opens
/// System Settings at that pane; nothing is changed.
enum SettingsPanes {
    static let idPrefix = "settings:"
    /// System Settings itself: the panes show its icon.
    static let settingsAppID = "com.apple.systempreferences"
    static let folder = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true)

    static func isPane(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// Read once; `warmUp()` does it off the main thread at launch.
    static let all: [AppItem] = load(from: folder)

    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = all }
    }

    /// Panes matching what's typed: none for #tags, or for a single Latin letter (which
    /// would list half of them).
    static func search(_ query: String, in panes: [AppItem] = all) -> [AppItem] {
        let (tags, text) = AppSearch.parse(query)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard tags.isEmpty, trimmed.count >= (trimmed.allSatisfy(\.isASCII) ? 2 : 1) else { return [] }
        return AppSearch.search(trimmed, in: panes)
    }

    static func load(from folder: URL, languages: [String] = Locale.preferredLanguages) -> [AppItem] {
        let bundles = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var seen = Set<String>()
        return bundles.filter { $0.pathExtension == "appex" }
            .compactMap { pane(at: $0, languages: languages) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Panes whose names aren't in their bundle, by bundle ID.
    private static let knownNames: [String: (local: String, english: String)] = [
        "com.apple.Battery-Settings.extension": (String(localized: "电池"), "Battery"),
    ]
    /// Panes that only make sense when System Settings opens them itself.
    private static let skipped: Set<String> = ["com.apple.FollowUpSettings.FollowUpSettingsExtension"]

    static func pane(at bundle: URL, languages: [String]) -> AppItem? {
        let contents = bundle.appendingPathComponent("Contents")
        guard let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String, !skipped.contains(id),
              let attributes = info["EXAppExtensionAttributes"] as? [String: Any],
              attributes["EXExtensionPointIdentifier"] as? String == "com.apple.Settings.extension.ui",
              let settings = attributes["SettingsExtensionAttributes"] as? [String: Any],
              settings["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true,
              let url = URL(string: "x-apple.systempreferences:" + id) else { return nil }

        let table = NSDictionary(contentsOf: contents.appendingPathComponent("Resources/InfoPlist.loctable"))
            as? [String: [String: Any]] ?? [:]
        // Some names are internal ("TrackpadExtension"), even translated ones: only a plain one will do.
        func name(_ strings: [String: Any]?) -> String? {
            let value = (strings?["CFBundleDisplayName"] as? String)?.trimmingCharacters(in: .whitespaces)
            guard let value, !value.isEmpty, !looksInternal(value) else { return nil }
            return value
        }
        let named = table.filter { name($0.value) != nil }
        let language = Bundle.preferredLocalizations(from: Array(named.keys), forPreferences: languages).first
        let english = knownNames[id]?.english ?? name(table["en"]) ?? name(info)
        guard let local = knownNames[id]?.local ?? language.flatMap({ name(named[$0]) }) ?? english else { return nil }

        let names = [local, english].compactMap { $0 }
        return AppItem(id: idPrefix + id, url: url, bundleID: nil, name: local,
                       searchNames: Array(Set(names.map { $0.lowercased() })),
                       pinyinKeys: Array(Set(names.flatMap(Pinyin.keys(for:)))),
                       category: nil, custom: .url)
    }

    private static func looksInternal(_ name: String) -> Bool {
        ["Extension", "Settings", "Preferences", "SettingPane"].contains { name.contains($0) }
            || name.contains(where: { $0 == "_" })
    }
}
