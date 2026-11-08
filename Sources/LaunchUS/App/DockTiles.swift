import AppKit

/// A Dock icon of its own for every profile with 程序坞图标 on, besides the default one (that
/// one is LaunchUS's own icon). macOS gives each running app one Dock icon, so each profile's is
/// a small stand-in app in the data folder (DockTiles/<title>.app) that runs this same program
/// (`TileApp`): it shows the profile's icon and name, opens the profile when clicked and lists
/// its apps on right-click. LaunchUS starts and stops them, and they quit with it.
enum DockTiles {
    /// What a stand-in reads from its bundle: which profile it is and how to reach LaunchUS.
    struct Info: Codable, Equatable {
        var profile: String
        var title: String
        var icon: Int
        var mainApp: String
        /// Which build of LaunchUS the stand-in's copy of it is.
        var build: String = ""
        var mainBundleID: String
    }

    /// One line of a Dock menu: an app to open, or a submenu.
    struct Entry: Codable, Equatable {
        var title: String
        var path: String?
        var symbol: String?
        var children: [Entry]?
    }

    /// The profile's Dock menu, plus 设置… at the end.
    struct Menu: Codable, Equatable {
        var entries: [Entry]
        var settingsTitle: String
    }

    static let changed = Notification.Name("local.launchus.dockTilesChanged")
    static var directory: URL { LayoutStore.directory.appendingPathComponent("DockTiles", isDirectory: true) }
    static let infoName = "tile.json"
    static let menuName = "menu.json"

    static func bundleID(for profile: String, main: String) -> String {
        main + ".tile." + profile.utf8.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether this process is a stand-in: it runs from DockTiles/<title>.app.
    static var runningAsTile: Bool {
        // Its own copy of LaunchUS (LaunchServices resolves links, so it can't be one).
        Bundle.main.bundlePath.contains("/DockTiles/")
    }

    // MARK: - LaunchUS's side

    struct Wanted {
        var profile: String
        var title: String
        var icon: AppIconStyle
        var menu: Menu
    }

    /// Makes the running stand-ins match `wanted`: starts missing ones, refreshes their icon
    /// and menu, and stops (and removes) the others.
    @MainActor static func update(_ wanted: [Wanted]) {
        let main = Bundle.main
        guard let mainID = main.bundleIdentifier, let executable = main.executableURL else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var keep = Set<String>()
        var changedAny = false
        for tile in wanted {
            let id = bundleID(for: tile.profile, main: mainID)
            let app = directory.appendingPathComponent(fileName(tile.title) + ".app", isDirectory: true)
            keep.insert(app.lastPathComponent)
            let info = Info(profile: tile.profile, title: tile.title, icon: tile.icon.rawValue,
                            mainApp: main.bundlePath, build: stamp(of: executable), mainBundleID: mainID)
            let state = build(app, id: id, info: info, executable: executable)
            guard state != .failed else { continue }
            write(tile.menu, to: app.appendingPathComponent("Contents/Resources/\(menuName)"))
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            if running.isEmpty {
                start(app, id: id)
            } else if state == .rebuilt {
                // A new LaunchUS: the old copy quits, and the new one takes its place.
                running.forEach { $0.terminate() }
                start(app, id: id)
            } else if state == .infoChanged {
                changedAny = true
            }
        }
        if changedAny {
            DistributedNotificationCenter.default().postNotificationName(changed, object: nil, userInfo: nil, deliverImmediately: true)
        }
        // Stand-ins of profiles that no longer want one, were renamed or removed.
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".app") && !keep.contains(name) {
            let app = directory.appendingPathComponent(name, isDirectory: true)
            if let id = Bundle(url: app)?.bundleIdentifier {
                NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
            }
            try? fm.removeItem(at: app)
        }
    }

    /// Starts the stand-in once no copy of it is running: opening a running one is a click on
    /// its Dock icon, which would open its profile.
    private static func start(_ app: URL, id: String, tries: Int = 20) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else {
            if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { start(app, id: id, tries: tries - 1) }
            }
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: app, configuration: config)
    }

    private static func stamp(of executable: URL) -> String {
        let values = try? executable.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(executable.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    private enum BuildState { case current, infoChanged, rebuilt, failed }

    /// A file name for the bundle; the Dock shows the name in its Info.plist.
    static func fileName(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.hasPrefix(".") ? "_" + cleaned : cleaned
    }

    /// Writes the stand-in's bundle when it's missing or out of date. Returns whether it's
    /// there and what changed.
    private static func build(_ app: URL, id: String, info: Info, executable: URL) -> BuildState {
        let fm = FileManager.default
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let infoURL = resources.appendingPathComponent(infoName)
        let old = (try? Data(contentsOf: infoURL)).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
        if let old, old.build == info.build {
            guard old != info else { return .current }
            write(info, to: infoURL)
            return .infoChanged
        }
        // Missing, or a different LaunchUS (an update, or another copy): build it again.
        try? fm.removeItem(at: app)
        do {
            try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            // A copy (an APFS clone, so it takes no space): started through a link, it would be
            // LaunchUS itself.
            try fm.copyItem(at: executable, to: contents.appendingPathComponent("MacOS/LaunchUS"))
            let frameworks = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Frameworks")
            try fm.createSymbolicLink(atPath: contents.appendingPathComponent("Frameworks").path,
                                      withDestinationPath: frameworks.path)
            let plist: [String: Any] = [
                "CFBundleExecutable": "LaunchUS",
                "CFBundleIdentifier": id,
                "CFBundleName": info.title,
                "CFBundleDisplayName": info.title,
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "1.0",
                "LSMinimumSystemVersion": Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") ?? "26.0",
                "NSPrincipalClass": "NSApplication",
                "NSHighResolutionCapable": true,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            write(info, to: infoURL)
            return .rebuilt
        } catch {
            NSLog("LaunchUS: Dock icon for \(info.title) failed: \(error)")
            return .failed
        }
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), (try? Data(contentsOf: url)) != data else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Menu items for `entries`; an app's item calls `action` with its path.
    @MainActor static func menuItems(_ entries: [Entry], target: AnyObject, action: Selector) -> [NSMenuItem] {
        entries.map { entry in
            let menuItem = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            if let children = entry.children {
                let sub = NSMenu()
                menuItems(children, target: target, action: action).forEach(sub.addItem)
                menuItem.submenu = sub
            } else if let path = entry.path {
                menuItem.action = action
                menuItem.target = target
                menuItem.representedObject = path
                let icon = NSWorkspace.shared.icon(forFile: path)
                icon.size = NSSize(width: 16, height: 16)
                menuItem.image = icon
            }
            if let symbol = entry.symbol {
                menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            return menuItem
        }
    }

    /// The profile's icon with its name on it, so icons of the same style tell apart.
    @MainActor static func icon(_ style: AppIconStyle, title: String?, size: CGFloat = 512) -> NSImage {
        let base = IconArt.image(style, size: size)
        guard let title, !title.isEmpty else { return base }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            base.draw(in: rect)
            let font = NSFont.systemFont(ofSize: size * 0.15, weight: .bold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
            let text = NSAttributedString(string: title, attributes: attributes)
            let textHeight = ceil(font.ascender - font.descender)
            let width = min(rect.width * 0.86, ceil(text.size().width) + size * 0.12)
            let label = NSRect(x: rect.midX - width / 2, y: rect.minY + size * 0.06, width: width, height: textHeight + size * 0.04)
            NSColor.black.withAlphaComponent(0.62).setFill()
            NSBezierPath(roundedRect: label, xRadius: label.height / 2, yRadius: label.height / 2).fill()
            text.draw(in: label.insetBy(dx: size * 0.04, dy: size * 0.02))
            return true
        }
    }
}

/// A profile's own Dock icon: this program, run from a stand-in bundle (`DockTiles`).
@MainActor
final class TileApp: NSObject, NSApplicationDelegate {
    private let bundle: URL
    private var info: DockTiles.Info?

    init(bundle: URL) {
        self.bundle = bundle
        super.init()
    }

    static func run() -> Never {
        // argv[0] is …/DockTiles/<title>.app/Contents/MacOS/LaunchUS.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = NSApplication.shared
        let delegate = TileApp(bundle: bundle)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }

    private var resources: URL { bundle.appendingPathComponent("Contents/Resources") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        reload()
        guard info != nil else { NSApp.terminate(nil); return }
        DistributedNotificationCenter.default().addObserver(forName: DockTiles.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        // Quits with LaunchUS.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quitWithoutLaunchUS() }
        }
        // Opened from the Dock while LaunchUS wasn't running (kept in the Dock): start it on this profile.
        if NSRunningApplication.runningApplications(withBundleIdentifier: info!.mainBundleID).isEmpty {
            openProfile()
        }
    }

    private func reload() {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent(DockTiles.infoName)),
              let info = try? JSONDecoder().decode(DockTiles.Info.self, from: data) else { return }
        self.info = info
        NSApp.applicationIconImage = DockTiles.icon(AppIconStyle(rawValue: info.icon) ?? .grid, title: info.title)
    }

    private func quitWithoutLaunchUS() {
        guard let info else { return }
        // Give a relaunch (language change, update) a moment before deciding.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if NSRunningApplication.runningApplications(withBundleIdentifier: info.mainBundleID).isEmpty {
                NSApp.terminate(nil)
            }
        }
    }

    /// Clicked in the Dock: open (or close) its profile in LaunchUS.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openProfile()
        return false
    }

    private func openProfile() {
        guard let info else { return }
        var parts = URLComponents()
        parts.scheme = URLCommand.scheme
        parts.host = "toggle"
        parts.queryItems = [URLQueryItem(name: "profile", value: info.profile)]
        send(parts.url)
    }

    private func send(_ url: URL?) {
        guard let url, let info else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: info.mainApp), configuration: config)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent(DockTiles.menuName)),
              let spec = try? JSONDecoder().decode(DockTiles.Menu.self, from: data) else { return nil }
        let menu = NSMenu()
        DockTiles.menuItems(spec.entries, target: self, action: #selector(launch(_:))).forEach(menu.addItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: spec.settingsTitle, action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    @objc private func launch(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openSettings() {
        send(URL(string: "\(URLCommand.scheme)://settings"))
    }
}
