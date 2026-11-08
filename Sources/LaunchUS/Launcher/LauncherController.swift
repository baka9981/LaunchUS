import AppKit
import Carbon.HIToolbox
import SwiftUI

final class LauncherPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the menu bar and the Dock so the launcher covers the whole screen.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class LauncherController {
    let catalog: AppCatalog
    let model: LauncherModel
    private let wallpaper = WallpaperProvider()
    let panel = LauncherPanel()
    /// The settings window and the editor cards, windows of their own above the launcher.
    private var cards: CardWindows!
    let settings = Settings.shared
    var monitors: [Any] = []
    /// Clicks in other apps while the launcher is up (works even if activation didn't stick).
    private var outsideClickMonitor: Any?
    private var isHiding = false
    private var hideToken = 0
    /// Set while an icon is being dragged out to the Dock, Finder or another app.
    private var dragOut: DragOutSource?
    /// `dragOutURL()` for the item being dragged, so it isn't looked up on every mouse event.
    var dragOutTarget: (id: String, url: URL?)?

    // Trackpad swipe state
    var rawDrag: CGFloat = 0
    var lastWheelEvent = Date.distantPast
    var lastWheelFlip = Date.distantPast
    /// Lines turned in the current spin, and whether it has flipped yet.
    var wheelTurned = 0.0
    private let running = RunningApps()
    private let dockBadges = DockBadges()
    private var lastDockBadges: [String: String] = [:]
    private var hitchLog: HitchLog?
    /// Shows the ⌘ numbers after a short hold, so ⌘W and friends don't flash them.
    var commandHold: DispatchWorkItem?

    init(catalog: AppCatalog) {
        self.catalog = catalog
        model = LauncherModel(catalog: catalog)
        model.onLaunch = { [weak self] app in self?.launch(app) }
        HotKeyGroup.apps.action = { [weak self] id in self?.openFromShortcut(id) }
        model.onOpenFiles = { [weak self] urls, app in self?.open(urls, with: app) }
        model.onOpenGroup = { [weak self] apps in self?.openGroup(apps) }
        model.onClose = { [weak self] in self?.hide(restoreFocus: true) }
        PermissionHelper.shared.hideLauncher = { [weak self] in
            if self?.isVisible == true { self?.hide(restoreFocus: true, force: true) }
        }
        Updater.shared.hideLauncher = { [weak self] in
            if self?.isVisible == true { self?.hide(restoreFocus: false, force: true) }
        }
        catalog.onChange = { [weak self] in
            self?.model.catalogChanged()
            // Installed or removed apps change which icon each Dock badge belongs to.
            self?.remapBadges()
        }
        catalog.iconPriority = { [weak self] in
            guard let model = self?.model, model.pages.indices.contains(model.currentPage) else { return [] }
            return model.pages[model.currentPage].flatMap { entry -> [String] in
                switch entry {
                case .app(let app): [app.id]
                case .folder(_, let apps): apps.prefix(9).map(\.id)
                case .gap, .widget: []
                }
            }
        }
        running.onChange = { [weak self] ids in
            if self?.model.runningIDs != ids { self?.model.runningIDs = ids }
        }
        running.publish()
        dockBadges.onChange = { [weak self] byPath in
            guard let self, byPath != self.lastDockBadges else { return }
            self.lastDockBadges = byPath
            self.remapBadges()
        }

        cards = CardWindows(model: model, launcher: panel) { [weak self] in self?.isVisible == true }
        cards.showLauncher = { [weak self] in self?.show() }

        configurePanel(for: targetScreen())
        panel.contentView = LauncherHostingView(rootView: LauncherView(model: model, wallpaper: wallpaper))
        hitchLog = HitchLog(view: panel.contentView!) { [weak self] in
            guard let model = self?.model else { return "" }
            return "page \(model.currentPage) folder \(model.openFolderID != nil) query \(model.query.count)"
        }

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The Touch ID / password prompt belongs to another process.
                guard let self, !self.model.isAuthenticating, self.dragOut == nil else { return }
                // The settings window stays, as an ordinary window other apps can come in front of.
                self.hide(restoreFocus: false, keepSettings: true)
            }
        }
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            // Also posted for menu bar / Dock changes, so only react to real display changes.
            MainActor.assumeIsolated {
                guard let self, self.isVisible,
                      !NSScreen.screens.contains(where: { self.frame(on: $0) == self.panel.frame }) else { return }
                // With the settings open the launcher stays; it's fitted to the new screen instead.
                if self.model.showSettings { self.displaySettingsChanged() } else { self.hide(restoreFocus: false) }
            }
        }
        installEventMonitors()
        wallpaper.prepare(for: targetScreen(), blur: settings.blur)
    }

    /// Opens the settings window (menu bar, Dock menu, ⌘,) over the launcher, which shows what
    /// the settings change and stays open as long as they do.
    func openSettings(tab: SettingsTab? = nil) {
        if !isVisible { show() }
        model.openSettings(tab)
        cards.focusSettings()
    }

    func openGuide() {
        if !isVisible { show() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.model.openGuide() }
    }

    /// Display settings changed: restyle the panel if it is showing.
    func displaySettingsChanged() {
        guard isVisible else { return }
        let screen = panel.screen ?? targetScreen()
        configurePanel(for: screen)
        wallpaper.prepare(for: screen, blur: settings.blur)
        // Full screen and window sit at different levels; the settings stay above either.
        cards.restack()
    }

    private func frame(on screen: NSScreen) -> NSRect {
        guard settings.displayMode == .window else { return screen.frame }
        let v = screen.visibleFrame
        // The system Apps window's size and proportions (844 × 576 on a 1728-point-wide screen), a little above centre.
        // 窗口大小 scales it, staying inside the screen.
        let scale = settings.windowSize
        let w = min(min(v.width * 0.49, 860) * scale, v.width * 0.94).rounded()
        let h = min(v.height * 0.8 * max(1, scale), w / 1.465, v.height * 0.94).rounded()
        return NSRect(x: (v.midX - w / 2).rounded(), y: (v.midY - h / 2 + v.height * 0.03).rounded(), width: w, height: h)
    }

    private func configurePanel(for screen: NSScreen) {
        let windowed = settings.displayMode == .window
        // A titled (but chrome-less) window gets the system's large window shadow; borderless ones only a thin one.
        // Full screen stays borderless so it can cover the menu bar.
        panel.styleMask = windowed ? [.titled, .fullSizeContentView, .nonactivatingPanel] : [.borderless, .fullSizeContentView, .nonactivatingPanel]
        if windowed {
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        }
        panel.setFrame(frame(on: screen), display: false)
        panel.hasShadow = windowed
        // Full screen covers the menu bar and Dock, unless the Dock should stay on top.
        let level: Int = if windowed {
            Int(CGWindowLevelForKey(.modalPanelWindow))
        } else if settings.hideDock || settings.displayMode == .ring {
            Int(CGWindowLevelForKey(.mainMenuWindow)) + 2
        } else {
            Int(CGWindowLevelForKey(.dockWindow)) - 1
        }
        panel.level = NSWindow.Level(rawValue: level)
    }

    var isVisible: Bool { panel.isVisible && !isHiding }

    func toggle(via source: OpenSource = .other) {
        isVisible ? hide(restoreFocus: true) : show(via: source)
    }

    /// A profile's own shortcut or corner: opens the launcher on that profile, or closes it when
    /// it's already showing that profile.
    func toggleProfile(_ name: String, via source: OpenSource) {
        if isVisible, model.currentProfile == name {
            hide(restoreFocus: true)
            return
        }
        model.switchProfile(name)
        if !isVisible, !model.relaunchingForLanguage { show(via: source) }
    }

    func show(via source: OpenSource = .other) {
        show(interactive: false, via: source)
    }

    /// `interactive`: a pinch is under way and drives how shown the launcher is until it ends.
    private func show(interactive: Bool, via source: OpenSource) {
        Heartbeat.countOpen(via: source)
        hideToken += 1
        isHiding = false
        let screen = targetScreen()
        configurePanel(for: screen)
        wallpaper.prepare(for: screen, blur: settings.blur)
        // The ring opens round the pointer (or the middle, when it is on another screen).
        let mouse = NSEvent.mouseLocation, f = screen.frame
        model.ringCenter = NSMouseInRect(mouse, f, false)
            ? CGPoint(x: mouse.x - f.minX, y: f.maxY - mouse.y) : CGPoint(x: f.width / 2, y: f.height / 2)
        catalog.reload()
        // The settings window stays open across the launcher coming and going.
        let openSettings = (model.showSettings, model.tuner)
        model.prepareForShow()
        (model.showSettings, model.tuner) = openSettings

        // A non-activating panel takes the keyboard even when the app can't become active
        // (hotkey, F4, hot corner); activation is still requested for menus and alerts.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        cards.launcherShown()
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isVisible, NSApp.modalWindow == nil, !self.model.isAuthenticating else { return }
                    self.hide(restoreFocus: false)
                }
            }
        }

        if settings.showBadges { dockBadges.start() }
        if interactive {
            model.gestureProgress = 0
            model.focusRequest += 1
            return
        }
        DispatchQueue.main.async { self.model.focusRequest += 1 }
        finishShowing(animation: settings.motion(.easeOut(duration: 0.22), duration: 0.26).speed(openCloseRate))
        writeDebugSnapshotIfRequested()
    }

    /// Opening and closing grow the content from 110% while it fades in. In a window that's
    /// far fewer points than on the whole screen, so at the same pace it looks slower; the
    /// window runs it faster to look as quick at the same speed setting.
    private var openCloseRate: Double { settings.displayMode == .window ? 1.3 : 1 }

    private func finishShowing(animation: Animation) {
        DispatchQueue.main.async {
            withAnimation(animation) {
                self.model.isPresented = true
                self.model.gestureProgress = nil
            }
        }
        // After the open animation, so the card doesn't pop in over a half-drawn grid.
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.animationSpeed.duration(0.35)) { [weak self] in
            guard let self, self.isVisible else { return }
            self.model.presentPendingIntro()
        }
    }

    // MARK: - Trackpad pinch

    /// A pinch opening the launcher is under way.
    private var pinchOpening = false

    /// Follows a pinch as the fingers move: closing them opens the launcher, spreading closes it.
    func pinchChanged(opening: Bool, progress: Double) {
        if opening {
            if !isVisible {
                guard !pinchOpening else { return }
                pinchOpening = true
                show(interactive: true, via: .pinch)
            }
            guard pinchOpening else { return }
            model.gestureProgress = progress
        } else {
            guard isVisible, !pinchOpening, model.drag == nil, !model.showSettings else { return }
            model.gestureProgress = 1 - progress
        }
    }

    /// The fingers lifted (or went all the way): finish the open or close, or spring back.
    func pinchEnded(opening: Bool, commit: Bool) {
        if opening {
            guard pinchOpening else { return }
            pinchOpening = false
            if commit { finishShowing(animation: settings.motion(.easeOut(duration: 0.18), duration: 0.2)) } else { hide(restoreFocus: true) }
        } else {
            guard isVisible, model.gestureProgress != nil else { return }
            if commit {
                hide(restoreFocus: true)
            } else {
                withAnimation(.easeOut(duration: 0.18)) { model.gestureProgress = nil }
            }
        }
    }

    /// Puts the Dock's badges (by app path) on the matching icons.
    private func remapBadges() {
        var ids: [String: String] = [:]
        if !lastDockBadges.isEmpty {
            for app in catalog.apps where !app.isCustom {
                if let label = lastDockBadges[app.url.standardizedFileURL.path] { ids[app.id] = label }
            }
        }
        if model.badges != ids { model.badges = ids }
    }

    func badgesSettingChanged() {
        if settings.showBadges, isVisible { dockBadges.start() } else { dockBadges.stop() }
        if !settings.showBadges {
            model.badges = [:]
            lastDockBadges = [:]
        }
    }

    /// Debug aid: LAUNCHUS_SNAPSHOT=/path.png [LAUNCHUS_QUERY=text] [LAUNCHUS_SPACES=n] saves the rendered view.
    private func writeDebugSnapshotIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LAUNCHUS_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if let query = env["LAUNCHUS_QUERY"] { self.model.query = query }
            // LAUNCHUS_MODE=ring|window|fullScreen, for demo runs only (it is saved).
            if env["LAUNCHUS_DEMO"] != nil, let mode = env["LAUNCHUS_MODE"].flatMap(DisplayMode.init) {
                self.settings.displayMode = mode
            }
            // LAUNCHUS_SPACES=n: as if space was pressed n times in the empty field.
            for _ in 0..<(env["LAUNCHUS_SPACES"].flatMap(Int.init) ?? 0) { self.model.pressSpace() }
            if let ask = env["LAUNCHUS_ASK"] {
                self.model.query = ask
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.model.startChat() }
            }
            // LAUNCHUS_CHAT=1: a sample chat; =empty: a fresh one, with the recent chats; =error: a failed answer.
            if env["LAUNCHUS_CHAT"] == "empty" {
                self.model.chat = ChatSession()
            } else if env["LAUNCHUS_CHAT"] == "error" {
                let chat = ChatSession()
                let json: [String: Any] = ["error": ["message": "You didn't provide an API key. You need to provide your API key in an Authorization header using Bearer auth.", "type": "invalid_request_error"]]
                chat.load([ChatMessage(role: .user, text: "啥")],
                          error: AIFailure.gateway(status: 401, json: json, keyMissing: true))
                self.model.chat = chat
            } else if env["LAUNCHUS_CHAT"] != nil {
                let chat = ChatSession()
                chat.load([
                    ChatMessage(role: .user, text: "怎么用 Swift 读取一个文件的大小？"),
                    ChatMessage(role: .assistant, text: "可以用 **FileManager** 读取文件属性：\n\n```swift\nlet attrs = try FileManager.default.attributesOfItem(atPath: path)\nlet size = attrs[.size] as? Int64 ?? 0\n```\n\n- `attributesOfItem` 返回字典\n- `.size` 是字节数"),
                    ChatMessage(role: .user, text: "换成 URL 的写法呢"),
                ])
                self.model.chat = chat
            }
            if let id = env["LAUNCHUS_UNINSTALL"] { self.model.sheet = .confirmTrash(id) }
            if let id = env["LAUNCHUS_EDIT"] { self.model.sheet = .editApp(id) }
            // LAUNCHUS_SHEET=custom | custom:<id> | manager | widgets | stats | icon:<id> | info:<id> | profile | whatsnew | guide:<step> | tip:<name> | photo:<id> | apps:<widget id>
            if let sheet = env["LAUNCHUS_SHEET"] {
                if sheet == "custom" { self.model.sheet = .editCustom(nil) }
                else if sheet == "manager" { self.model.sheet = .manager }
                else if sheet == "widgets" { self.model.openWidgetGallery() }
                else if ["stats", "duplicates", "leftovers"].contains(sheet) { self.model.sheet = .manager }
                else if sheet == "whatsnew" { self.model.showWhatsNew = true }
                else if sheet.hasPrefix("guide:") { self.model.showGuide = true }
                else if sheet.hasPrefix("tip:") { self.model.tip = Tip(rawValue: String(sheet.dropFirst(4))) }
                else if sheet == "profile" { self.model.sheet = .newProfile }
                else if sheet.hasPrefix("icon:") { self.model.sheet = .chooseIcon(String(sheet.dropFirst(5))) }
                else if sheet.hasPrefix("info:") { self.model.sheet = .appInfo(String(sheet.dropFirst(5))) }
                else if sheet.hasPrefix("photo:") { self.model.sheet = .photoWidget(String(sheet.dropFirst(6))) }
                else if sheet.hasPrefix("apps:") { self.model.sheet = .widgetApps(String(sheet.dropFirst(5))) }
                else if sheet.hasPrefix("custom:") { self.model.sheet = .editCustom(sheet) }
            }
            if let tab = env["LAUNCHUS_SETTINGS"].flatMap(SettingsTab.named) { self.model.openSettings(tab) }
            if let tuner = env["LAUNCHUS_TUNER"] {
                self.model.openSettings(tuner.hasPrefix("motion") ? .appearance : .display)
                self.model.tuner = tuner.hasPrefix("motion") ? .motion : .background
                // `background:<n>` also applies the n-th preset, to picture it.
                if let n = tuner.split(separator: ":").last.flatMap({ Int($0) }), BackgroundStyle.presets.indices.contains(n) {
                    self.settings.backgroundStyle = BackgroundStyle.presets[n].style
                }
                if tuner.hasPrefix("motion") { self.settings.motionCurve = MotionCurve.presets[3].curve }
            }
            if let name = env["LAUNCHUS_FOLDER"],
               case .folder(let folder, _)? = self.model.pages.joined().first(where: { $0.title == name }) {
                self.model.openFolder(folder.id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (env["LAUNCHUS_DELAY"].flatMap(Double.init) ?? 1.0)) {
                let front = self.model.tuner == nil ? self.cards.snapshotView : nil
                if front != nil || env["LAUNCHUS_EDIT"] != nil || env["LAUNCHUS_SHEET"] != nil || env["LAUNCHUS_REAL"] != nil,
                   let view = front ?? self.panel.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    // AppKit controls only draw through the real view hierarchy.
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    NSLog("LaunchUS: settings snapshot written to \(path)")
                    return
                }
                let renderer = ImageRenderer(content: LauncherView(model: self.model, wallpaper: self.wallpaper)
                    .frame(width: self.panel.frame.width, height: self.panel.frame.height))
                renderer.scale = 1
                guard let image = renderer.cgImage else {
                    NSLog("LaunchUS: snapshot render failed")
                    return
                }
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                NSLog("LaunchUS: snapshot written to \(path) folder=\(self.model.openFolderID ?? "-") expanded=\(self.model.folderExpanded)")
            }
        }
    }

    /// - Parameters:
    ///   - restoreFocus: hand focus back to the previous app (Esc / click outside).
    ///   - force: close even with the settings open (they close too). Otherwise the launcher
    ///     stays while the settings are open, since they show their changes on it.
    ///   - keepSettings: close the launcher but leave the settings window open (another app
    ///     came to the front); it comes back over the launcher when that opens again.
    func hide(restoreFocus: Bool, force: Bool = false, keepSettings: Bool = false) {
        guard panel.isVisible, !isHiding else { return }
        if model.showSettings, !keepSettings {
            guard force else { return }
            model.tuner = nil
            model.showSettings = false
        }
        isHiding = true
        hideToken += 1
        let token = hideToken
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
        model.endDrag()
        dockBadges.stop()
        pinchOpening = false
        withAnimation(settings.motion(.easeIn(duration: 0.16), duration: 0.18).speed(openCloseRate)) {
            model.isPresented = false
            model.gestureProgress = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.animationSpeed.duration(settings.motionCurve == nil ? 0.17 : 0.19) / openCloseRate) {
            guard self.hideToken == token else { return }
            self.panel.orderOut(nil)
            self.cards.launcherHidden()
            self.model.didHide()
            // Don't hide the settings window along with the launcher.
            let otherWindows = NSApp.windows.contains { $0 !== self.panel && $0.isVisible && $0.canBecomeMain }
            if restoreFocus, NSApp.isActive, !otherWindows { NSApp.hide(nil) }
            self.isHiding = false
            self.model.query = ""
            self.model.selection = nil
        }
    }

    /// An app's own shortcut: opens it, or hides it when it's already in front.
    private func openFromShortcut(_ id: String) {
        if id.hasPrefix(LauncherModel.folderShortcutPrefix) {
            model.openAll(String(id.dropFirst(LauncherModel.folderShortcutPrefix.count)))
            return
        }
        guard let app = model.app(id) else { return }
        if app.custom == nil, let bundleID = app.bundleID,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: \.isActive) {
            running.hide()
            return
        }
        model.launch(app)
    }

    private func launch(_ app: AppItem) {
        if SettingsPanes.isPane(app.id) {
            NSWorkspace.shared.open(app.url)
            hide(restoreFocus: false)
            return
        }
        if let item = model.customItem(app.id) {
            CustomLauncher.open(item)
            hide(restoreFocus: false)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
            if let error { NSLog("LaunchUS: failed to open \(app.url.path): \(error)") }
        }
        hide(restoreFocus: false)
    }

    /// Opens each app without bringing it forward, except the last, so they don't fight for focus.
    private func openGroup(_ apps: [AppItem]) {
        for (index, app) in apps.enumerated() {
            if let item = model.customItem(app.id) {
                CustomLauncher.open(item)
                continue
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = index == apps.count - 1
            NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
                if let error { NSLog("LaunchUS: failed to open \(app.url.path): \(error)") }
            }
        }
        if isVisible { hide(restoreFocus: false) }
    }

    private func open(_ urls: [URL], with app: AppItem) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: app.url, configuration: config) { _, error in
            if let error { NSLog("LaunchUS: failed to open files with \(app.url.path): \(error)") }
        }
        hide(restoreFocus: false)
    }

    /// The screen chosen in settings: the Dock's, the pointer's, or the main one.
    func targetScreen() -> NSScreen {
        let screens = NSScreen.screens
        let mouse = NSEvent.mouseLocation
        let underMouse = screens.first { NSMouseInRect(mouse, $0.frame, false) }
        switch settings.targetScreen {
        case .main: return screens.first ?? NSScreen.main ?? underMouse!
        case .mouse: return underMouse ?? NSScreen.main ?? screens[0]
        case .active: return Self.activeWindowScreen(screens) ?? underMouse ?? NSScreen.main ?? screens[0]
        case .dock: break
        }
        if screens.count > 1, let dockScreen = screens.first(where: { screen in
            let f = screen.frame, v = screen.visibleFrame
            return v.minY - f.minY > 1 || v.minX - f.minX > 1 || f.maxX - v.maxX > 1
        }) {
            return dockScreen
        }
        return underMouse ?? NSScreen.main ?? screens[0]
    }

    /// The display showing the frontmost app's front window.
    private static func activeWindowScreen(_ screens: [NSScreen]) -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // Front to back; layer 0 is ordinary windows.
        guard let info = windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }), let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
        // Window bounds are top-down from the primary display; screens are bottom-up.
        let primaryHeight = screens.first?.frame.height ?? 0
        let center = CGPoint(x: bounds.midX, y: primaryHeight - bounds.midY)
        return screens.first { $0.frame.contains(center) }
            ?? screens.max { $0.frame.intersection(bounds).width < $1.frame.intersection(bounds).width }
    }

    // MARK: - Dragging out

    /// What the icon being dragged stands for outside the launcher: the app, or a launch item's file.
    func dragOutURL() -> URL? {
        guard let session = model.drag, session.companions.isEmpty, case .app(let id) = session.item else { return nil }
        if let cached = dragOutTarget, cached.id == id { return cached.url }
        let url: URL? = switch model.app(id)?.custom {
        case .none: model.app(id)?.url
        case .file: model.customItem(id)?.fileURL
        case .url, .script: nil
        }
        dragOutTarget = (id, url)
        return url
    }

    /// Hands the icon to a system drag, so it can be dropped on the Dock, Finder or any app.
    /// The launcher fades out meanwhile and closes if the drop lands somewhere.
    func beginDragOut(_ event: NSEvent) -> Bool {
        guard dragOut == nil, let url = dragOutURL(), let view = panel.contentView else { return false }
        model.endDrag()
        model.dragOutHint = false
        dragOutTarget = nil

        let side: CGFloat = 72
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: side, height: side)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let p = view.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side), contents: image)

        let source = DragOutSource { [weak self] operation in
            guard let self else { return }
            self.dragOut = nil
            self.panel.ignoresMouseEvents = false
            if operation.isEmpty {
                // Dropped nowhere: bring the launcher back.
                NSAnimationContext.runAnimationGroup { $0.duration = 0.15; self.panel.animator().alphaValue = 1 }
            } else {
                self.hide(restoreFocus: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.panel.alphaValue = 1 }
            }
        }
        dragOut = source
        view.beginDraggingSession(with: [item], event: event, source: source)
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 0 }
        return true
    }
}

/// The system side of dragging an icon out of the launcher.
final class DragOutSource: NSObject, NSDraggingSource {
    private let ended: @MainActor (NSDragOperation) -> Void

    init(ended: @escaping @MainActor (NSDragOperation) -> Void) {
        self.ended = ended
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { ended(operation) }
    }
}

/// SwiftUI sets the arrow again each time the views under the pointer move: on every frame of
/// showing, paging or searching. With a customized pointer (Accessibility › Display › Pointer)
/// each set has the system draw the pointer image anew, a third of the main thread while paging.
/// Setting the arrow when it's already the arrow changes nothing, so it's skipped; text fields
/// keep their own I-beam.
final class LauncherHostingView<Content: View>: NSHostingView<Content> {
    override func cursorUpdate(with event: NSEvent) {
        if NSCursor.current == NSCursor.arrow { return }
        super.cursorUpdate(with: event)
    }
}
