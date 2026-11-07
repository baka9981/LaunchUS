import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let catalog = AppCatalog()
    private let settings = Settings.shared
    private var launcher: LauncherController!
    private var statusItem: NSStatusItem?
    private var keyTap: LaunchpadKeyTap?
    private var pinch: TrackpadPinch?
    private var hotCorner: HotCornerWatcher!
    private var appearanceWatch: NSKeyValueObservation?

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
        ICloudSync.onRemoteChange = { [weak self] backup in self?.launcher.model.applySynced(backup) }
        hotCorner = HotCornerWatcher { [weak self] in self?.launcher.toggle() }
        // Before the first scan, so icons are drawn light or dark only once.
        apply("appearance")
        appearanceWatch = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.apply("darkIcons") }
        }
        catalog.reload(force: true)
        AutoBackup.schedule()  // a starting point to go back to
        // After the first scan, so a layout from iCloud is reconciled against real apps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ICloudSync.start() }

        NSApp.mainMenu = makeMainMenu()
        for key in ["hotKey", "f4Key", "trackpadPinch", "hotCorner", "showMenuBarIcon", "appIcon"] { apply(key) }
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
            }
        }
    }

    private func apply(_ key: String) {
        switch key {
        case "hotKey":
            HotKeyCenter.register(settings.hotKey) { [weak self] in self?.launcher.toggle() }
            updateStatusTooltip()
        case "f4Key":
            keyTap = settings.f4Key ? LaunchpadKeyTap { [weak self] in self?.launcher.toggle() } : nil
        case "trackpadPinch", "pinchFingers":
            pinch?.invalidate()
            pinch = settings.trackpadPinch ? TrackpadPinch(
                fingers: settings.pinchFingers,
                changed: { [weak self] direction, progress in
                    self?.launcher.pinchChanged(opening: direction == .pinchIn, progress: progress)
                },
                ended: { [weak self] direction, commit in
                    self?.launcher.pinchEnded(opening: direction == .pinchIn, commit: commit)
                }
            ) : nil
        case "hotCorner":
            hotCorner.corner = settings.hotCorner
        case "showMenuBarIcon":
            if settings.showMenuBarIcon { setupStatusItem() } else if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        case "menuBarIcon":
            statusItem?.button?.image = settings.menuBarIcon.image
        case "showDockIcon":
            NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
            apply("appIcon")
            // Switching policy can deactivate the app (and close the launcher); bring the card back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if !self.launcher.isVisible { self.launcher.openSettings(tab: .general) }
            }
        case "appIcon":
            NSApp.applicationIconImage = IconArt.image(settings.appIcon)
        case "dynamicCalendar":
            launcher.catalog.refreshDynamicIcons()
        case "appearance":
            NSApp.appearance = settings.appearance.nsAppearance
            apply("darkIcons")
        case "darkIcons":
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            catalog.darkIcons = settings.darkIcons.resolve(dark: dark)
        case "columns", "rows", "sortOrder", "browseStyle", "folderBrowseStyle":
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
        case "blur", "backgroundSaturation", "displayMode", "hideDock", "background", "backgroundImage":
            launcher.displaySettingsChanged()
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
            if !launcher.isVisible { launcher.show() }
        case .toggle:
            launcher.toggle()
        case .close:
            if launcher.isVisible { launcher.hide(restoreFocus: true) }
        case .search(let text):
            if !launcher.isVisible { launcher.show() }
            DispatchQueue.main.async { model.query = text }
        case .folder(let name):
            if !launcher.isVisible { launcher.show() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.openFolder(named: name) }
        case .page(let n):
            if !launcher.isVisible { launcher.show() }
            DispatchQueue.main.async { model.goToPage(n - 1) }
        case .settings(let tab):
            launcher.openSettings(tab: tab)
        case .profile(let name):
            if !model.switchProfile(named: name) { NSLog("LaunchUS: no layout named \(name)") }
        case .openAll(let name):
            if let folder = model.folder(named: name) { model.openAll(folder.id) }
            else { NSLog("LaunchUS: no folder named \(name)") }
        }
    }

    /// Opening LaunchUS.app again (Finder, Dock, `open`) toggles the launcher.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcher?.toggle()  // nil while quitting to reopen from /Applications
        return false
    }

    // MARK: - Menus

    /// The menu bar icon has no menu: clicking it opens (or closes) the launcher.
    private func setupStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = settings.menuBarIcon.image
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        updateStatusTooltip()
    }

    private func updateStatusTooltip() {
        statusItem?.button?.toolTip = HotKeyCenter.isRegistered
            ? String(localized: "打开启动台（\(settings.hotKey.display)）") : String(localized: "打开启动台")
    }

    @objc private func statusItemClicked() { launcher.toggle() }

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
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard launcher != nil else { return nil }
        let menu = NSMenu()
        let model = launcher.model
        let byID = Dictionary(model.visibleApps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        switch settings.dockMenu {
        case .pages:
            addPages(to: menu, byID: byID)
        case .alphabetical:
            let apps = model.visibleApps.filter { !$0.isCustom }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            // Grouped under their first letter (pinyin for Chinese names), so long lists stay usable.
            let groups = Dictionary(grouping: apps) { Self.indexLetter(for: $0) }
            for letter in groups.keys.sorted() {
                let sub = NSMenu()
                groups[letter]!.forEach { sub.addItem(appItem($0)) }
                let letterItem = NSMenuItem(title: letter, action: nil, keyEquivalent: "")
                letterItem.submenu = sub
                menu.addItem(letterItem)
            }
        case .recent:
            let recent = model.visibleApps.filter { !$0.isCustom && $0.lastUsedDate != nil }
                .sorted { $0.lastUsedDate! > $1.lastUsedDate! }
                .prefix(15)
            recent.forEach { menu.addItem(appItem($0)) }
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "设置…"), #selector(openSettings)))
        return menu
    }

    /// "A"…"Z" from the name (or its pinyin), "#" for anything else.
    static func indexLetter(for app: AppItem) -> String {
        let first = (Pinyin.keys(for: app.name).first ?? app.name).prefix(1).uppercased()
        return first.count == 1 && ("A"..."Z").contains(first) ? first : "#"
    }

    private func addPages(to menu: NSMenu, byID: [String: AppItem]) {
        let model = launcher.model
        for (index, page) in model.layout.enumerated() {
            let pageMenu = NSMenu()
            for entry in page {
                switch entry {
                case .app(let id):
                    if let app = byID[id] { pageMenu.addItem(appItem(app)) }
                case .folder(let folder):
                    let apps = folder.isSmart ? [] : folder.apps.compactMap { byID[$0] }
                    guard !apps.isEmpty else { continue }
                    let sub = NSMenu()
                    apps.forEach { sub.addItem(appItem($0)) }
                    let folderItem = NSMenuItem(title: folder.name, action: nil, keyEquivalent: "")
                    folderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                    folderItem.submenu = sub
                    pageMenu.addItem(folderItem)
                }
            }
            let pageItem = NSMenuItem(title: String(localized: "第 \(index + 1) 页"), action: nil, keyEquivalent: "")
            pageItem.submenu = pageMenu
            menu.addItem(pageItem)
        }
    }

    private func appItem(_ app: AppItem) -> NSMenuItem {
        let menuItem = NSMenuItem(title: app.name, action: #selector(launchFromMenu(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = app.url
        let icon = NSWorkspace.shared.icon(forFile: app.url.path)
        icon.size = NSSize(width: 16, height: 16)
        menuItem.image = icon
        return menuItem
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
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
