import AppKit
import LocalAuthentication
import SwiftUI

/// Touch ID, or the login password where there's no Touch ID.
@MainActor
enum OwnerAuth {
    static func verify(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        // The prompt is a normal-level window; the launcher sits far above it.
        let panels = NSApp.windows.filter { $0 is LauncherPanel && $0.isVisible }
        let levels = panels.map(\.level)
        panels.forEach { $0.level = .normal }
        let ok = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                done.resume(returning: ok)
            }
        }
        zip(panels, levels).forEach { $0.level = $1 }
        NSApp.activate()
        panels.first?.makeKeyAndOrderFront(nil)
        return ok
    }
}

/// An invisible page dot after the last one; hovering shows a dashed outline.
struct PhantomDot: View {
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.windowedStyle) private var windowed

    var body: some View {
        Circle()
            .strokeBorder(windowed ? Color.primary.opacity(0.45) : .white.opacity(0.7),
                          style: StrokeStyle(lineWidth: 1, dash: [2, 1.6]))
            .frame(width: 8, height: 8)
            .opacity(hovering ? 1 : 0)
            .padding(4)
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
            .onTapGesture(perform: action)
            // A secret entrance: VoiceOver mustn't announce it.
            .accessibilityHidden(true)
    }
}

/// The empty cell after a page's last app. Right-click shows a dashed tile; clicking that opens
/// the hidden apps. Until then left clicks fall through to the background.
struct PhantomSlot: View {
    let model: LauncherModel
    let metrics: GridMetrics

    var body: some View {
        let size = metrics.iconSize * 0.8
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        let armed = model.phantomSlotArmed
        let ink: Color = metrics.windowed ? .primary : .white
        ZStack {
            shape
                .strokeBorder(ink.opacity(metrics.windowed ? 0.4 : 0.65),
                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .background(shape.fill(ink.opacity(metrics.windowed ? 0.04 : 0.06)))
                .overlay {
                    Image(systemName: "lock.fill")
                        .font(.system(size: size * 0.3, weight: .medium))
                        .foregroundStyle(ink.opacity(0.7))
                }
                .frame(width: size, height: size)
                // Where an app's name would be, so it reads as "click here".
                .overlay(alignment: .top) {
                    Text("点击验证")
                        .font(.system(size: metrics.labelSize))
                        .foregroundStyle(ink.opacity(0.85))
                        .shadow(color: .black.opacity(metrics.windowed ? 0 : 0.28), radius: 2, y: 0.5)
                        .fixedSize()
                        .offset(y: size + metrics.iconSize * 0.1 + metrics.labelGap)
                        .allowsHitTesting(false)
                }
                .scaleEffect(armed ? 1 : 0.85)
                .opacity(armed ? 1 : 0)
                .contentShape(shape)
                .onTapGesture { model.revealHidden() }
                .allowsHitTesting(armed)
            RightClickCatcher { model.armPhantomSlot() }
                .frame(width: size, height: size)
                .allowsHitTesting(!armed)
        }
        .accessibilityHidden(true)
    }
}

/// Takes right-clicks (and Control-clicks) only; everything else passes through.
private struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let menuClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return menuClick ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { action?() }
        override func mouseDown(with event: NSEvent) { action?() }
    }
}

/// The hidden apps, in a card over the grid like an open folder.
struct HiddenAppsPanel: View {
    let model: LauncherModel
    let metrics: GridMetrics
    @Environment(\.windowedStyle) private var windowed

    var body: some View {
        let apps = model.hiddenApps
        let columns = metrics.columns
        let rows = min(metrics.rows, max(1, (apps.count + columns - 1) / columns))
        let height = CGFloat(rows) * metrics.cellSize.height + 80
        let rect = CGRect(x: metrics.gridOriginX, y: (metrics.size.height * 0.51 - height / 2).rounded(),
                          width: metrics.gridWidth, height: height)
        let shape = RoundedRectangle(cornerRadius: metrics.folderCornerRadius, style: .continuous)
        let secondary: AnyShapeStyle = windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.6))

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "eye.slash")
                Text("隐藏的 App")
                Spacer()
                Button { model.lockHidden() } label: {
                    Label(String(localized: "锁定"), systemImage: "lock")
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(windowed ? Color.primary.opacity(0.08) : .white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help(String(localized: "重新隐藏，下次需要再次验证"))
            }
            .font(.system(size: windowed ? 18 : 20, weight: windowed ? .semibold : .light))
            .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white.opacity(0.85)))
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 10)

            if apps.isEmpty {
                VStack(spacing: 6) {
                    Text("没有隐藏的 App").font(.system(size: 15, weight: .medium))
                    Text("右键点击 App，选择「隐藏」").font(.system(size: 12)).foregroundStyle(secondary)
                }
                .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white.opacity(0.85)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(metrics.cellSize.width), spacing: 0), count: columns),
                              spacing: 0) {
                        ForEach(apps) { app in
                            HiddenAppCell(app: app, model: model, metrics: metrics)
                                .frame(height: metrics.cellSize.height)
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(width: rect.width, height: rect.height)
        .background {
            if windowed {
                shape.fill(.thickMaterial)
                    .overlay(shape.strokeBorder(.white.opacity(0.5), lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
            } else {
                shape.fill(.black.opacity(0.18))
                    .overlay(shape.strokeBorder(.white.opacity(0.16), lineWidth: 1))
            }
        }
        .clipShape(shape)
        .position(x: rect.midX, y: rect.midY)
    }
}

private struct HiddenAppCell: View {
    let app: AppItem
    let model: LauncherModel
    let metrics: GridMetrics
    @State private var pressed = false

    var body: some View {
        VStack(spacing: metrics.labelGap) {
            EntryIcon(entry: .app(app), icons: model.catalog.icons, size: metrics.iconSize)
            if !metrics.hideNames {
                Text(app.name)
                    .font(.system(size: metrics.labelSize))
                    .foregroundStyle(metrics.windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white.opacity(0.95)))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: metrics.cellSize.width - 8)
        .opacity(0.92)
        .contentShape(Rectangle())
        .onTapGesture { model.launch(app) }
        .nativeContextMenu {
            let menu = NSMenu.launcher()
            menu.add(String(localized: "打开"), symbol: "arrow.up.forward.app") { model.launch(app) }
            menu.add(String(localized: "在访达中显示"), symbol: "folder") { model.reveal(app.url.path) }
            menu.addSeparator()
            menu.add(String(localized: "取消隐藏"), symbol: "eye") { model.setHidden(false, for: app.id) }
            return menu
        }
    }
}
