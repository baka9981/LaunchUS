import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let catalog = AppCatalog()
    private let settings = Settings.shared
    private var launcher: LauncherController!
    /// Each profile's own menu bar icon, by profile name.
    private var statusItems: [String: NSStatusItem] = [:]
    /// Started by the Mac at login, not by the user.
    private var launchedAtLogin = false
    private var keyTap: LaunchpadKeyTap?
    private var pinch: TrackpadPinch?
    /// The profile the F4 key opens.
    private var f4Profile: String?
    /// Corners that open a particular layout profile.
    private var profileCorners: [HotCornerWatcher] = []
    /// Mouse buttons clicked quickly to open a particular layout profile.
    private var profileClicks: [MouseClickWatcher] = []
    private var appearanceWatch: NSKeyValueObservation?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened from the installer disk: offer to move to /Applications and reopen from there.
        if InstallLocation.checkAtLaunch() { return }
        let firstRun = !FileManager.default.fileExists(atPath: LayoutStore.layoutURL.path)
        launcher = LauncherController(catalog: catalog)
        SettingsPanes.warmUp()
        launcher.model.settingsActions = SettingsActions(
            rescan: { [weak self] done in
                guard let self else { return }
                let before = Set(catalog.apps.map(\.id))
                catalog.reload(force: true) { apps in
                    let after = Set(apps.map(\.id))
                    done(RescanResult(total: apps.count, added: after.subtracting(before).count,
                                      removed: before.subtracting(after).count))
                }
            }
        )
        Updater.shared.start()
        Heartbeat.smartBarInUse = { [weak self] in !(self?.launcher.model.categoryTabs.isEmpty ?? true) }
        Heartbeat.start()
        License.shared.checkIfDue()
        Feedback.shared.start()
        AppUsage.shared.start()
        ICloudSync.onRemoteChange = { [weak self] backup in self?.launcher.model.applySynced(backup) }
        // Before the first scan, so icons are drawn light or dark only once.
        apply("appearance")
        appearanceWatch = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.apply("darkIcons") }
        }
        catalog.reload(force: true) { [weak self] _ in
            self?.openLoginProfile()
            self?.updateDockTiles()  // their menus list the apps found
        }
        AutoBackup.schedule()  // a starting point to go back to
        // After the first scan, so a layout from iCloud is reconciled against real apps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ICloudSync.start() }

        NSApp.mainMenu = makeMainMenu()
        HotKeyGroup.profiles.action = { [weak self] name in self?.launcher.toggleProfile(name, via: .hotKey) }
        // Before start at login was each profile's, LaunchUS's one login item was the active profile's.
        if UserDefaults.app.object(forKey: "startAtLogin") == nil, LoginItem.isEnabled { settings.startAtLogin = true }
        for key in ["profileTriggers", "appIcon"] { apply(key) }
        // What was changed in the launcher shows in the profiles' Dock menus.
        NotificationCenter.default.addObserver(forName: LauncherModel.didHideLauncher, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDockTiles() }
        }
        NotificationCenter.default.addObserver(forName: LauncherModel.triggersChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply("profileTriggers") }
        }
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] note in
            let key = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.apply(key) }
        }
        // Accessibility may have been granted in System Settings since the F4 key was turned on.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.keyTap == nil { self?.apply("f4Key") } }
        }

        // Debug aid: LAUNCHUS_PERMISSION=fda|ax opens the permission helper at launch.
        if let kind = ProcessInfo.processInfo.environment["LAUNCHUS_PERMISSION"] {
            PermissionHelper.shared.request(kind == "ax" ? .accessibility : .fullDiskAccess)
        }
        // Debug aid: LAUNCHUS_CHECK_UPDATES=1 checks for updates at launch.
        if ProcessInfo.processInfo.environment["LAUNCHUS_CHECK_UPDATES"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Updater.shared.checkForUpdates() }
        }
        // Once a permission is switched on, go back to where it was asked for.
        PermissionHelper.shared.onGranted = { [weak self] kind in
            guard let self else { return }
            switch kind {
            case .fullDiskAccess:
                if !self.launcher.isVisible { self.launcher.show() }  // resumes the uninstall card
            case .accessibility:
                self.apply("f4Key")
                self.launcher.openSettings(tab: .general)
            }
        }

        // Debug aid: LAUNCHUS_GUIDE=1 shows the walkthrough at launch; LAUNCHUS_DEMO skips it.
        let env = ProcessInfo.processInfo.environment
        if (env["LAUNCHUS_DEMO"] == nil && (firstRun || !UserDefaults.app.bool(forKey: "didShowGuide")))
            || env["LAUNCHUS_GUIDE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.launcher.openGuide() }
        } else if env["LAUNCHUS_SNAPSHOT"] != nil || env["LAUNCHUS_SHOW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.launcher.show()
                // Also open a folder when only showing (snapshots open theirs themselves).
                if env["LAUNCHUS_SNAPSHOT"] == nil, let name = env["LAUNCHUS_FOLDER"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.launcher.model.openFolder(named: name)
                    }
                }
                // …or 编辑智能栏.
                if env["LAUNCHUS_SNAPSHOT"] == nil, env["LAUNCHUS_SMARTBAR"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.launcher.model.sheet = .editSmartFolder(nil, query: "")
                    }
                }
            }
        }
    }

    /// Writes the chosen icon onto the app itself, so the Dock and Finder keep it after LaunchUS quits.
    /// An update replaces the whole app and drops it, so it's checked again at every launch.
    private func keepAppIcon(_ style: AppIconStyle) {
        guard ProcessInfo.processInfo.environment["LAUNCHUS_DEMO"] == nil else { return }
        let path = Bundle.main.bundlePath
        let hasCustom = FileManager.default.fileExists(atPath: path + "/Icon\r")
        let defaults = UserDefaults.standard
        // The default style is the icon the app ships with: only a custom one left over needs taking off.
        if style == .grid ? !hasCustom : hasCustom && defaults.integer(forKey: "appliedAppIcon") == style.rawValue {
            return
        }
        guard FileManager.default.isWritableFile(atPath: path) else { return }
        let image = style == .grid ? nil : IconArt.image(style, size: 1024)
        if NSWorkspace.shared.setIcon(image, forFile: path, options: []) {
            defaults.set(style.rawValue, forKey: "appliedAppIcon")
        }
    }

    private func apply(_ key: String) {
        switch key {
        // Every profile opens its own way: the current one's shortcut, F4, pinch and corner are
        // in the settings, the others' in their saved settings. Used, they open that profile.
        case "hotKey":
            updateShortcuts()
        case "f4Key":
            updateF4Key()
        case "trackpadPinch", "pinchFingers":
            updatePinch()
        case "hotCorner":
            updateCorners()
        case "clickButton", "clickCount":
            updateClicks()
        case "profileTriggers":
            // Also posted when profiles are switched, added, renamed or removed.
            updateShortcuts()
            updateF4Key()
            updatePinch()
            updateCorners()
            updateClicks()
            updateStatusItems()
            updateLoginItem()
            updateDock()
        case "showMenuBarIcon", "menuBarIcon":
            updateStatusItems()
        case "startAtLogin":
            updateLoginItem()
        case "showDockIcon":
            updateDock()
        case "dockMenu":
            updateDockTiles()
        case "appIcon":
            // LaunchUS's own icon is the default profile's; the others' are on their stand-ins.
            let style = launcher.model.appIcon(of: "")
            NSApp.applicationIconImage = IconArt.image(style)
            keepAppIcon(style)
            updateDockTiles()
        case "dynamicCalendar":
            launcher.catalog.refreshDynamicIcons()
        case "appearance":
            NSApp.appearance = settings.appearance.nsAppearance
            apply("darkIcons")
        case "darkIcons":
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            catalog.darkIcons = settings.darkIcons.resolve(dark: dark)
        case "columns", "rows", "sortOrder", "browseStyle", "folderBrowseStyle", "freePlacement":
            launcher.model.settingsChanged()
        case "autoBackupCount":
            if settings.autoBackupCount > 0 {
                AutoBackup.prune(keeping: settings.autoBackupCount)
                AutoBackup.schedule(after: 0)
            }
        case "iCloudSync":
            ICloudSync.start()
        case "extraAppFolders":
            catalog.reload(force: true)
        case "hiddenDotEntrance", "hiddenSlotEntrance", "hiddenSlotPage":
            launcher.model.refresh()
        case "showFrequent":
            launcher.model.settingsChanged()
        case "showBadges":
            launcher.badgesSettingChanged()
        case "blur", "backgroundSaturation", "displayMode", "windowSize", "hideDock", "background", "backgroundImage":
            launcher.displaySettingsChanged()
            // The ring always turns pages: the scrolling grid's cells come and go with it.
            if key == "displayMode" { launcher.model.settingsChanged() }
        default:
            break
        }
    }

    /// `launchus://…` links.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard launcher != nil else { return }  // still asking about the install location
        for url in urls {
            guard let command = URLCommand(url: url) else {
                NSLog("LaunchUS: unknown link \(url.absoluteString)")
                continue
            }
            run(command)
        }
    }

    /// A Focus filter turned on (with a layout name) or off (nil): switch to it, then back.
    func focusLayout(_ name: String?) {
        let model = launcher.model
        let key = "focusPreviousProfile"
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            if UserDefaults.app.string(forKey: key) == nil {
                UserDefaults.app.set(model.currentProfile, forKey: key)
            }
            if !model.switchProfile(named: name) { NSLog("LaunchUS: no layout named \(name)") }
        } else if let previous = UserDefaults.app.string(forKey: key) {
            UserDefaults.app.removeObject(forKey: key)
            if model.profileNames.contains(previous) { model.switchProfile(previous) }
        }
    }

    func run(_ command: URLCommand) {
        let model = launcher.model
        switch command {
        case .open:
            if !launcher.isVisible { launcher.show(via: .link) }
        case .toggle:
            launcher.toggle(via: .link)
        case .toggleProfile(let text):
            // A profile's own Dock icon was clicked.
            guard let name = LayoutProfiles.resolve(text, in: model.profiles) else {
                NSLog("LaunchUS: no layout named \(text)")
                break
            }
            launcher.toggleProfile(name, via: .appIcon)
        case .close:
            if launcher.isVisible { launcher.hide(restoreFocus: true, force: true) }
        case .search(let text):
            if !launcher.isVisible { launcher.show(via: .link) }
            DispatchQueue.main.async { model.query = text }
        case .folder(let name):
            if !launcher.isVisible { launcher.show(via: .link) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.openFolder(named: name) }
        case .page(let n):
            if !launcher.isVisible { launcher.show(via: .link) }
            DispatchQueue.main.async { model.goToPage(n - 1) }
        case .settings(let tab):
            launcher.openSettings(tab: tab)
        case .profile(let name):
            if !model.switchProfile(named: name) { NSLog("LaunchUS: no layout named \(name)") }
        case .openAll(let name):
            if let folder = model.folder(named: name) { model.openAll(folder.id) }
            else { NSLog("LaunchUS: no folder named \(name)") }
        case .widgets:
            if !launcher.isVisible { launcher.show(via: .link) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.openWidgetGallery() }
        case .tool(let request):
            MCPBridge.answer(request, model: model)
        }
    }

    /// Opening LaunchUS.app again (Finder, Dock, `open`) toggles the launcher.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The Dock icon is the default profile's; opened from Finder without one, the current profile.
        guard let launcher else { return false }  // nil while quitting to reopen from /Applications
        if NSApp.activationPolicy() == .regular { launcher.toggleProfile("", via: .appIcon) } else { launcher.toggle(via: .appIcon) }
        return false
    }

    // MARK: - Menus

    /// One menu bar icon for every profile that has it on. An icon has no menu: clicking it
    /// opens (or closes) its own profile.
    private func updateStatusItems() {
        let model = launcher.model
        let wanted = Dictionary(model.profileNames.compactMap { name in model.menuBarIcon(of: name).map { (name, $0) } },
                                uniquingKeysWith: { a, _ in a })
        for (name, item) in statusItems where wanted[name] == nil {
            NSStatusBar.system.removeStatusItem(item)
            statusItems[name] = nil
        }
        for name in model.profileNames {  // left to right in the order the profiles are listed
            guard let style = wanted[name] else { continue }
            let item = statusItems[name] ?? {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.target = self
                item.button?.action = #selector(statusItemClicked(_:))
                item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
                statusItems[name] = item
                return item
            }()
            item.button?.identifier = NSUserInterfaceItemIdentifier(name)
            if item.button?.image?.name() != style.rawValue {
                let image = style.image
                image?.setName(style.rawValue)
                item.button?.image = image
            }
        }
        updateStatusTooltip()
    }

    /// The default profile's Dock icon is LaunchUS's own; every other profile with one on gets
    /// a stand-in app of its own (`DockTiles`), since an app has only one Dock icon.
    private func updateDock() {
        let model = launcher.model
        let policy: NSApplication.ActivationPolicy = model.showsDockIcon("") ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            apply("appIcon")
            // Switching policy can deactivate the app (and close the launcher); bring back the
            // card it was changed on.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard !self.launcher.isVisible else { return }
                self.launcher.openSettings(tab: .general)
            }
        }
        updateDockTiles()
    }

    private func updateDockTiles() {
        let model = launcher.model
        DockTiles.update(model.profileNames.filter { !$0.isEmpty && model.showsDockIcon($0) }.map { name in
            DockTiles.Wanted(profile: name, title: LayoutProfiles.title(name), icon: model.appIcon(of: name), menu: model.dockMenu(of: name))
        })
    }

    /// LaunchUS starts with the Mac while any profile does; that one then opens (`openLoginProfile`).
    private func updateLoginItem() {
        let model = launcher.model
        let wanted = model.profileNames.contains { model.startsAtLogin($0) }
        if wanted ? !(LoginItem.isEnabled || LoginItem.needsApproval) : (LoginItem.isEnabled || LoginItem.needsApproval) {
            LoginItem.set(wanted)
        }
    }

    /// Started at login: switch to the profile that starts with the Mac, unless it's already the
    /// active one. Nothing is shown, as before.
    private func openLoginProfile() {
        guard launchedAtLogin else { return }
        launchedAtLogin = false
        let model = launcher.model
        guard !model.startsAtLogin(model.currentProfile),
              let name = model.profileNames.first(where: { model.startsAtLogin($0) }) else { return }
        model.switchProfile(name, reopen: false)
    }

    private func updateShortcuts() {
        let model = launcher.model
        let own = settings.hotKey
        var others: [String: HotKeySpec] = [:]
        for name in model.profileNames where name != model.currentProfile {
            guard let spec = model.opening(for: name).hotKey else { continue }
            let same = { (other: HotKeySpec) in other.keyCode == spec.keyCode && other.modifiers == spec.modifiers }
            if let own, same(own) { continue }
            if others.values.contains(where: same) { continue }
            others[name] = spec
        }
        // The others first, so a shortcut one of them just gave up is free for the current one.
        HotKeyGroup.profiles.update(others)
        HotKeyCenter.register(own) { [weak self] in self?.launcher.toggle(via: .hotKey) }
        updateStatusTooltip()
    }

    private func updateF4Key() {
        let model = launcher.model
        f4Profile = model.profilesByPriority.first { model.opening(for: $0).f4 }
        if f4Profile == nil {
            keyTap = nil
        } else if keyTap == nil {
            keyTap = LaunchpadKeyTap { [weak self] in
                guard let self, let name = self.f4Profile else { return }
                self.launcher.toggleProfile(name, via: .f4)
            }
        }
    }

    private func updatePinch() {
        let model = launcher.model
        let counts = model.profileNames.reduce(into: Set<Int>()) { $0.formUnion(model.opening(for: $1).fingers) }
        pinch?.invalidate()
        pinch = TrackpadPinch(
            fingers: counts,
            changed: { [weak self] direction, progress, fingers in
                guard let self else { return }
                let opening = direction == .pinchIn
                if opening, !self.launcher.isVisible, let name = self.launcher.model.profile(forPinch: fingers) {
                    self.launcher.model.switchProfile(name)
                }
                self.launcher.pinchChanged(opening: opening, progress: progress)
            },
            ended: { [weak self] direction, commit in
                self?.launcher.pinchEnded(opening: direction == .pinchIn, commit: commit)
            }
        )
    }

    private func updateClicks() {
        let model = launcher.model
        profileClicks.forEach { $0.invalidate() }
        var taken = Set<Int>()
        profileClicks = model.profilesByPriority.compactMap { name in
            let opening = model.opening(for: name)
            guard opening.clickButton >= 0, taken.insert(opening.clickButton).inserted else { return nil }
            return MouseClickWatcher(button: opening.clickButton, count: opening.clickCount) { [weak self] in
                self?.launcher.toggleProfile(name, via: .clicks)
            }
        }
    }

    private func updateCorners() {
        let model = launcher.model
        profileCorners.forEach { $0.corner = .off }  // removes their event monitors
        var taken = Set<HotCorner>()
        profileCorners = model.profilesByPriority.compactMap { name in
            let corner = model.opening(for: name).corner
            guard corner != .off, taken.insert(corner).inserted else { return nil }
            let watcher = HotCornerWatcher { [weak self] in self?.launcher.toggleProfile(name, via: .hotCorner) }
            watcher.corner = corner
            return watcher
        }
    }

    private func updateStatusTooltip() {
        let model = launcher.model
        for (name, item) in statusItems {
            let key = name == model.currentProfile ? (HotKeyCenter.isRegistered ? settings.hotKey : nil) : model.opening(for: name).hotKey
            let title = LayoutProfiles.title(name)
            item.button?.toolTip = if let key = key?.display {
                String(localized: "打开「\(title)」（\(key)）")
            } else {
                String(localized: "打开「\(title)」")
            }
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let name = sender.identifier?.rawValue ?? launcher.model.currentProfile
        if name == launcher.model.currentProfile { launcher.toggle(via: .menuBar) } else { launcher.toggleProfile(name, via: .menuBar) }
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(item(String(localized: "关于 LaunchUS"), #selector(openAbout)))
        if Updater.shared.isConfigured { appMenu.addItem(item(String(localized: "检查更新…"), #selector(checkForUpdates))) }
        appMenu.addItem(.separator())
        appMenu.addItem(item(String(localized: "设置…"), #selector(openSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: String(localized: "隐藏 LaunchUS"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: String(localized: "退出 LaunchUS"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Standard editing commands, so ⌘C / ⌘V / ⌘Z work in text fields.
        let edit = NSMenu(title: String(localized: "编辑"))
        edit.addItem(NSMenuItem(title: String(localized: "撤销"), action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: String(localized: "重做"), action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: String(localized: "剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: String(localized: "拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: String(localized: "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: String(localized: "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let window = NSMenu(title: String(localized: "窗口"))
        window.addItem(NSMenuItem(title: String(localized: "关闭"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }

    /// Right-click on the Dock icon: every page, with folders as submenus.
    /// The default profile's menu (`LauncherModel.dockMenu(of:)`); the other profiles' Dock
    /// icons show their own.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard launcher != nil else { return nil }
        let spec = launcher.model.dockMenu(of: "")
        let menu = NSMenu()
        DockTiles.menuItems(spec.entries, target: self, action: #selector(launchFromMenu(_:))).forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(item(spec.settingsTitle, #selector(openSettings)))
        return menu
    }

    /// "A"…"Z" from the name (or its pinyin), "#" for anything else.
    static func indexLetter(for app: AppItem) -> String {
        let first = (Pinyin.keys(for: app.name).first ?? app.name).prefix(1).uppercased()
        return first.count == 1 && ("A"..."Z").contains(first) ? first : "#"
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }
    @objc private func openSettings() { launcher.openSettings(tab: nil) }
    @objc private func openAbout() { launcher.openSettings(tab: .advanced) }
    @objc private func launchFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
    }
}
