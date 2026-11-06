import AppKit
import SwiftUI

/// Permissions granted by adding LaunchUS to a list in System Settings.
enum PermissionKind {
    case fullDiskAccess, accessibility

    var title: String {
        switch self {
        case .fullDiskAccess: String(localized: "完全磁盘访问权限")
        case .accessibility: String(localized: "辅助功能")
        }
    }

    var settingsURL: URL {
        let anchor = self == .fullDiskAccess ? "Privacy_AllFiles" : "Privacy_Accessibility"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    var isGranted: Bool {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted()
        case .fullDiskAccess:
            // Full Disk Access lets a process read the TCC database; nothing else does.
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
            return FileHandle(forReadingAtPath: path) != nil
        }
    }
}

/// A small floating panel that follows the System Settings window while it shows a
/// privacy list, holding a LaunchUS icon the user can drag into that list.
@MainActor
final class PermissionHelper {
    static let shared = PermissionHelper()

    /// Hides the launcher, which would otherwise cover System Settings.
    var hideLauncher: (() -> Void)?
    /// Called when the permission turns up while the helper is showing.
    var onGranted: ((PermissionKind) -> Void)?
    private var panel: NSPanel?
    private var hosting: NSHostingView<HelperView>?
    private var timer: Timer?
    private static let settingsBundleID = "com.apple.systempreferences"
    private static let size = NSSize(width: 380, height: 92)

    func request(_ kind: PermissionKind) {
        hideLauncher?()
        // After the launcher has handed focus back, so Settings ends up in front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.show(kind) }
    }

    private func show(_ kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
        if panel == nil { panel = makePanel() }
        hosting?.rootView = HelperView(kind: kind, close: { [weak self] in self?.close() })
        panel?.setFrame(NSRect(origin: placement(), size: Self.size), display: true)
        panel?.orderFrontRegardless()
        timer?.invalidate()
        var waited = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                waited += 1
                if kind.isGranted {
                    self.close()
                    self.onGranted?(kind)
                    return
                }
                // Give Settings a few seconds to launch before treating "not running" as closed.
                let settingsRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID).isEmpty
                if !settingsRunning && waited > 20 {
                    self.close()
                    return
                }
                let origin = self.placement()
                if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
            }
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        let hosting = NSHostingView(rootView: HelperView(kind: .fullDiskAccess, close: {}))
        self.hosting = hosting
        panel.contentView = hosting
        return panel
    }

    /// Just under the Settings window, centred on its right-hand (content) side; bottom of
    /// the screen when the window can't be found. Window bounds need no screen-recording permission.
    private func placement() -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let fallback = NSPoint(x: screen.visibleFrame.midX - Self.size.width / 2, y: screen.visibleFrame.minY + 40)
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict) else { return fallback }
        // CG coordinates are top-left based on the primary screen.
        let primaryHeight = NSScreen.screens[0].frame.height
        let windowBottom = primaryHeight - bounds.maxY
        let contentMidX = bounds.minX + bounds.width * 0.62
        var origin = NSPoint(x: contentMidX - Self.size.width / 2, y: windowBottom - Self.size.height - 10)
        let cocoaBounds = CGRect(x: bounds.minX, y: windowBottom, width: bounds.width, height: bounds.height)
        let visible = (NSScreen.screens.first { $0.frame.intersects(cocoaBounds) } ?? screen).visibleFrame
        if origin.y < visible.minY {
            // No room below: beside the window, level with its bottom, on whichever side fits;
            // overlap the window's bottom edge only as a last resort.
            let y = max(visible.minY + 8, windowBottom + 14)
            if bounds.maxX + 12 + Self.size.width <= visible.maxX {
                return NSPoint(x: bounds.maxX + 12, y: y)
            } else if bounds.minX - 12 - Self.size.width >= visible.minX {
                return NSPoint(x: bounds.minX - 12 - Self.size.width, y: y)
            }
            origin.y = windowBottom + 14
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - Self.size.width - 8)
        return origin
    }
}

struct HelperView: View {
    let kind: PermissionKind
    let close: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            AppDragSource()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("把 LaunchUS 拖进「\(kind.title)」列表")
                    .font(.system(size: 13, weight: .semibold))
                Text("然后打开它右边的开关")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .frame(width: 380, height: 92)
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 1))
    }
}

/// The app icon as a drag source carrying LaunchUS.app's file URL.
private struct AppDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }
    func updateNSView(_ view: DragSourceView, context: Context) {}
}

final class DragSourceView: NSView, NSDraggingSource {
    private let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    private var downEvent: NSEvent?

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) { downEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        downEvent = nil
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: down, source: self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}
