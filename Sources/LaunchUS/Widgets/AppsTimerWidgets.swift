import AppKit
import SwiftUI
import UserNotifications

// MARK: - Frequent apps

struct AppsWidget: View {
    let size: WidgetItem.Size
    let unit: CGFloat
    let card: CGSize

    static func shape(_ size: WidgetItem.Size) -> (columns: Int, rows: Int) {
        switch size {
        case .small: (2, 2)
        case .medium: (4, 2)
        case .large: (4, 4)
        }
    }

    @MainActor static func apps(for size: WidgetItem.Size) -> [AppItem] {
        guard let model = WidgetHost.model else { return [] }
        _ = model.widgetLaunches
        let (c, r) = shape(size)
        return RecentLaunches.row(apps: model.visibleApps, recent: RecentLaunches.load(), pinned: RecentLaunches.pinned,
                                  removed: RecentLaunches.removed, limit: c * r, ownID: Bundle.main.bundleIdentifier)
    }

    /// The app under a click on the card.
    @MainActor static func app(at point: CGPoint, size: WidgetItem.Size, card: CGSize) -> AppItem? {
        let apps = apps(for: size)
        let (c, r) = shape(size)
        let local = ToolGrid.local(point, card: card)
        let cells = ToolGrid.cells(count: apps.count, columns: c, rows: r, in: ToolGrid.content(card).size)
        return cells.firstIndex { $0.contains(local) }.map { apps[$0] }
    }

    var body: some View {
        let apps = Self.apps(for: size)
        let (c, r) = Self.shape(size)
        let area = ToolGrid.content(card).size
        let cells = ToolGrid.cells(count: apps.count, columns: c, rows: r, in: area)
        if apps.isEmpty {
            VStack(alignment: .leading, spacing: unit * 0.06) {
                Image(systemName: "square.grid.2x2").font(.system(size: unit * 0.24))
                Spacer(minLength: 0)
                Text(String(localized: "打开几个 App 后会显示在这里")).font(.system(size: unit * 0.12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(0.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            let icons = WidgetHost.model?.catalog.icons ?? [:]
            let named = size == .large
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(apps, cells)), id: \.0.id) { app, cell in
                    let side = min(cell.width, cell.height) * (named ? 0.62 : 0.84)
                    VStack(spacing: unit * 0.04) {
                        if let icon = icons[app.id] {
                            Image(decorative: icon, scale: 2).resizable().interpolation(.high)
                                .frame(width: side, height: side)
                        } else {
                            RoundedRectangle(cornerRadius: side * 0.225, style: .continuous).fill(.primary.opacity(0.12))
                                .frame(width: side * 0.8, height: side * 0.8)
                                .frame(width: side, height: side)
                        }
                        if named {
                            Text(app.name).font(.system(size: unit * 0.1)).lineLimit(1).opacity(0.85)
                        }
                    }
                    .frame(width: cell.width, height: cell.height)
                    .offset(x: cell.minX, y: cell.minY)
                }
            }
            .frame(width: area.width, height: area.height, alignment: .topLeading)
        }
    }
}

// MARK: - Timer

struct TimerWidget: View {
    let id: String
    let size: WidgetItem.Size
    let unit: CGFloat
    let card: CGSize
    let live: Bool

    static let presets = [5, 15, 25, 45]

    enum Hit: Equatable { case toggle, preset(Int) }

    /// Where the ring and the length buttons sit, in content coordinates.
    static func layout(_ size: WidgetItem.Size, card: CGSize) -> (ring: CGRect, presets: [CGRect]) {
        let area = ToolGrid.content(card).size
        switch size {
        case .small:
            return (CGRect(origin: .zero, size: area), [])
        case .medium:
            let ring = CGRect(x: 0, y: 0, width: area.height, height: area.height)
            let rest = CGSize(width: area.width - area.height - area.height * 0.2, height: area.height)
            let gap = area.height * 0.08
            let cells = ToolGrid.cells(count: 4, columns: 2, rows: 2, in: rest, gap: gap)
                .map { $0.offsetBy(dx: area.width - rest.width, dy: 0) }
            return (ring, cells)
        case .large:
            let row = area.height * 0.17
            let gap = area.height * 0.05
            let ring = CGRect(x: 0, y: 0, width: area.width, height: area.height - row - gap * 2)
            let cells = ToolGrid.cells(count: 4, columns: 4, rows: 1, in: CGSize(width: area.width, height: row), gap: gap)
                .map { $0.offsetBy(dx: 0, dy: area.height - row) }
            return (ring, cells)
        }
    }

    static func hit(_ point: CGPoint, size: WidgetItem.Size, card: CGSize) -> Hit? {
        let local = ToolGrid.local(point, card: card)
        let (_, presets) = layout(size, card: card)
        if let i = presets.firstIndex(where: { $0.contains(local) }) { return .preset(Self.presets[i]) }
        return .toggle
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: live ? 0.5 : 3600)) { context in
            let t = WidgetStore.shared.timer(id)
            let now = context.date
            let (ring, presets) = Self.layout(size, card: card)
            ZStack(alignment: .topLeading) {
                dial(t, now: now, side: min(ring.width, ring.height))
                    .frame(width: ring.width, height: ring.height)
                    .offset(x: ring.minX, y: ring.minY)
                ForEach(Array(presets.enumerated()), id: \.offset) { i, cell in
                    let minutes = Self.presets[i]
                    let chosen = t.minutes == minutes
                    RoundedRectangle(cornerRadius: min(cell.height, cell.width) * 0.3, style: .continuous)
                        .fill(chosen ? AnyShapeStyle(Color.orange.opacity(0.9)) : AnyShapeStyle(.primary.opacity(0.12)))
                        .overlay {
                            Text(String(localized: "\(minutes) 分钟"))
                                .font(.system(size: unit * 0.12, weight: .semibold))
                                .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        }
                        .frame(width: cell.width, height: cell.height)
                        .offset(x: cell.minX, y: cell.minY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func dial(_ t: WidgetStore.TimerState, now: Date, side: CGFloat) -> some View {
        let left = t.remaining(at: now)
        let finished = t.isFinished(at: now)
        let fraction = t.total > 0 ? left / t.total : 0
        let line = side * 0.075
        return ZStack {
            Circle().stroke(.primary.opacity(0.15), lineWidth: line)
            Circle().trim(from: 0, to: finished ? 1 : max(0.001, fraction))
                .stroke(finished ? Color.green : Color.orange, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: side * 0.02) {
                if finished {
                    Image(systemName: "checkmark").font(.system(size: side * 0.16, weight: .bold)).foregroundStyle(.green)
                    Text(String(localized: "时间到")).font(.system(size: side * 0.1, weight: .semibold))
                } else {
                    Text(Self.clock(left))
                        .font(.system(size: side * 0.2, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Label(t.isRunning ? String(localized: "暂停") : t.left != nil ? String(localized: "继续") : String(localized: "开始"),
                          systemImage: t.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: side * 0.08, weight: .medium))
                        .opacity(0.65)
                }
            }
        }
        .padding(line / 2)
        .frame(width: side, height: side)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
