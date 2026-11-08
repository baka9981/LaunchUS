import AppKit
import SwiftUI

// Layout profiles, launch items and picked icons.

extension LauncherModel {
    // MARK: - Layout profiles

    var profileNames: [String] { _ = profilesVersion; return LayoutProfiles.names(profiles) }
    var currentProfile: String { _ = profilesVersion; return profiles.current }

    /// How a profile is shown; the current one's is whatever the settings say now.
    func profileMode(_ name: String) -> DisplayMode {
        _ = profilesVersion
        guard name != profiles.current else { return settings.displayMode }
        return ProfileSettings.mode(in: profiles.settings[name]) ?? settings.displayMode
    }

    /// "默认 · 全屏", for menus and the profile bar.
    func profileLabel(_ name: String) -> String {
        "\(LayoutProfiles.title(name)) · \(profileMode(name).title)"
    }

    /// Keeps the current layout and settings under its profile and loads the other one's.
    /// A profile in another language relaunches LaunchUS in it, opening the launcher again
    /// when `reopen`.
    func switchProfile(_ name: String, reopen: Bool = true) {
        guard name != profiles.current, drag == nil else { return }
        AutoBackup.snapshot()  // into the profile being left
        profiles.saved[profiles.current] = layout
        storeCurrentSettings()
        let target = profiles.saved[name] ?? layout
        let values = profiles.settings[name]
        profiles.current = name
        LayoutProfiles.save(profiles)
        profilesVersion += 1
        // Its hidden apps go behind their own entrance and verification.
        if hiddenUnlocked || showHiddenApps { lockHidden() }
        chat = nil
        NotificationCenter.default.post(name: ChatHistory.didChange, object: nil)
        guard takeOn(target, settings: values, reopen: reopen) else { return }
        showNotice(String(localized: "已切换到布局「\(LayoutProfiles.title(name))」"))
    }

    /// Puts a profile's settings, hidden apps and pages on screen as the current profile's (the
    /// profile is already `profiles.current`). A
    /// language change relaunches LaunchUS in it (opening the launcher again when `reopen`) and
    /// returns false; the pages are laid out once it's back.
    @discardableResult
    func takeOn(_ target: [[LayoutItem]], settings values: [String: String]?, reopen: Bool) -> Bool {
        let (name, languageBefore, foldersBefore) = (profiles.current, settings.language, settings.extraAppFolders)
        if let hidden = ProfileSettings.hiddenApps(in: values) { applyHiddenApps(hidden) }
        // The pages were saved for the profile's own grid: take that on first, then lay them out.
        if let values {
            switchingProfile = true
            ProfileSettings.restore(values, to: settings)
            switchingProfile = false
        }
        // Its own ways to open it, and the other profiles' ones that changed with it.
        NotificationCenter.default.post(name: Self.triggersChanged, object: nil)
        if settings.language != languageBefore {
            relaunchingForLanguage = true
            LayoutStore.save(layout: target)  // laid out again once it's back
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                AppRelauncher.relaunch(opening: reopen ? URL(string: "launchus://open") : nil)
            }
            return false
        }
        let layOut = { [self] in
            (laidOutColumns, laidOutRows) = (columns, rows)
            layout = LayoutOps.reconcile(target, installed: catalog.apps, hidden: hiddenIDs, perPage: perPage, free: freePlacement)
            LayoutStore.save(layout: layout)
            dropFolder()
            currentPage = 0
            refresh()
        }
        if settings.extraAppFolders != foldersBefore {
            // Its own app folders: lay its pages out against those apps, so the apps only it
            // reads keep their places.
            catalog.reload(force: true) { [weak self] _ in
                guard let self, profiles.current == name, drag == nil else { return }
                layOut()
            }
        } else {
            layOut()
        }
        return true
    }

    private func storeCurrentSettings() {
        profiles.settings[profiles.current] = captureCurrentSettings()
    }

    /// The active profile's settings, with its hidden apps.
    func currentProfileSettings() -> [String: String] { captureCurrentSettings() }

    private func captureCurrentSettings() -> [String: String] {
        var values = ProfileSettings.capture(settings)
        ProfileSettings.setHiddenApps(hiddenIDs, in: &values)
        return values
    }

    /// Makes exactly these apps hidden; the rest of each app's extras stay.
    func applyHiddenApps(_ ids: Set<String>) {
        guard ids != hiddenIDs else { return }
        var changed = meta
        for id in Set(changed.keys).union(ids) {
            let hide = ids.contains(id)
            guard (changed[id]?.hidden ?? false) != hide else { continue }
            var m = changed[id] ?? AppMeta()
            m.hidden = hide
            changed[id] = m
        }
        meta = changed
        LayoutStore.save(meta: meta)
    }

    /// Switches by a name typed in a link or Shortcuts. Returns false when there's no such profile.
    @discardableResult
    func switchProfile(named text: String) -> Bool {
        guard let name = LayoutProfiles.resolve(text, in: profiles) else { return false }
        switchProfile(name)
        return true
    }

    /// A new profile is shown the chosen way, with the settings of `settingsFrom` (the current
    /// profile by default). It starts with a copy of the current pages (or of `pages`, to copy
    /// another profile), or with every app in name order.
    func createProfile(_ rawName: String, mode: DisplayMode, copyPages: Bool = true, pages: [[LayoutItem]]? = nil,
                       settingsFrom source: String? = nil) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, LayoutProfiles.resolve(name, in: profiles) == nil else { return }
        profiles.saved[name] = pages ?? (copyPages ? layout : LayoutOps.alphabetical(catalog.apps, perPage: perPage))
        let live = captureCurrentSettings()
        let from = source.flatMap { $0 == profiles.current || profiles.settings[$0] != nil ? $0 : nil } ?? profiles.current
        var values = from == profiles.current ? live : profiles.settings[from] ?? live
        ProfileSettings.setMode(mode, in: &values)
        ProfileSettings.clearOpening(in: &values)
        profiles.settings[name] = values
        AIKey.copy(from: from, to: name)
        switchProfile(name)
    }

    func renameProfile(_ old: String, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !old.isEmpty, !name.isEmpty, name != old, LayoutProfiles.resolve(name, in: profiles) == nil else { return }
        profiles.saved[name] = profiles.saved.removeValue(forKey: old)
        profiles.settings[name] = profiles.settings.removeValue(forKey: old)
        AIKey.rename(old, to: name)
        ProfileFolders.rename(old, to: name)
        if profiles.current == old { profiles.current = name }
        saveProfiles()
    }

    func deleteProfile(_ name: String) {
        guard !name.isEmpty else { return }
        if profiles.current == name { switchProfile("") }
        profiles.saved[name] = nil
        profiles.settings[name] = nil
        AIKey.remove(name)
        ProfileFolders.remove(name)
        saveProfiles()
    }

    func saveProfiles() {
        LayoutProfiles.save(profiles)
        profilesVersion += 1
        NotificationCenter.default.post(name: Self.triggersChanged, object: nil)
    }

    // MARK: - Copying settings between profiles

    /// Takes another profile's settings in `group` once; afterwards each changes on its own.
    func copySettings(_ group: ProfileSettings.Group, from source: String) {
        guard source != profiles.current, let values = profiles.settings[source] else { return }
        let apply = { [self] in
            let keys = ProfileSettings.keys(in: group)
            ProfileSettings.restore(values.filter { keys.contains($0.key) }, to: settings)
            switch group {
            case .hidden:
                if let hidden = ProfileSettings.hiddenApps(in: values) {
                    applyHiddenApps(hidden)
                    reconcile(forceSave: true)
                }
            case .ai:
                AIKey.copy(from: source, to: profiles.current)
            default: break
            }
        }
        // Taking another profile's hidden settings could unhide apps or drop verification.
        if group == .hidden { whenHiddenUnlocked(reason: String(localized: "修改隐藏的 App 设置"), apply) } else { apply() }
    }

    /// Settings › a profile › 还原设置: this profile's settings as a fresh install has them. Its
    /// pages, hidden apps and AI key stay.
    func resetProfileSettings() {
        // The hidden apps' verification goes back to its default too.
        whenHiddenUnlocked(reason: String(localized: "还原这个方案的设置")) { [self] in
            ProfileSettings.restore(ProfileSettings.resetValues(defaultProfile: profiles.current.isEmpty), to: settings)
        }
    }

    /// Puts an automatic backup of this profile back: its pages and its hidden apps. Names,
    /// tags and icons are shared by all profiles, so they stay as they are.
    func restoreProfileBackup(from url: URL) throws {
        let backup = try JSONDecoder().decode(LayoutBackup.self, from: Data(contentsOf: url))
        // Launch items deleted since then come back, so their places aren't dropped.
        let missing = (backup.custom ?? []).filter { item in !customItems.contains { $0.id == item.id } }
        withCustomItems(missing.isEmpty ? nil : customItems + missing) {
            applyHiddenApps(Set(backup.meta.filter { $0.value.hidden }.map(\.key)))
            layout = LayoutOps.reconcile(backup.pages, installed: catalog.apps, hidden: hiddenIDs, perPage: perPage, free: freePlacement)
            LayoutStore.save(layout: layout)
            dropFolder()
            currentPage = 0
            refresh()
        }
    }

    // MARK: - Opening a profile directly

    /// How a profile opens: its own shortcut, F4, pinch and corner, from its settings.
    struct Opening: Equatable {
        var hotKey: HotKeySpec?
        var f4 = false
        /// Pinch finger counts; empty when it doesn't open by pinching.
        var fingers: Set<Int> = []
        var corner: HotCorner = .off
        /// Quick clicks of a mouse button; `.off` when it doesn't open that way.
        var clickButton: ClickButton = .off
        var clickCount = 3
    }

    func opening(for name: String) -> Opening {
        _ = profilesVersion
        if name == profiles.current {
            return Opening(hotKey: settings.hotKey, f4: settings.f4Key,
                           fingers: settings.trackpadPinch ? TrackpadPinch.fingerCounts(for: settings.pinchFingers) : [],
                           corner: settings.hotCorner,
                           clickButton: settings.clickButton, clickCount: settings.clickCount)
        }
        // Profiles from before their settings were kept use the current ones' way of showing,
        // but no way to open of their own.
        guard let values = profiles.settings[name] else { return Opening() }
        let pinch = ProfileSettings.value("trackpadPinch", in: values, as: Bool.self) ?? false
        return Opening(hotKey: ProfileSettings.value("hotKey", in: values, as: HotKeySpec?.self) ?? nil,
                       f4: ProfileSettings.value("f4Key", in: values, as: Bool.self) ?? false,
                       fingers: pinch ? TrackpadPinch.fingerCounts(for: ProfileSettings.value("pinchFingers", in: values, as: Int.self) ?? 4) : [],
                       corner: ProfileSettings.value("hotCorner", in: values, as: HotCorner.self) ?? .off,
                       clickButton: ProfileSettings.value("clickButton", in: values, as: ClickButton.self) ?? .off,
                       clickCount: ProfileSettings.value("clickCount", in: values, as: Int.self) ?? 3)
    }

    /// The current profile first: when two profiles ask for the same thing, it wins.
    /// One of a profile's settings: the live one for the current profile, else its saved one.
    func profileSetting<T: Decodable>(_ key: String, of name: String, current: T, as type: T.Type = T.self) -> T? {
        _ = profilesVersion
        return name == profiles.current ? current : ProfileSettings.value(key, in: profiles.settings[name], as: T.self)
    }

    /// The profile's own menu bar icon, or nil when it has none.
    func menuBarIcon(of name: String) -> MenuBarIconStyle? {
        guard profileSetting("showMenuBarIcon", of: name, current: settings.showMenuBarIcon) ?? false else { return nil }
        return profileSetting("menuBarIcon", of: name, current: settings.menuBarIcon) ?? .grid
    }

    /// Whether the profile has a Dock icon: LaunchUS's own for the default profile, a stand-in
    /// of its own (`DockTiles`) for the others.
    func showsDockIcon(_ name: String) -> Bool {
        profileSetting("showDockIcon", of: name, current: settings.showDockIcon) ?? false
    }

    func appIcon(of name: String) -> AppIconStyle {
        profileSetting("appIcon", of: name, current: settings.appIcon) ?? .grid
    }

    /// What right-clicking the profile's Dock icon lists: its pages, all its apps by letter, or
    /// the recently used ones (its hidden apps left out).
    func dockMenu(of name: String) -> DockTiles.Menu {
        let isCurrent = name == profiles.current
        let hidden = isCurrent ? hiddenIDs : ProfileSettings.hiddenApps(in: profiles.settings[name]) ?? hiddenIDs
        let apps = catalog.apps.filter { !hidden.contains($0.id) && $0.custom == nil }.map { app in
            meta[app.id]?.displayName.flatMap { $0.isEmpty ? nil : app.renamed($0) } ?? app
        }
        let byID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let entry = { (app: AppItem) in DockTiles.Entry(title: app.name, path: app.url.path) }
        var entries: [DockTiles.Entry] = []
        switch profileSetting("dockMenu", of: name, current: settings.dockMenu) ?? .pages {
        case .pages:
            let pages = isCurrent ? layout : profiles.saved[name] ?? []
            for (index, page) in pages.enumerated() {
                var items: [DockTiles.Entry] = []
                for item in page {
                    switch item {
                    case .app(let id):
                        if let app = byID[id] { items.append(entry(app)) }
                    case .folder(let folder):
                        let inside = folder.isSmart ? [] : folder.apps.compactMap { byID[$0] }.map(entry)
                        if !inside.isEmpty { items.append(DockTiles.Entry(title: folder.name, symbol: "folder", children: inside)) }
                    case .gap, .cover, .widget: continue
                    }
                }
                entries.append(DockTiles.Entry(title: String(localized: "第 \(index + 1) 页"), children: items))
            }
        case .alphabetical:
            // Grouped under their first letter (pinyin for Chinese names), so long lists stay usable.
            let groups = Dictionary(grouping: apps) { AppDelegate.indexLetter(for: $0) }
            for letter in groups.keys.sorted() {
                let sorted = groups[letter]!.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                entries.append(DockTiles.Entry(title: letter, children: sorted.map(entry)))
            }
        case .recent:
            entries = apps.filter { $0.lastUsedDate != nil }
                .sorted { $0.lastUsedDate! > $1.lastUsedDate! }
                .prefix(15).map(entry)
        }
        return DockTiles.Menu(entries: entries, settingsTitle: String(localized: "设置…"))
    }

    func startsAtLogin(_ name: String) -> Bool {
        profileSetting("startAtLogin", of: name, current: settings.startAtLogin) ?? false
    }

    var profilesByPriority: [String] {
        let current = currentProfile
        return [current] + profileNames.filter { $0 != current }
    }

    /// Posted when a profile's way to open may have changed.
    static let triggersChanged = Notification.Name("LaunchUS.profileTriggersChanged")
    /// The launcher closed: what was changed in it can now show in the Dock menus.
    static let didHideLauncher = Notification.Name("LaunchUS.didHideLauncher")

    /// Which profile a pinch with this many fingers opens.
    func profile(forPinch fingers: Int) -> String? {
        profilesByPriority.first { opening(for: $0).fingers.contains(fingers) }
    }

    /// Another profile that opens the same way, for the warnings in 通用.
    func otherProfile(opening matches: (Opening) -> Bool) -> String? {
        profileNames.first { $0 != currentProfile && matches(opening(for: $0)) }
    }

    // MARK: - Launch items and icons


    func customItem(_ id: String) -> CustomItem? { customItems.first { $0.id == id } }

    /// Adds or updates a launch item; new ones go to the end of the last page.
    func saveCustomItem(_ item: CustomItem) {
        if let i = customItems.firstIndex(where: { $0.id == item.id }) {
            customItems[i] = item
        } else {
            customItems.append(item)
        }
        CustomItemStore.save(customItems)
    }

    func deleteCustomItem(_ id: String) {
        customItems.removeAll { $0.id == id }
        CustomItemStore.save(customItems)
        if meta[id] != nil {
            meta[id] = nil
            LayoutStore.save(meta: meta)
            pruneIcons()
        }
    }

    /// Takes over a backup's launch items before `apply`, so restoring the layout doesn't drop
    /// them as uninstalled. The catalog picks them up at once.
    func withCustomItems(_ items: [CustomItem]?, _ apply: () -> Void) {
        if let items, items != customItems {
            customItems = items
            CustomItemStore.save(items)
        }
        apply()
    }

    /// `nil` goes back to the app's own icon.
    func setIcon(_ value: String?, for id: String) {
        setMeta(id) { $0.icon = value }
        pruneIcons()
    }

    private func pruneIcons() {
        CustomIcons.prune(keeping: Set(meta.values.compactMap(\.icon)))
    }

    var hiddenApps: [AppItem] {
        catalog.apps.filter { meta[$0.id]?.hidden == true }
            .map { app in meta[app.id]?.displayName.flatMap { $0.isEmpty ? nil : app.renamed($0) } ?? app }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
