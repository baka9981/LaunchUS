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
    private let panel = LauncherPanel()
    private let settings = Settings.shared
    private var monitors: [Any] = []
    /// Clicks in other apps while the launcher is up (works even if activation didn't stick).
    private var outsideClickMonitor: Any?
    private var isHiding = false
    private var hideToken = 0
    /// Set while an icon is being dragged out to the Dock, Finder or another app.
    private var dragOut: DragOutSource?
    /// `dragOutURL()` for the item being dragged, so it isn't looked up on every mouse event.
    private var dragOutTarget: (id: String, url: URL?)?

    // Trackpad swipe state
    private var rawDrag: CGFloat = 0
    private var lastWheelEvent = Date.distantPast
    private let running = RunningApps()
    private let dockBadges = DockBadges()
    private var lastDockBadges: [String: String] = [:]
    private var hitchLog: HitchLog?
    /// Shows the ⌘ numbers after a short hold, so ⌘W and friends don't flash them.
    private var commandHold: DispatchWorkItem?

    init(catalog: AppCatalog) {
        self.catalog = catalog
        model = LauncherModel(catalog: catalog)
        model.onLaunch = { [weak self] app in self?.launch(app) }
        AppHotKeys.action = { [weak self] id in self?.openFromShortcut(id) }
        model.onOpenFiles = { [weak self] urls, app in self?.open(urls, with: app) }
        model.onOpenGroup = { [weak self] apps in self?.openGroup(apps) }
        model.onClose = { [weak self] in self?.hide(restoreFocus: true) }
        PermissionHelper.shared.hideLauncher = { [weak self] in
            if self?.isVisible == true { self?.hide(restoreFocus: true) }
        }
        Updater.shared.hideLauncher = { [weak self] in
            if self?.isVisible == true { self?.hide(restoreFocus: false) }
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
                guard self?.model.isAuthenticating == false, self?.dragOut == nil else { return }
                self?.hide(restoreFocus: false)
            }
        }
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            // Also posted for menu bar / Dock changes, so only react to real display changes.
            MainActor.assumeIsolated {
                guard let self, self.isVisible,
                      !NSScreen.screens.contains(where: { self.frame(on: $0) == self.panel.frame }) else { return }
                self.hide(restoreFocus: false)
            }
        }
        installEventMonitors()
        wallpaper.prepare(for: targetScreen(), blur: settings.blur)
    }

    /// Shows the launcher with the settings card on top (menu bar, Dock menu, ⌘,).
    func openSettings(tab: SettingsTab? = nil) {
        if !isVisible { show() }
        model.openSettings(tab)
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
    }

    private func frame(on screen: NSScreen) -> NSRect {
        guard settings.displayMode == .window else { return screen.frame }
        let v = screen.visibleFrame
        // The system Apps window's size and proportions (844 × 576 on a 1728-point-wide screen), a little above centre.
        let w = min(v.width * 0.49, 860).rounded(), h = min(v.height * 0.8, w / 1.465).rounded()
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
        } else if settings.hideDock {
            Int(CGWindowLevelForKey(.mainMenuWindow)) + 2
        } else {
            Int(CGWindowLevelForKey(.dockWindow)) - 1
        }
        panel.level = NSWindow.Level(rawValue: level)
    }

    var isVisible: Bool { panel.isVisible && !isHiding }

    func toggle() {
        isVisible ? hide(restoreFocus: true) : show()
    }

    func show() {
        show(interactive: false)
    }

    /// `interactive`: a pinch is under way and drives how shown the launcher is until it ends.
    private func show(interactive: Bool) {
        hideToken += 1
        isHiding = false
        let screen = targetScreen()
        configurePanel(for: screen)
        wallpaper.prepare(for: screen, blur: settings.blur)
        catalog.reload()
        model.prepareForShow()

        // A non-activating panel takes the keyboard even when the app can't become active
        // (hotkey, F4, hot corner); activation is still requested for menus and alerts.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
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
        finishShowing(animation: .easeOut(duration: 0.22))
        writeDebugSnapshotIfRequested()
    }

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
                show(interactive: true)
            }
            guard pinchOpening else { return }
            model.gestureProgress = progress
        } else {
            guard isVisible, !pinchOpening, model.drag == nil else { return }
            model.gestureProgress = 1 - progress
        }
    }

    /// The fingers lifted (or went all the way): finish the open or close, or spring back.
    func pinchEnded(opening: Bool, commit: Bool) {
        if opening {
            guard pinchOpening else { return }
            pinchOpening = false
            if commit { finishShowing(animation: .easeOut(duration: 0.18)) } else { hide(restoreFocus: true) }
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
            // LAUNCHUS_SHEET=custom | custom:<id> | manager | stats | icon:<id> | info:<id> | profile | whatsnew | guide:<step> | tip:<name>
            if let sheet = env["LAUNCHUS_SHEET"] {
                if sheet == "custom" { self.model.sheet = .editCustom(nil) }
                else if sheet == "manager" { self.model.sheet = .manager }
                else if ["stats", "duplicates", "leftovers"].contains(sheet) { self.model.sheet = .manager }
                else if sheet == "whatsnew" { self.model.showWhatsNew = true }
                else if sheet.hasPrefix("guide:") { self.model.showGuide = true }
                else if sheet.hasPrefix("tip:") { self.model.tip = Tip(rawValue: String(sheet.dropFirst(4))) }
                else if sheet == "profile" { self.model.sheet = .newProfile }
                else if sheet.hasPrefix("icon:") { self.model.sheet = .chooseIcon(String(sheet.dropFirst(5))) }
                else if sheet.hasPrefix("info:") { self.model.sheet = .appInfo(String(sheet.dropFirst(5))) }
                else if sheet.hasPrefix("custom:") { self.model.sheet = .editCustom(sheet) }
            }
            if let tab = env["LAUNCHUS_SETTINGS"].flatMap(SettingsTab.named) { self.model.openSettings(tab) }
            if let name = env["LAUNCHUS_FOLDER"],
               case .folder(let folder, _)? = self.model.pages.joined().first(where: { $0.title == name }) {
                self.model.openFolder(folder.id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (env["LAUNCHUS_DELAY"].flatMap(Double.init) ?? 1.0)) {
                if self.model.showSettings || env["LAUNCHUS_EDIT"] != nil || env["LAUNCHUS_SHEET"] != nil || env["LAUNCHUS_REAL"] != nil, let view = self.panel.contentView,
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

    /// - Parameter restoreFocus: hand focus back to the previous app (Esc / click outside).
    func hide(restoreFocus: Bool) {
        guard panel.isVisible, !isHiding else { return }
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
        withAnimation(.easeIn(duration: 0.16)) {
            model.isPresented = false
            model.gestureProgress = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.animationSpeed.duration(0.17)) {
            guard self.hideToken == token else { return }
            self.panel.orderOut(nil)
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
    private func dragOutURL() -> URL? {
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
    private func beginDragOut(_ event: NSEvent) -> Bool {
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

    // MARK: - Keyboard & scrolling

    private func installEventMonitors() {
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self else { return event }
            return self.handleScroll(event)
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown, handler: { [weak self] event in
            guard let self else { return event }
            return self.handleSideButton(event)
        }) { monitors.append(m) }

        // Icon drags are tracked here rather than by the SwiftUI gesture, because the view
        // that started the drag may go away (leaving a folder, overflowing onto another page).
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp], handler: { [weak self] event in
            guard let self, self.model.drag != nil, event.window === self.panel else { return event }
            if event.type == .leftMouseUp {
                self.model.endDrag()
                self.model.dragOutHint = false
                self.dragOutTarget = nil
            } else {
                let p = event.locationInWindow
                let point = CGPoint(x: p.x, y: self.panel.frame.height - p.y)
                let canDragOut = self.dragOutURL() != nil
                // Full screen: the bottom edge, where the Dock is. Window: anywhere outside.
                let size = self.panel.frame.size
                let outside = self.settings.displayMode == .window
                    ? !CGRect(origin: .zero, size: size).contains(point)
                    : point.y > size.height - 6
                if canDragOut, outside, self.beginDragOut(event) { return nil }
                let hint = canDragOut && self.settings.displayMode == .fullScreen && point.y > size.height - 110
                if self.model.dragOutHint != hint { self.model.dragOutHint = hint }
                self.model.dragMoved(to: point)
            }
            return event
        }) { monitors.append(m) }

        // Holding ⌥ makes the icons jiggle, like Launchpad.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            guard let self, self.isVisible else { return event }
            let option = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
            if option, !self.model.isEditing, !self.model.isSearching, !self.model.isRenaming, self.model.sheet == nil, !self.model.showSettings {
                self.model.editingFromOption = true
                withAnimation { self.model.isEditing = true }
            } else if !option, self.model.editingFromOption {
                self.model.editingFromOption = false
                withAnimation { self.model.isEditing = false }
            }
            self.commandChanged(event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command)
            return event
        }) { monitors.append(m) }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard isVisible, event.window === panel else { return event }
        // Let the input method finish composing (e.g. pinyin candidates) before we react.
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }

        let command = event.modifierFlags.contains(.command)
        if model.showSettings {
            // Settings card: its controls get the keys; Esc closes it.
            guard Int(event.keyCode) == kVK_Escape else { return event }
            model.escape()
            return nil
        }
        if model.sheet != nil {
            // An editor card is open: its text fields and buttons get the keys, except Esc.
            guard Int(event.keyCode) == kVK_Escape else { return event }
            model.escape()
            return nil
        }
        if model.isRenaming {
            // Typing a folder name: only Esc is ours (it ends renaming).
            guard Int(event.keyCode) == kVK_Escape else { return event }
            model.escape()
            return nil
        }
        if model.chat != nil {
            // Chatting: the field writes messages; ↩ sends, ⌘N starts over, Esc stops or leaves.
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case kVK_Escape: model.escape()
            case kVK_Return where flags.isEmpty, kVK_ANSI_KeypadEnter where flags.isEmpty: model.sendChat()
            case kVK_ANSI_N where flags == .command: model.newChat()
            case kVK_ANSI_W where flags == .command: hide(restoreFocus: true)
            case kVK_ANSI_Comma where flags == .command: openSettings()
            default: return event
            }
            return nil
        }
        commandChanged(false)
        // ⌘1…⌘9 open the numbered items; ⌃1…⌃9 go to that page.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let digit = Self.digit(event), flags == .command || flags == .control {
            if flags == .command { model.openShortcut(digit) } else { model.goToPage(digit - 1) }
            return nil
        }
        // Space with nothing typed opens the 猜你想找 / 最近使用 / 最常使用 / 最近安装 lists; while they
        // show, space and →/← switch between them and ⌫ closes them.
        if model.query.isEmpty, model.openFolderID == nil, !model.isEditing,
           flags.intersection([.command, .option, .control, .shift]).isEmpty {
            switch Int(event.keyCode) {
            case kVK_Space:
                model.pressSpace()
                return nil
            case kVK_RightArrow where model.spaceList != nil:
                model.spaceList = model.spaceList?.step(1)
                return nil
            case kVK_LeftArrow where model.spaceList != nil:
                model.spaceList = model.spaceList?.step(-1)
                return nil
            case kVK_Delete where model.spaceList != nil:
                model.spaceList = nil
                return nil
            default: break
            }
        }
        switch Int(event.keyCode) {
        case kVK_Home:
            model.goToPage(0)
        case kVK_End:
            model.goToPage(model.pageCount - 1)
        case kVK_PageUp:
            model.flipPage(-1)
        case kVK_PageDown:
            model.flipPage(1)
        case kVK_Escape:
            model.escape()
        case kVK_Tab where !model.tagCandidates.isEmpty:
            model.completeTag(model.tagCandidates[0])
        case kVK_Tab where model.canAskAI:
            model.searchWeb()
        case kVK_Return where command && model.fallbackQuery != nil:
            model.searchFinder()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.activateSelection()
        case kVK_LeftArrow:
            command ? model.flipPage(-1) : model.moveSelection(dx: -1, dy: 0)
        case kVK_RightArrow:
            command ? model.flipPage(1) : model.moveSelection(dx: 1, dy: 0)
        case kVK_UpArrow:
            model.moveSelection(dx: 0, dy: -1)
        case kVK_DownArrow:
            model.moveSelection(dx: 0, dy: 1)
        case kVK_ANSI_W where command:
            hide(restoreFocus: true)
        case kVK_ANSI_Comma where command:
            openSettings()
        case kVK_ANSI_I where command:
            model.showInfoForSelection()
        default:
            return event
        }
        return nil
    }

    /// 1…9 from the number row or keypad.
    private static func digit(_ event: NSEvent) -> Int? {
        let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let keypad = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
                      kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
        let code = Int(event.keyCode)
        if let i = keys.firstIndex(of: code) ?? keypad.firstIndex(of: code) { return i + 1 }
        return nil
    }

    private func commandChanged(_ held: Bool) {
        commandHold?.cancel()
        commandHold = nil
        if held, isVisible, model.sheet == nil, !model.showSettings, model.openFolderID == nil, model.drag == nil {
            let work = DispatchWorkItem { [weak self] in
                withAnimation(.easeOut(duration: 0.15)) { self?.model.showShortcutNumbers = true }
            }
            commandHold = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        } else if model.showShortcutNumbers {
            withAnimation(.easeOut(duration: 0.15)) { model.showShortcutNumbers = false }
        }
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard isVisible, event.window === panel else { return event }
        // Smooth-scrolling mouse drivers send point deltas with no gesture phase at all.
        let isTrackpad = event.hasPreciseScrollingDeltas && !(event.phase.isEmpty && event.momentumPhase.isEmpty)
        if model.drag != nil {
            // The wheel turns pages while an icon is held.
            if !isTrackpad { wheelFlip(event) }
            return nil
        }
        // Cards (the App manager's lists) scroll themselves; the pages stay put.
        if model.showSettings || model.sheet != nil { return event }
        // The scrolling browse style scrolls natively, unless a folder is open.
        if settings.browseStyle == .scroll, model.openFolderID == nil { return event }
        if model.openFolderID != nil, model.folderScrolls {
            // Trackpads report points (momentum included); wheels report lines.
            let dy = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 36)
            model.scrollFolder(by: -dy)
            return nil
        }

        if isTrackpad {
            // Trackpad: follow the fingers, then snap to a page.
            if !event.momentumPhase.isEmpty { return nil }
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            let delta = abs(dx) >= abs(dy) ? dx : dy

            switch event.phase {
            case .began:
                rawDrag = 0
            case .changed:
                rawDrag += delta
                model.dragChanged(rawDrag)
            case .ended, .cancelled:
                model.dragEnded(rawDrag, pageWidth: panel.frame.width)
                rawDrag = 0
            default:
                break
            }
        } else {
            wheelFlip(event)
        }
        return nil
    }

    /// Mouse wheel: one flick flips one page. A flick (or a smooth-scrolling mouse's glide)
    /// sends a burst of events, so only the first event after a pause counts.
    private func wheelFlip(_ event: NSEvent) {
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta != 0 else { return }
        let now = Date()
        if now.timeIntervalSince(lastWheelEvent) > 0.3 {
            flip(delta < 0 ? 1 : -1)
        }
        lastWheelEvent = now
    }

    private func flip(_ step: Int) {
        model.flipPage(step)
        // A held icon lands on the new page under the pointer.
        if model.drag != nil { model.dragMoved(to: model.dragLocation) }
    }

    /// The mouse's back and forward side buttons turn pages.
    private func handleSideButton(_ event: NSEvent) -> NSEvent? {
        guard isVisible, event.window === panel, !model.showSettings, model.sheet == nil,
              model.openFolderID == nil, settings.browseStyle == .paged || model.drag != nil else { return event }
        switch event.buttonNumber {
        case 3: flip(-1)
        case 4: flip(1)
        default: return event
        }
        return nil
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
