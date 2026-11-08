import AppKit
import SwiftUI

/// The settings window. A real window rather than a card drawn inside the launcher, so the
/// system sees it on its own (screenshots, Mission Control, ⌘`) and it doesn't depend on the
/// launcher's shape or size.
final class SettingsHostWindow: NSWindow {
    var onClose: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            onClose?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// An editor or confirmation card (`LauncherSheet`) in a window of its own, over the launcher
/// or the settings window.
final class CardPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        // The card draws its own shadow inside the window's margin.
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Keeps the settings window and the card window in step with the model (`showSettings`,
/// `tuner`, `sheet`) and stacked above the launcher while it shows.
@MainActor
final class CardWindows: NSObject, NSWindowDelegate {
    /// Room around a card for its shadow.
    static let margin: CGFloat = 44

    private let model: LauncherModel
    private let launcher: NSPanel
    private let launcherVisible: () -> Bool
    /// Shows the launcher for a tuning panel opened while it was hidden.
    var showLauncher: (() -> Void)?

    private var settingsWindow: SettingsHostWindow?
    /// Whether the settings window holds its views (they go while it's closed).
    private var settingsLoaded = false
    private var cardPanel: CardPanel?
    private var tunerPanel: CardPanel?
    private var shownTuner: Tuner?
    private var shownSheet: LauncherSheet?
    /// What the open card is over, and whether it sits a little high (small cards over the launcher).
    private var cardAnchor: (parent: NSRect, high: Bool)?

    init(model: LauncherModel, launcher: NSPanel, launcherVisible: @escaping () -> Bool) {
        self.model = model
        self.launcher = launcher
        self.launcherVisible = launcherVisible
        super.init()
        observe()
    }

    /// Our windows that float above normal ones; alerts and the Touch ID prompt drop them for a while.
    static func floating() -> [NSWindow] {
        NSApp.windows.filter { ($0 is LauncherPanel || $0 is CardPanel || $0 is SettingsHostWindow) && $0.isVisible && $0.level > .normal }
    }

    var settingsShowing: Bool { settingsWindow?.isVisible == true }

    /// The view to save for LAUNCHUS_SNAPSHOT: the card, else the settings.
    var snapshotView: NSView? {
        if model.sheet != nil, let view = cardPanel?.contentView { return view }
        if settingsShowing { return settingsWindow?.contentView }
        return nil
    }

    private func observe() {
        withObservationTracking {
            _ = model.showSettings
            _ = model.tuner
            _ = model.sheet
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.sync()
                self?.observe()
            }
        }
    }

    func sync() {
        if model.showSettings, model.tuner != nil, !launcherVisible() {
            // A tuning panel shows the launcher as it'll look; it lives there.
            showLauncher?()
        }
        if model.showSettings && model.tuner == nil {
            openSettingsWindow()
        } else if settingsShowing {
            settingsWindow?.orderOut(nil)
            // Closed (not just out of the way of a tuning panel): its views go too, so they stop
            // watching the model; the window keeps its size.
            if !model.showSettings {
                settingsWindow?.contentView = NSView()
                settingsLoaded = false
            }
        }
        let tuner = model.showSettings ? model.tuner : nil
        if tuner != shownTuner { showTuner(tuner) }
        if model.sheet != shownSheet { showCard(model.sheet) }
        restack()
    }

    /// Settings asked for again while already open (behind another app's window, say).
    func focusSettings() {
        guard settingsShowing, model.sheet == nil else { return }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// The launcher came up: settings and cards go above it.
    func launcherShown() {
        restack()
        if shownTuner != nil, let panel = tunerPanel { placeTuner(panel) }
        if model.sheet != nil { cardPanel?.makeKeyAndOrderFront(nil) } else if settingsShowing { settingsWindow?.makeKeyAndOrderFront(nil) }
    }

    /// The launcher went away (it stays while the settings are open, unless it had to go: a
    /// permission prompt, an update). Its cards and a tuning panel go with it.
    func launcherHidden() {
        if model.tuner != nil { model.tuner = nil }
        if model.sheet != nil, !(model.showSettings && model.tuner == nil) {
            model.sheet = nil
            model.sheetParent = nil
        }
        restack()
    }

    func restack() {
        let shown = launcherVisible()
        let above = shown ? launcher.level.rawValue + 1 : NSWindow.Level.normal.rawValue
        settingsWindow?.level = NSWindow.Level(rawValue: above)
        // Over the settings window and the launcher; with the launcher gone it floats over the
        // settings window, and hides while another app is in front.
        cardPanel?.level = NSWindow.Level(rawValue: max(above + 1, NSWindow.Level.floating.rawValue))
        cardPanel?.hidesOnDeactivate = !shown
        tunerPanel?.level = NSWindow.Level(rawValue: launcher.level.rawValue + 1)
    }

    // MARK: Settings

    private func openSettingsWindow() {
        let isNew = settingsWindow == nil
        let window = settingsWindow ?? makeSettingsWindow()
        guard !window.isVisible else { return }
        if !settingsLoaded {
            window.contentView = settingsContent()
            settingsLoaded = true
        }
        let screen = launcherVisible() ? (launcher.screen ?? NSScreen.main) : (NSScreen.main ?? launcher.screen)
        // Centred on the screen in use; a size the window was given is kept.
        if let visible = screen?.visibleFrame, isNew || window.screen != screen {
            if isNew { window.setContentSize(NSSize(width: 600, height: min(700, visible.height - 60))) }
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: (visible.midX - frame.width / 2).rounded(), y: (visible.midY - frame.height / 2).rounded()))
        }
        restack()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> SettingsHostWindow {
        let window = SettingsHostWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
                                        styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                        backing: .buffered, defer: true)
        window.title = String(localized: "设置")
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.contentMinSize = NSSize(width: 600, height: 420)
        window.contentMaxSize = NSSize(width: 600, height: 10_000)
        window.delegate = self
        window.onClose = { [weak self] in self?.closeSettings() }
        settingsWindow = window
        return window
    }

    private func settingsContent() -> NSView {
        NSHostingView(rootView:
            SettingsView(model: model, settings: model.settings, actions: model.settingsActions)
                .environment(\.windowedStyle, true))
    }

    private func closeSettings() {
        model.tuner = nil
        model.closeSettings()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === settingsWindow {
            closeSettings()
            return false
        }
        return true
    }

    // MARK: Tuning panel

    /// Beside the launcher, so the panel never covers or overflows a small launcher window.
    private func showTuner(_ tuner: Tuner?) {
        shownTuner = tuner
        guard let tuner else {
            tunerPanel?.orderOut(nil)
            tunerPanel?.contentView = nil
            return
        }
        let panel = tunerPanel ?? {
            let panel = CardPanel()
            panel.delegate = self
            panel.onCancel = { [weak self] in self?.model.closeSettings() }
            tunerPanel = panel
            return panel
        }()
        let visible = (launcher.screen ?? NSScreen.main)?.visibleFrame ?? launcher.frame
        let fullScreen = model.settings.displayMode != .window
        let maxHeight = min(640, (fullScreen ? launcher.frame.height : visible.height) - 80)
        let host = NSHostingView(rootView:
            TunerPanel(model: model, settings: model.settings, tuner: tuner, maxHeight: maxHeight)
                .padding(Self.margin)
                .fixedSize()
                .environment(\.windowedStyle, true))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        placeTuner(panel)
        restack()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Full screen: at the right edge, as before. A window: to its right if there's room, else
    /// its left, else over the screen's right edge.
    private func placeTuner(_ panel: NSPanel) {
        let size = panel.frame.size
        let width = size.width - Self.margin * 2
        let frame = launcher.frame
        let visible = (launcher.screen ?? NSScreen.main)?.visibleFrame ?? frame
        let x: CGFloat
        if model.settings.displayMode != .window {
            x = frame.maxX - 36 - width
        } else if frame.maxX + 16 + width <= visible.maxX {
            x = frame.maxX + 16
        } else if frame.minX - 16 - width >= visible.minX {
            x = frame.minX - 16 - width
        } else {
            x = visible.maxX - 16 - width
        }
        let origin = NSPoint(x: (x - Self.margin).rounded(), y: (frame.midY - size.height / 2).rounded())
        if origin != panel.frame.origin { panel.setFrameOrigin(origin) }
    }

    // MARK: Cards

    private func showCard(_ sheet: LauncherSheet?) {
        shownSheet = sheet
        guard let sheet else {
            cardPanel?.orderOut(nil)
            cardPanel?.contentView = nil
            cardAnchor = nil
            return
        }
        let panel = cardPanel ?? makeCardPanel()
        // Over the settings window when that's where it was opened from, else over the launcher.
        let overSettings = settingsShowing && (settingsWindow?.isKeyWindow == true || !launcherVisible())
        let parent: NSRect = if overSettings, let frame = settingsWindow?.frame {
            frame
        } else if launcherVisible() {
            launcher.frame
        } else {
            (NSScreen.main ?? launcher.screen)?.visibleFrame ?? .zero
        }
        let screen = (overSettings ? settingsWindow?.screen : launcher.screen) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? parent
        // The launcher's own size for cards over it (as before); the screen's otherwise.
        let roomBase = overSettings || !launcherVisible() ? visible.size : launcher.frame.size
        let room = CGSize(width: roomBase.width - 32, height: roomBase.height - 32)
        cardAnchor = (parent, !sheet.isLarge && !overSettings && launcherVisible())

        let host = NSHostingView(rootView:
            SheetCard(model: model, sheet: sheet, room: room)
                .id(sheet)
                .padding(Self.margin)
                .fixedSize())
        panel.contentView = host
        place(panel, size: host.fittingSize)
        restack()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makeCardPanel() -> CardPanel {
        let panel = CardPanel()
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.model.dismissSheet() }
        cardPanel = panel
        return panel
    }

    /// Centred on what it's over; the small cards over the launcher a little higher, as they
    /// used to sit, but never past the top.
    private func place(_ panel: NSPanel, size: NSSize) {
        guard let anchor = cardAnchor else { return }
        let parent = anchor.parent
        var y = parent.midY
        if anchor.high {
            let height = size.height - Self.margin * 2
            y = parent.maxY - min(max(parent.height * 0.42, height / 2 + 16), parent.height / 2)
        }
        let frame = NSRect(x: (parent.midX - size.width / 2).rounded(), y: (y - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    /// A card that grows or shrinks (a list loading, a longer message) stays in place.
    func windowDidResize(_ notification: Notification) {
        guard let panel = notification.object as? CardPanel else { return }
        if panel === cardPanel { place(panel, size: panel.frame.size) }
        if panel === tunerPanel { placeTuner(panel) }
    }
}
