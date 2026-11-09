import Foundation

/// The settings that belong to a layout profile: everything except what LaunchUS can only have
/// one of (iCloud sync, updates, anonymous usage sharing, moving everything in or out). App
/// names, tags and icons belong to the apps, so every profile sees the same. Start at
/// login, the language, the menu bar and Dock icons and where apps come from are the profile's too. A profile also has its own hidden apps (`hiddenAppsKey`), AI key
/// (`AIKey`), automatic backups and AI chats (`ProfileFolders`).
/// The active profile's live in `Settings`; switching saves them under the old profile and puts
/// the new one's in. To make another setting follow the profile, add it here (and show it on one
/// of the profile tabs).
@MainActor
enum ProfileSettings {
    /// The profile's settings tabs. A profile can copy a group from another one.
    enum Group: String, Codable, CaseIterable, Identifiable {
        case display, appearance, organize, general, behavior, hidden, apps, ai, manage
        var id: String { rawValue }

        var title: String {
            switch self {
            case .display: String(localized: "显示（设置页）", defaultValue: "显示")
            case .appearance: String(localized: "外观")
            case .organize: String(localized: "整理")
            case .general: String(localized: "打开（设置页）", defaultValue: "打开")
            case .behavior: String(localized: "行为（设置页）", defaultValue: "行为")
            case .hidden: String(localized: "隐藏")
            case .apps: "Apps"
            case .ai: "AI"
            case .manage: String(localized: "方案（设置页）", defaultValue: "方案")
            }
        }
    }

    /// One setting, saved as JSON so any Codable value fits.
    struct Field {
        let key: String
        let group: Group
        let capture: @MainActor (Settings) -> String?
        let restore: @MainActor (Settings, String) -> Void

        init<T: Codable & Equatable>(_ group: Group, _ key: String, _ path: ReferenceWritableKeyPath<Settings, T>,
                                     fit: @escaping @Sendable (T) -> T = { $0 }) {
            self.key = key
            self.group = group
            capture = { settings in
                (try? encoder.encode([settings[keyPath: path]])).map { String(decoding: $0, as: UTF8.self) }
            }
            restore = { settings, json in
                guard let saved = try? JSONDecoder().decode([T].self, from: Data(json.utf8)).first,
                      case let value = fit(saved),
                      settings[keyPath: path] != value else { return }
                settings[keyPath: path] = value
            }
        }
    }

    /// In the order they're put back: the way of showing comes first.
    static let fields: [Field] = [
        // 显示
        Field(.display, "displayMode", \.displayMode),
        Field(.display, "targetScreen", \.targetScreen),
        Field(.display, "hideDock", \.hideDock),
        Field(.display, "windowSize", \.windowSize, fit: clamp(Settings.windowSizeRange)),
        Field(.display, "iconScale", \.fullIconScale, fit: clamp(0.6...1.3)),
        Field(.display, "windowIconScale", \.windowIconScale, fit: clamp(0.6...1.3)),
        Field(.display, "columns", \.columns, fit: clamp(4...10)),
        Field(.display, "rows", \.rows, fit: clamp(3...8)),
        Field(.display, "hideNames", \.hideNames),
        Field(.display, "hideFolderNames", \.hideFolderNames),
        Field(.display, "browseStyle", \.browseStyle),
        Field(.display, "folderBrowseStyle", \.folderBrowseStyle),
        Field(.display, "folderIconStyle", \.folderIconStyle),
        Field(.display, "showFrequent", \.showFrequent),
        Field(.display, "showCategoryBar", \.showCategoryBar),
        Field(.display, "background", \.background),
        Field(.display, "backgroundImage", \.backgroundImage),
        Field(.display, "dynamicWallpaper", \.dynamicWallpaper),
        Field(.display, "weatherCity", \.weatherCity),
        Field(.display, "weatherLatitude", \.weatherLatitude),
        Field(.display, "weatherLongitude", \.weatherLongitude),
        Field(.display, "showWeatherLabel", \.showWeatherLabel),
        Field(.display, "liveWallpaper", \.liveWallpaper),
        Field(.display, "blur", \.blur),
        Field(.display, "backgroundSaturation", \.backgroundSaturation),
        Field(.display, "dim", \.dim),
        Field(.display, "glassStrength", \.glassStrength),
        Field(.display, "backgroundTemperature", \.backgroundTemperature),
        Field(.display, "backgroundTintHue", \.backgroundTintHue),
        Field(.display, "backgroundTint", \.backgroundTint),
        Field(.display, "backgroundGrain", \.backgroundGrain),
        Field(.display, "backgroundVignette", \.backgroundVignette),
        Field(.display, "darkenBackground", \.darkenBackground),
        Field(.display, "savedBackgroundStyles", \.savedBackgroundStyles),
        // 外观
        Field(.appearance, "appearance", \.appearance),
        Field(.appearance, "liquidGlass", \.liquidGlass),
        Field(.appearance, "animationRate", \.animationRate),
        Field(.appearance, "animationsOff", \.animationsOff),
        Field(.appearance, "motionCurve", \.motionCurve),
        Field(.appearance, "darkIcons", \.darkIcons),
        Field(.appearance, "hoverLift", \.hoverLift),
        Field(.appearance, "showNewDot", \.showNewDot),
        Field(.appearance, "showRunningDot", \.showRunningDot),
        Field(.appearance, "showBadges", \.showBadges),
        Field(.appearance, "dynamicCalendar", \.dynamicCalendar),
        Field(.appearance, "fadeStale", \.fadeStale),
        // 整理
        Field(.organize, "sortOrder", \.sortOrder),
        Field(.organize, "freePlacement", \.freePlacement),
        Field(.organize, "categoryTabOrder", \.categoryTabOrder),
        Field(.organize, "hiddenCategoryTabs", \.hiddenCategoryTabs),
        // 打开: how this profile opens
        Field(.general, "hotKey", \.hotKey),
        Field(.general, "f4Key", \.f4Key),
        Field(.general, "trackpadPinch", \.trackpadPinch),
        Field(.general, "pinchFingers", \.pinchFingers),
        Field(.general, "hotCorner", \.hotCorner),
        Field(.general, "clickButton", \.clickButton),
        Field(.general, "clickCount", \.clickCount),
        // 行为
        Field(.behavior, "returnHome", \.returnHome),
        Field(.behavior, "clickBackgroundToClose", \.clickBackgroundToClose),
        Field(.behavior, "wheelSpeed", \.wheelSpeed),
        Field(.behavior, "multiSelectKey", \.multiSelectKey),
        Field(.behavior, "deleteBadges", \.deleteBadges),
        Field(.behavior, "searchEngine", \.searchEngine),
        Field(.behavior, "searchFiles", \.searchFiles),
        // 打开 › 菜单栏与程序坞, 启动
        Field(.general, "showMenuBarIcon", \.showMenuBarIcon),
        Field(.general, "menuBarIcon", \.menuBarIcon),
        Field(.general, "showDockIcon", \.showDockIcon),
        Field(.general, "dockMenu", \.dockMenu),
        Field(.general, "appIcon", \.appIcon),
        Field(.general, "startAtLogin", \.startAtLogin),
        // 方案: the profile itself (never copied from another one)
        Field(.manage, "language", \.language),
        Field(.manage, "autoBackupCount", \.autoBackupCount, fit: clamp(0...50)),
        // Apps
        Field(.apps, "extraAppFolders", \.extraAppFolders),
        // 隐藏: how this profile's hidden apps are reached (the list itself is `hiddenAppsKey`)
        Field(.hidden, "hiddenDotEntrance", \.hiddenDotEntrance),
        Field(.hidden, "hiddenSlotEntrance", \.hiddenSlotEntrance),
        Field(.hidden, "hiddenSlotPage", \.hiddenSlotPage),
        Field(.hidden, "hiddenPhrase", \.hiddenPhrase),
        Field(.hidden, "hiddenRequireAuth", \.hiddenRequireAuth),
        Field(.hidden, "hiddenRelock", \.hiddenRelock),
        // AI (the key is in the keychain, `AIKey`)
        Field(.ai, "aiFormat", \.aiFormat),
        Field(.ai, "aiBaseURL", \.aiBaseURL),
        Field(.ai, "aiModel", \.aiModel),
        Field(.ai, "aiSystemPrompt", \.aiSystemPrompt),
        Field(.ai, "aiToolAccess", \.aiToolAccess),
        Field(.ai, "aiHistoryCount", \.aiHistoryCount, fit: clamp(0...200)),
    ]

    private static func clamp<T: Comparable & Sendable>(_ range: ClosedRange<T>) -> @Sendable (T) -> T {
        { min(range.upperBound, max(range.lowerBound, $0)) }
    }

    /// The way of showing is the profile itself, so it's never copied.
    static func keys(in group: Group) -> Set<String> {
        var keys = Set(fields.filter { $0.group == group && $0.key != modeKey }.map(\.key))
        if group == .hidden { keys.insert(hiddenAppsKey) }
        return keys
    }

    /// The profile's hidden apps, as a JSON list of app IDs. They're kept with the app's other
    /// extras (`AppMeta.hidden`) while the profile is active, and saved here when it isn't.
    /// Profiles from before 1.5 have none and keep the hidden apps of the one switched from.
    /// Sorted keys, so the same value always reads the same and a comparison sees no change.
    nonisolated static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }

    static let hiddenAppsKey = "hiddenApps"

    static func hiddenApps(in values: [String: String]?) -> Set<String>? {
        value(hiddenAppsKey, in: values, as: [String].self).map(Set.init)
    }

    static func setHiddenApps(_ ids: Set<String>, in values: inout [String: String]) {
        values[hiddenAppsKey] = (try? encoder.encode([ids.sorted()])).map { String(decoding: $0, as: UTF8.self) }
    }

    static let modeKey = "displayMode"
    /// Ways to open a profile; a new profile starts without them so it doesn't take another's.
    static let openingKeys: Set<String> = ["hotKey", "f4Key", "trackpadPinch", "hotCorner", "clickButton"]
    /// What a profile has its own of on the Mac (a login item, a menu bar icon): a new profile
    /// starts without them too, so it doesn't add a second one.
    static let presenceKeys: Set<String> = ["startAtLogin", "showMenuBarIcon"]

    /// One saved value of a waiting profile, or nil when it has none.
    static func value<T: Decodable>(_ key: String, in values: [String: String]?, as type: T.Type = T.self) -> T? {
        guard let json = values?[key] else { return nil }
        return try? JSONDecoder().decode([T].self, from: Data(json.utf8)).first
    }

    /// Clears the ways to open a profile in its saved settings.
    static func clearOpening(in values: inout [String: String]) {
        values["hotKey"] = "[null]"
        values["f4Key"] = "[false]"
        values["trackpadPinch"] = "[false]"
        values["hotCorner"] = #"["off"]"#
        values["clickButton"] = "[-1]"
        values["startAtLogin"] = "[false]"
        values["showMenuBarIcon"] = "[false]"
    }

    /// Profiles saved before start at login and the menu bar icon were their own had only the
    /// one of the active profile: the others start without them (everything else they lack
    /// keeps following the active profile until they're switched to). True when it changed any.
    static func addPresenceKeys(_ file: inout LayoutProfiles.File, names: [String]) -> Bool {
        var changed = false
        for name in names where name != file.current {
            var values = file.settings[name] ?? [:]
            for key in presenceKeys where values[key] == nil {
                values[key] = "[false]"
                changed = true
            }
            file.settings[name] = values
        }
        return changed
    }

    /// What 还原设置 puts back: a fresh install's settings, without the way of showing, the icon
    /// or the language (they're what the profile is). A profile other than the default one starts
    /// without ways to open it, a login item or a menu bar icon, like a new profile.
    static func resetValues(defaultProfile: Bool) -> [String: String] {
        let suite = "LaunchUS.reset.\(UUID().uuidString)"
        let blank = UserDefaults(suiteName: suite) ?? UserDefaults()
        defer { blank.removePersistentDomain(forName: suite) }
        var values = capture(Settings(defaults: blank))
        values[modeKey] = nil
        values["language"] = nil
        values["appIcon"] = nil
        if !defaultProfile { clearOpening(in: &values) }
        return values
    }

    static func capture(_ settings: Settings) -> [String: String] {
        var values: [String: String] = [:]
        for field in fields { values[field.key] = field.capture(settings) }
        return values
    }

    /// Settings missing from the saved ones (added in a later version) keep their current value.
    static func restore(_ values: [String: String], to settings: Settings) {
        for field in fields {
            if let json = values[field.key] { field.restore(settings, json) }
        }
    }

    static func mode(in values: [String: String]?) -> DisplayMode? {
        guard let json = values?[modeKey] else { return nil }
        return try? JSONDecoder().decode([DisplayMode].self, from: Data(json.utf8)).first
    }

    static func setMode(_ mode: DisplayMode, in values: inout [String: String]) {
        values[modeKey] = (try? encoder.encode([mode])).map { String(decoding: $0, as: UTF8.self) }
    }
}
