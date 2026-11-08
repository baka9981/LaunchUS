import AppKit
import EventKit
import SwiftUI

extension GridMetrics {
    /// Where a widget's card is drawn, in launcher coordinates: from the top-left of its first
    /// cell's artwork to the bottom-right of its last, so it lines up with the icons around it.
    func widgetRect(slot: Int, span: (width: Int, height: Int)) -> CGRect {
        widgetRect(first: iconCenter(slot: slot), span: span)
    }

    func widgetRect(first: CGPoint, span: (width: Int, height: Int)) -> CGRect {
        let art = iconSize * 0.8
        let width = CGFloat(span.width - 1) * cellSize.width + art
        let height = CGFloat(span.height - 1) * cellSize.height + art
        return CGRect(x: first.x - art / 2, y: first.y - art / 2, width: width, height: height)
    }

    /// Centre of the first cell's icon for a card centred at `center`.
    func widgetFirstCell(center: CGPoint, span: (width: Int, height: Int)) -> CGPoint {
        CGPoint(x: center.x - CGFloat(span.width - 1) * cellSize.width / 2,
                y: center.y - CGFloat(span.height - 1) * cellSize.height / 2)
    }
}

/// A widget on the grid with its name under it, as the icons have. Click opens the app it
/// comes from, dragging moves it, a long press starts jiggle mode.
struct WidgetCell: View {
    let widget: WidgetItem
    let model: LauncherModel
    let metrics: GridMetrics
    /// The card's frame in launcher coordinates.
    let rect: CGRect
    let selected: Bool

    @GestureState private var pressing = false
    /// The card's frame in the launcher, for working out what a click landed on.
    @State private var cardFrame: CGRect = .zero
    @State private var longPress: DispatchWorkItem?
    @State private var longPressFired = false

    var body: some View {
        let isDragged = model.draggedID == "widget:" + widget.id
        VStack(spacing: metrics.labelGap + metrics.iconSize * 0.1) {
            let typing = model.editingNoteID == widget.id
            WidgetCard(widget: widget, size: rect.size, live: model.isPresented && !isDragged, editing: typing)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(LauncherView.space)) } action: { cardFrame = $0 }
                .contentShape(RoundedRectangle(cornerRadius: WidgetCard.radius(for: metrics.iconSize), style: .continuous))
                .modifier(MenuLift(id: "widget:" + widget.id, size: min(rect.width, rect.height), scale: 1.03))
                .overlay(alignment: .topLeading) {
                    if model.isEditing, !isDragged {
                        DeleteBadge { model.removeWidget(widget.id) }
                            .offset(x: -9, y: -9)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: WidgetCard.radius(for: metrics.iconSize), style: .continuous)
                            .strokeBorder(metrics.windowed ? Color.accentColor : .white.opacity(0.8), lineWidth: 2)
                    }
                }
                .brightness(pressing && !typing && !Self.pressesInside(widget) ? -0.15 : 0)
                .gesture(pressGesture, including: typing ? .subviews : .all)
            if !metrics.hideNames {
                Text(WidgetCard.title(widget))
                    .lineLimit(1)
                    .font(.system(size: metrics.labelSize))
                    .foregroundStyle(metrics.windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white.opacity(0.95)))
                    .shadow(color: .black.opacity(metrics.windowed ? 0 : 0.28), radius: 2, y: 0.5)
                    .opacity(model.settings.hideNames ? 0 : 1)
            }
        }
        .modifier(Wiggle(active: model.isEditing && !isDragged, seed: widget.id.utf8.reduce(0) { $0 &+ Int($1) } / 3))
        .opacity(isDragged ? 0 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetCard.title(widget))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.activate(.widget(widget)) }
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(LauncherView.space))
            .updating($pressing) { value, state, _ in
                state = hypot(value.translation.width, value.translation.height) < 5 && model.drag == nil
            }
            .onChanged { value in
                guard model.drag == nil, !model.dragJustEnded else { return }
                if hypot(value.translation.width, value.translation.height) < 5 {
                    guard longPress == nil else { return }
                    longPressFired = false
                    let work = DispatchWorkItem {
                        longPressFired = true
                        withAnimation { model.isEditing = true }
                    }
                    longPress = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
                } else {
                    longPress?.cancel()
                    longPress = nil
                    model.beginDrag(.widget(widget), inFolder: nil, pointer: value.location,
                                    iconCenter: CGPoint(x: rect.midX, y: rect.midY))
                }
            }
            .onEnded { value in
                longPress?.cancel()
                longPress = nil
                defer { longPressFired = false }
                guard hypot(value.translation.width, value.translation.height) < 5, !longPressFired,
                      model.drag == nil, !model.dragJustEnded else { return }
                if model.editingNoteID == widget.id { return }
                model.endNoteEditing()
                let point = CGPoint(x: value.startLocation.x - cardFrame.minX, y: value.startLocation.y - cardFrame.minY)
                model.activateWidget(widget, at: point, card: cardFrame.size)
            }
    }

    /// Widgets with buttons of their own, and the note (it turns into a text field), don't darken as a whole when pressed.
    private static func pressesInside(_ widget: WidgetItem) -> Bool {
        [BuiltInWidget.note, .apps, .actions, .todo, .clipboard].map(\.rawValue).contains(widget.kind)
    }
}

/// The rounded card and what's on it.
struct WidgetCard: View {
    let widget: WidgetItem
    let size: CGSize
    /// Off while the launcher is hidden, so nothing ticks in the background.
    var live = true
    /// A note being typed on shows the editor instead of its text.
    var editing = false
    @Environment(\.windowedStyle) private var windowed

    static func radius(for iconSize: CGFloat) -> CGFloat { iconSize * 0.8 * 0.225 }

    static func title(_ widget: WidgetItem) -> String {
        WidgetRegistry.shared.provider(widget.kind)?.name ?? String(localized: "未安装的小组件")
    }

    /// The text scales with the card, so widgets read the same on any grid.
    private var unit: CGFloat {
        let cells = widget.size.cells
        return min(size.width / CGFloat(cells.width), size.height / CGFloat(cells.height))
    }

    private var padding: CGFloat { min(size.width, size.height) * 0.09 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(size.width, size.height) * 0.12, style: .continuous)
        let provider = WidgetRegistry.shared.provider(widget.kind)
        let isPlugin = provider?.isPlugin == true
        let note = widget.kind == BuiltInWidget.note.rawValue ? WidgetStore.shared.note(widget.id) : nil
        content(provider)
            // Plugins lay out their own margins over the whole card, and a photo fills it.
            .padding(isPlugin || widget.kind == BuiltInWidget.photo.rawValue ? 0 : padding)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .foregroundStyle(note != nil ? AnyShapeStyle(Color.black.opacity(0.8))
                             : windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .background {
                if let note {
                    // Paper, not glass: a darker band on top, like a real sticky note.
                    shape.fill(note.color.paper)
                        .overlay(alignment: .top) {
                            note.color.band.frame(height: padding * 0.7)
                        }
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                } else if Settings.shared.liquidGlass {
                    shape.fill(windowed ? AnyShapeStyle(.clear) : AnyShapeStyle(.black.opacity(0.12)))
                        .glassEffect(windowed ? .regular : .clear, in: shape)
                } else {
                    shape.fill(windowed ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.black.opacity(0.28)))
                        .overlay(shape.strokeBorder(.white.opacity(windowed ? 0.25 : 0.18), lineWidth: 0.5))
                }
            }
            .clipShape(shape)
            .environment(\.colorScheme, note != nil ? .light : windowed ? colorScheme : .dark)
    }

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder private func content(_ provider: WidgetProvider?) -> some View {
        switch provider?.source {
        case .builtIn(.clock)?: ClockWidget(size: widget.size, unit: unit, live: live)
        case .builtIn(.system)?: SystemStatusWidget(size: widget.size, unit: unit, live: live)
        case .builtIn(.calendar)?: CalendarWidget(size: widget.size, unit: unit, live: live)
        case .builtIn(.analogClock)?: AnalogClockWidget(size: widget.size, unit: unit, live: live)
        case .builtIn(.countdown)?: CountdownWidget(size: widget.size, unit: unit, live: live)
        case .builtIn(.progress)?: ProgressWidget(size: widget.size, unit: unit, live: live)
        case .builtIn(.battery)?: BatteryWidget(size: widget.size, unit: unit, live: live)
        case .builtIn(.network)?: NetworkWidget(size: widget.size, unit: unit, live: live)
        case .builtIn(.storage)?: StorageWidget(size: widget.size, unit: unit, live: live)
        case .builtIn(.note)?:
            if editing { NoteEditor(id: widget.id, unit: unit) } else { NoteWidget(id: widget.id, size: widget.size, unit: unit) }
        case .builtIn(.apps)?: AppsWidget(id: widget.id, size: widget.size, unit: unit, card: size)
        case .builtIn(.timer)?: TimerWidget(id: widget.id, size: widget.size, unit: unit, card: size, live: live)
        case .builtIn(.actions)?: ActionsWidget(size: widget.size, unit: unit, card: size)
        case .builtIn(.todo)?: TodoWidget(id: widget.id, size: widget.size, unit: unit, card: size, editing: editing)
        case .builtIn(.clipboard)?: ClipboardWidget(id: widget.id, size: widget.size, unit: unit, card: size)
        case .builtIn(.group)?: GroupWidget(id: widget.id, size: widget.size, unit: unit, card: size)
        case .builtIn(.photo)?: PhotoWidget(id: widget.id, unit: unit, card: size)
        case .builtIn(.currency)?: CurrencyWidget(id: widget.id, size: widget.size, unit: unit, live: live)
        case .plugin(let folder, let manifest)?:
            PluginWidgetView(folder: folder, manifest: manifest, size: widget.size, frame: size, unit: unit,
                             dark: !windowed || colorScheme == .dark, live: live,
                             generation: WidgetRegistry.shared.generation)
        case nil:
            MissingWidget(kind: widget.kind, unit: unit)
        }
    }
}

/// A widget whose plugin was removed: says which, until it's put back or removed.
private struct MissingWidget: View {
    let kind: String
    let unit: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: unit * 0.06) {
            Image(systemName: "puzzlepiece.extension").font(.system(size: unit * 0.3))
            Spacer(minLength: 0)
            Text(String(localized: "未安装的小组件")).font(.system(size: unit * 0.13, weight: .semibold))
            Text(verbatim: kind).font(.system(size: unit * 0.1)).opacity(0.6).lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Clock

struct ClockWidget: View {
    let size: WidgetItem.Size
    let unit: CGFloat
    let live: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: live ? 1 : 3600)) { context in
            let now = context.date
            switch size {
            case .small:
                VStack(alignment: .leading, spacing: unit * 0.04) {
                    Text(now, format: .dateTime.weekday(.wide))
                        .font(.system(size: unit * 0.16, weight: .semibold))
                        .foregroundStyle(.red)
                    Text(now, format: .dateTime.month().day())
                        .font(.system(size: unit * 0.16, weight: .medium))
                        .opacity(0.8)
                    Spacer(minLength: 0)
                    Text(Self.time(now))
                        .font(.system(size: unit * 0.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    if let lunar = Self.lunar(now) {
                        Text(lunar).font(.system(size: unit * 0.13)).opacity(0.7)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            case .medium, .large:
                VStack(alignment: .leading, spacing: unit * 0.12) {
                    HStack(alignment: .top, spacing: unit * 0.2) {
                        VStack(alignment: .leading, spacing: unit * 0.04) {
                            Text(now, format: .dateTime.weekday(.wide).month().day())
                                .font(.system(size: unit * 0.16, weight: .semibold))
                                .foregroundStyle(.red)
                            Text(Self.time(now))
                                .font(.system(size: unit * 0.58, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            Text(Self.seconds(now))
                                .font(.system(size: unit * 0.14, design: .rounded))
                                .monospacedDigit()
                                .opacity(0.6)
                            if let lunar = Self.lunar(now) {
                                Text(lunar).font(.system(size: unit * 0.14)).opacity(0.7)
                            }
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: unit * 0.1) {
                            ForEach(Self.worldClocks, id: \.identifier) { zone in
                                WorldClock(zone: zone, now: now, unit: unit)
                            }
                        }
                    }
                    if size == .large {
                        Divider().opacity(0.4)
                        MonthGrid(now: now, unit: unit)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
    }

    static func seconds(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    /// The Chinese calendar date, for Chinese-speaking users.
    static func lunar(_ date: Date) -> String? {
        guard Locale.preferredLanguages.first?.hasPrefix("zh") == true else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .chinese)
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "农历MMMd"
        return f.string(from: date)
    }

    /// Three far-apart cities, leaving out the one the Mac is in.
    static let worldClocks: [TimeZone] = {
        let here = TimeZone.current.secondsFromGMT()
        return ["America/New_York", "Europe/London", "Asia/Shanghai", "Asia/Tokyo"]
            .compactMap(TimeZone.init(identifier:))
            .filter { $0.secondsFromGMT() != here }
            .prefix(3)
            .map { $0 }
    }()
}

struct WorldClock: View {
    let zone: TimeZone
    let now: Date
    let unit: CGFloat

    var body: some View {
        var cal = Calendar.current
        cal.timeZone = zone
        let hour = cal.component(.hour, from: now)
        let diff = (zone.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)) / 3600
        return HStack(spacing: unit * 0.08) {
            Image(systemName: (6..<18).contains(hour) ? "sun.max.fill" : "moon.fill")
                .font(.system(size: unit * 0.12))
                .foregroundStyle((6..<18).contains(hour) ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
            VStack(alignment: .trailing, spacing: 0) {
                Text(Self.city(zone)).font(.system(size: unit * 0.12, weight: .medium))
                Text(verbatim: diff == 0 ? "" : diff > 0 ? "+\(diff)h" : "\(diff)h")
                    .font(.system(size: unit * 0.1)).opacity(0.6)
            }
            Text(now.formatted(Date.FormatStyle(timeZone: zone).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                .font(.system(size: unit * 0.2, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    static func city(_ zone: TimeZone) -> String {
        switch zone.identifier {
        case "America/New_York": String(localized: "纽约")
        case "Europe/London": String(localized: "伦敦")
        case "Asia/Shanghai": String(localized: "北京")
        case "Asia/Tokyo": String(localized: "东京")
        default: zone.localizedName(for: .shortGeneric, locale: .current) ?? zone.identifier
        }
    }
}

/// This month, today circled.
struct MonthGrid: View {
    let now: Date
    let unit: CGFloat

    var body: some View {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .month, for: now)?.start ?? now
        let days = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let lead = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
        let today = cal.component(.day, from: now)
        let symbols = Array(cal.veryShortWeekdaySymbols[(cal.firstWeekday - 1)...] + cal.veryShortWeekdaySymbols[..<(cal.firstWeekday - 1)])
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        VStack(alignment: .leading, spacing: unit * 0.06) {
            Text(now, format: .dateTime.year().month(.wide))
                .font(.system(size: unit * 0.14, weight: .semibold))
            LazyVGrid(columns: columns, spacing: unit * 0.04) {
                ForEach(0..<7, id: \.self) { i in
                    Text(symbols[i]).font(.system(size: unit * 0.1, weight: .semibold)).opacity(0.5)
                }
                ForEach(0..<(lead + days), id: \.self) { i in
                    let day = i - lead + 1
                    Text(day > 0 ? "\(day)" : "")
                        .font(.system(size: unit * 0.12, weight: day == today ? .bold : .regular))
                        .monospacedDigit()
                        .frame(width: unit * 0.22, height: unit * 0.22)
                        .background(Circle().fill(day == today ? Color.red : .clear))
                }
            }
        }
    }
}

// MARK: - System

struct SystemStatusWidget: View {
    let size: WidgetItem.Size
    let unit: CGFloat
    let live: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: live ? 2 : 3600)) { _ in
            let s = SystemStats.shared.sample()
            switch size {
            case .small:
                RingGrid(items: [
                    .init(value: s.cpu, label: "CPU", color: .blue),
                    .init(value: s.memory, label: String(localized: "内存"), color: .green),
                    .init(value: s.disk, label: String(localized: "磁盘"), color: .orange),
                    s.battery.map { .init(value: $0, label: String(localized: "电池"), color: $0 < 0.2 ? .red : .mint,
                                          symbol: s.charging ? "bolt.fill" : nil) }
                        ?? .init(value: min(1, s.download / (10 * 1024 * 1024)), label: String(localized: "下载"), color: .cyan,
                                 text: Self.shortRate(s.download)),
                ], unit: unit)
            case .medium, .large:
                VStack(alignment: .leading, spacing: unit * (size == .large ? 0.2 : 0.09)) {
                    Bar(title: "CPU", value: s.cpu, detail: Self.percent(s.cpu), color: .blue, unit: unit)
                    Bar(title: String(localized: "内存"), value: s.memory,
                        detail: "\(Self.bytes(Int64(s.memoryUsed))) / \(Self.bytes(Int64(s.memoryTotal)))", color: .green, unit: unit)
                    Bar(title: String(localized: "磁盘"), value: s.disk,
                        detail: "\(Self.bytes(s.diskUsed)) / \(Self.bytes(s.diskTotal))", color: .orange, unit: unit)
                    if let battery = s.battery {
                        Bar(title: String(localized: "电池"), value: battery,
                            detail: (s.charging ? "⚡︎ " : "") + Self.percent(battery), color: battery < 0.2 ? .red : .mint, unit: unit)
                    }
                    HStack(spacing: unit * 0.2) {
                        Label(Self.rate(s.download), systemImage: "arrow.down")
                        Label(Self.rate(s.upload), systemImage: "arrow.up")
                        Spacer(minLength: 0)
                        if size == .large {
                            Text(String(localized: "已运行 \(Self.uptime())")).opacity(0.6)
                        }
                    }
                    .font(.system(size: unit * 0.13, weight: .medium))
                    .monospacedDigit()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: size == .large ? .center : .topLeading)
            }
        }
    }

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    static func bytes(_ v: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: v, countStyle: .memory)
    }

    static func rate(_ v: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .binary) + "/s"
    }

    /// "1.2M", "340K": short enough for the middle of a ring.
    static func shortRate(_ v: Double) -> String {
        switch v {
        case ..<1024: "\(Int(v))B"
        case ..<(1024 * 1024): "\(Int(v / 1024))K"
        default: String(format: "%.1fM", v / 1024 / 1024)
        }
    }

    static func uptime() -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: ProcessInfo.processInfo.systemUptime) ?? ""
    }
}

struct Ring: View {
    let value: Double
    let label: String
    let color: Color
    let unit: CGFloat
    let diameter: CGFloat
    var symbol: String?
    /// Shown in the middle instead of the percentage.
    var text: String?

    var body: some View {
        let line = max(2, diameter * 0.12)
        VStack(spacing: unit * 0.05) {
            ZStack {
                Circle().stroke(.primary.opacity(0.15), lineWidth: line)
                Circle().trim(from: 0, to: max(0.001, value))
                    .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: value)
                if let symbol {
                    Image(systemName: symbol).font(.system(size: diameter * 0.28, weight: .bold))
                } else if let text {
                    Text(text)
                        .font(.system(size: diameter * 0.22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .padding(.horizontal, line)
                } else {
                    Text("\(Int((value * 100).rounded()))")
                        .font(.system(size: diameter * 0.3, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                }
            }
            .padding(line / 2)
            .frame(width: diameter, height: diameter)
            Text(label).font(.system(size: unit * 0.1, weight: .medium)).opacity(0.7).lineLimit(1)
        }
    }
}

struct Bar: View {
    let title: String
    let value: Double
    let detail: String
    let color: Color
    let unit: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: unit * 0.03) {
            HStack {
                Text(title).font(.system(size: unit * 0.12, weight: .semibold))
                Spacer(minLength: 0)
                Text(detail).font(.system(size: unit * 0.11)).monospacedDigit().opacity(0.7)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.15))
                    Capsule().fill(color).frame(width: max(unit * 0.06, geo.size.width * value))
                        .animation(.easeOut(duration: 0.5), value: value)
                }
            }
            .frame(height: unit * 0.06)
        }
    }
}

// MARK: - Calendar and reminders

private struct CalendarWidget: View {
    let size: WidgetItem.Size
    let unit: CGFloat
    let live: Bool
    private var data: WidgetEvents { WidgetEvents.shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: live ? 30 : 3600)) { context in
            let now = context.date
            let _ = live ? data.reload() : ()
            Group {
                if data.notAsked && !data.eventsAllowed && !data.remindersAllowed {
                    access(String(localized: "允许访问日历和提醒事项"), action: { data.requestAccess() })
                } else if !data.eventsAllowed && !data.remindersAllowed {
                    access(String(localized: "在系统设置中允许访问日历和提醒事项"), action: Self.openPrivacy)
                } else {
                    switch size {
                    case .small: small(now)
                    case .medium: medium(now)
                    case .large: large(now)
                    }
                }
            }
        }
    }

    private func access(_ title: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: unit * 0.1) {
            Image(systemName: "calendar.badge.exclamationmark").font(.system(size: unit * 0.3))
            Text(title).font(.system(size: unit * 0.13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: action) {
                Text(String(localized: "允许")).font(.system(size: unit * 0.12, weight: .semibold))
                    .padding(.horizontal, unit * 0.08).padding(.vertical, unit * 0.03)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    static func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func dateHeader(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(now, format: .dateTime.weekday(.wide))
                .font(.system(size: unit * 0.14, weight: .semibold))
                .foregroundStyle(.red)
            Text(now, format: .dateTime.day())
                .font(.system(size: unit * 0.5, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }

    private func small(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: unit * 0.06) {
            dateHeader(now)
            Spacer(minLength: 0)
            if let next = data.events.first {
                EventRow(event: next, unit: unit, compact: true)
            } else if let reminder = data.reminders.first {
                ReminderRow(reminder: reminder, unit: unit)
            } else {
                Text(String(localized: "今天没有日程")).font(.system(size: unit * 0.12)).opacity(0.6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func medium(_ now: Date) -> some View {
        HStack(alignment: .top, spacing: unit * 0.2) {
            dateHeader(now).frame(width: unit * 0.8, alignment: .leading)
            list(events: 3, reminders: 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func large(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: unit * 0.14) {
            HStack(alignment: .top) {
                dateHeader(now)
                Spacer(minLength: 0)
                MonthGrid(now: now, unit: unit * 0.85).frame(width: unit * 2)
            }
            Divider().opacity(0.4)
            list(events: 5, reminders: 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func list(events: Int, reminders: Int) -> some View {
        VStack(alignment: .leading, spacing: unit * 0.07) {
            if data.eventsAllowed {
                if data.events.isEmpty {
                    Text(String(localized: "今天没有日程")).font(.system(size: unit * 0.12)).opacity(0.6)
                }
                ForEach(data.events.prefix(events)) { EventRow(event: $0, unit: unit, compact: false) }
            }
            if data.remindersAllowed, !data.reminders.isEmpty {
                ForEach(data.reminders.prefix(reminders)) { ReminderRow(reminder: $0, unit: unit) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EventRow: View {
    let event: WidgetEvents.Event
    let unit: CGFloat
    let compact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: unit * 0.06) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: event.color)).frame(width: 3)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title).font(.system(size: unit * 0.12, weight: .semibold)).lineLimit(compact ? 2 : 1)
                Text(event.allDay ? String(localized: "全天") : "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: unit * 0.1)).opacity(0.65).monospacedDigit()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ReminderRow: View {
    let reminder: WidgetEvents.Reminder
    let unit: CGFloat

    var body: some View {
        HStack(spacing: unit * 0.06) {
            Image(systemName: "circle").font(.system(size: unit * 0.11)).foregroundStyle(Color(nsColor: reminder.color))
            Text(reminder.title).font(.system(size: unit * 0.12)).lineLimit(1)
            Spacer(minLength: 0)
            if let due = reminder.due {
                Text(due, format: Calendar.current.isDateInToday(due) ? .dateTime.hour().minute() : .dateTime.month().day())
                    .font(.system(size: unit * 0.1))
                    .foregroundStyle(due < Date() ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
        }
    }
}

extension WidgetCell {
    /// Card plus the name under it.
    static func height(_ rect: CGRect, _ metrics: GridMetrics) -> CGFloat {
        rect.height + (metrics.hideNames ? 0 : metrics.labelGap + metrics.iconSize * 0.1 + metrics.labelSize * 1.2)
    }
}
