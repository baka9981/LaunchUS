import AppKit
import SwiftUI

// The newer built-in widgets: analog clock, holiday countdown, time progress, battery,
// network and storage. Every length is a multiple of `unit`, one cell's worth of points.

// MARK: - Shared pieces

/// Four gauges, each centred in its own quarter of a small card.
struct RingGrid: View {
    struct Item {
        var value: Double
        var label: String
        var color: Color
        var symbol: String?
        var text: String?
    }

    let items: [Item]
    let unit: CGFloat

    var body: some View {
        GeometryReader { geo in
            let quarter = CGSize(width: geo.size.width / 2, height: geo.size.height / 2)
            let ring = max(10, min(quarter.width * 0.72, quarter.height - unit * 0.23))
            VStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<2, id: \.self) { column in
                            let index = row * 2 + column
                            Group {
                                if index < items.count {
                                    let item = items[index]
                                    Ring(value: item.value, label: item.label, color: item.color, unit: unit, diameter: ring,
                                         symbol: item.symbol, text: item.text)
                                }
                            }
                            .frame(width: quarter.width, height: quarter.height)
                        }
                    }
                }
            }
        }
    }
}

/// A line graph of recent readings, scaled to `peak`.
struct Sparkline: View {
    let values: [Double]
    let peak: Double
    let color: Color
    var lineWidth: CGFloat = 1.5
    var filled = true
    /// How many readings fit across; fewer start from the right.
    var capacity = SystemStats.historyLength

    var body: some View {
        GeometryReader { geo in
            let step = geo.size.width / CGFloat(max(1, capacity - 1))
            let points = values.enumerated().map { i, v in
                CGPoint(x: geo.size.width - CGFloat(values.count - 1 - i) * step,
                        y: geo.size.height * (1 - CGFloat(min(1, peak > 0 ? v / peak : 0))))
            }
            ZStack {
                if filled, points.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    points.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// Small grey caption over a value, used down the side of the larger widgets.
private struct Fact: View {
    let title: String
    let value: String
    let unit: CGFloat

    var body: some View {
        HStack {
            Text(title).opacity(0.6)
            Spacer(minLength: unit * 0.1)
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .font(.system(size: unit * 0.12))
        .lineLimit(1)
    }
}

// MARK: - Analog clock

struct AnalogClockWidget: View {
    let size: WidgetItem.Size
    let unit: CGFloat
    let live: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: live ? 1 : 3600)) { context in
            let now = context.date
            let zones = [TimeZone.current] + ClockWidget.worldClocks
            switch size {
            case .small:
                ClockFace(date: now, zone: .current, numbers: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .medium:
                HStack(spacing: unit * 0.12) {
                    ForEach(zones, id: \.identifier) { zone in
                        labelled(zone, now: now) { ClockFace(date: now, zone: zone, numbers: false) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .large:
                // Two rows that share the height, so the faces shrink to fit
                // instead of growing with the column width and spilling out.
                VStack(spacing: unit * 0.16) {
                    ForEach(Array(stride(from: 0, to: zones.count, by: 2)), id: \.self) { start in
                        HStack(spacing: unit * 0.2) {
                            ForEach(zones[start..<min(start + 2, zones.count)], id: \.identifier) { zone in
                                labelled(zone, now: now) { ClockFace(date: now, zone: zone, numbers: true) }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func labelled(_ zone: TimeZone, now: Date, face: () -> ClockFace) -> some View {
        VStack(spacing: unit * 0.05) {
            face().aspectRatio(1, contentMode: .fit)
            Text(zone == .current ? String(localized: "本地") : WorldClock.city(zone))
                .font(.system(size: unit * 0.12, weight: .semibold))
                .lineLimit(1)
            Text(Self.offset(zone, now: now))
                .font(.system(size: unit * 0.1))
                .opacity(0.6)
                .lineLimit(1)
        }
    }

    /// "今天 +1小时", "明天 -8小时".
    static func offset(_ zone: TimeZone, now: Date) -> String {
        let hours = (zone.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)) / 3600
        var there = Calendar.current
        there.timeZone = zone
        let day = there.component(.day, from: now) - Calendar.current.component(.day, from: now)
        let when = day == 0 ? String(localized: "今天") : (day == 1 || day < -1) ? String(localized: "明天") : String(localized: "昨天")
        if hours == 0 { return when }
        return when + " " + (hours > 0 ? "+\(hours)" : "\(hours)") + String(localized: "小时")
    }
}

/// A watch face: light by day, dark by night in its time zone.
struct ClockFace: View {
    let date: Date
    let zone: TimeZone
    let numbers: Bool

    var body: some View {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let hour = c.hour ?? 0, minute = c.minute ?? 0
        let second = Double(c.second ?? 0)
        let day = (6..<18).contains(hour)
        let face = day ? Color.white : Color(white: 0.11)
        let ink = day ? Color.black : Color.white
        return Canvas { context, size in
            let r = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), with: .color(face))
            func point(_ fraction: Double, _ length: CGFloat) -> CGPoint {
                let angle = fraction * 2 * .pi - .pi / 2
                return CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length)
            }
            for tick in 0..<60 {
                let major = tick % 5 == 0
                if numbers && major { continue }
                let outer = r * 0.9, inner = r * (major ? 0.78 : 0.84)
                var p = Path()
                p.move(to: point(Double(tick) / 60, inner))
                p.addLine(to: point(Double(tick) / 60, outer))
                context.stroke(p, with: .color(ink.opacity(major ? 0.9 : 0.3)), lineWidth: major ? r * 0.035 : r * 0.015)
            }
            if numbers {
                for n in 1...12 {
                    let text = Text("\(n)").font(.system(size: r * 0.2, weight: .medium, design: .rounded)).foregroundColor(ink)
                    context.draw(text, at: point(Double(n) / 12, r * 0.74))
                }
            }
            func hand(_ fraction: Double, length: CGFloat, width: CGFloat, color: Color, tail: CGFloat = 0) {
                var p = Path()
                p.move(to: point(fraction + 0.5, tail))
                p.addLine(to: point(fraction, length))
                context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            let m = Double(minute) + second / 60
            hand((Double(hour % 12) + m / 60) / 12, length: r * 0.5, width: r * 0.075, color: ink)
            hand(m / 60, length: r * 0.78, width: r * 0.05, color: ink)
            hand(second / 60, length: r * 0.86, width: r * 0.02, color: .orange, tail: r * 0.16)
            let dot = r * 0.07
            context.fill(Path(ellipseIn: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2)), with: .color(.orange))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Holiday countdown

struct CountdownWidget: View {
    let size: WidgetItem.Size
    let unit: CGFloat
    let live: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: live ? 60 : 3600)) { context in
            let now = context.date
            let list = Holiday.upcoming(from: now)
            if let next = list.first {
                switch size {
                case .small: hero(next, now: now)
                case .medium:
                    HStack(alignment: .top, spacing: unit * 0.24) {
                        hero(next, now: now).frame(width: unit * 1.45)
                        rows(Array(list.dropFirst().prefix(3)), now: now)
                    }
                case .large:
                    VStack(alignment: .leading, spacing: unit * 0.16) {
                        hero(next, now: now).frame(height: unit * 1.5)
                        Divider().opacity(0.4)
                        rows(Array(list.dropFirst().prefix(7)), now: now)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func hero(_ holiday: Holiday, now: Date) -> some View {
        let days = holiday.days(from: now)
        return VStack(alignment: .leading, spacing: unit * 0.02) {
            Label(holiday.name, systemImage: holiday.symbol)
                .font(.system(size: unit * 0.14, weight: .semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)
            Spacer(minLength: 0)
            if days == 0 {
                Text(String(localized: "就是今天"))
                    .font(.system(size: unit * 0.3, weight: .bold, design: .rounded))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: unit * 0.04) {
                    Text("\(days)")
                        .font(.system(size: unit * 0.6, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                    Text(String(localized: "天")).font(.system(size: unit * 0.14, weight: .medium)).opacity(0.7)
                }
                .lineLimit(1)
            }
            Text(holiday.date, format: .dateTime.month().day().weekday(.abbreviated))
                .font(.system(size: unit * 0.11))
                .opacity(0.6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func rows(_ list: [Holiday], now: Date) -> some View {
        VStack(alignment: .leading, spacing: unit * 0.09) {
            ForEach(list) { holiday in
                HStack(spacing: unit * 0.08) {
                    Image(systemName: holiday.symbol)
                        .font(.system(size: unit * 0.11))
                        .foregroundStyle(.orange)
                        .frame(width: unit * 0.16)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(holiday.name).font(.system(size: unit * 0.12, weight: .semibold))
                        Text(holiday.date, format: .dateTime.month().day()).font(.system(size: unit * 0.1)).opacity(0.55)
                    }
                    Spacer(minLength: 0)
                    Text(String(localized: "\(holiday.days(from: now)) 天"))
                        .font(.system(size: unit * 0.13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Time progress

struct ProgressWidget: View {
    let size: WidgetItem.Size
    let unit: CGFloat
    let live: Bool

    private static let spans: [(TimeProgress.Span, Color)] = [(.day, .orange), (.week, .yellow), (.month, .green), (.year, .cyan)]

    static func title(_ span: TimeProgress.Span) -> String {
        switch span {
        case .day: String(localized: "今天")
        case .week: String(localized: "本周")
        case .month: String(localized: "本月")
        case .year: String(localized: "今年")
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: live ? 30 : 3600)) { context in
            let now = context.date
            switch size {
            case .small:
                RingGrid(items: Self.spans.map { span, color in
                    .init(value: TimeProgress.fraction(span, at: now), label: Self.title(span), color: color)
                }, unit: unit)
            case .medium:
                VStack(spacing: unit * 0.1) {
                    ForEach(Self.spans, id: \.0) { span, color in bar(span, color: color, now: now) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .large:
                VStack(alignment: .leading, spacing: unit * 0.14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(now, format: .dateTime.year())
                            .font(.system(size: unit * 0.3, weight: .bold, design: .rounded))
                        Spacer()
                        Text(SystemStatusWidget.percent(TimeProgress.fraction(.year, at: now)))
                            .font(.system(size: unit * 0.18, weight: .semibold, design: .rounded))
                            .foregroundStyle(.cyan)
                            .monospacedDigit()
                    }
                    YearDots(now: now, unit: unit)
                    VStack(spacing: unit * 0.1) {
                        ForEach(Self.spans.dropLast(), id: \.0) { span, color in bar(span, color: color, now: now) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func bar(_ span: TimeProgress.Span, color: Color, now: Date) -> some View {
        let value = TimeProgress.fraction(span, at: now)
        return Bar(title: Self.title(span), value: value,
                   detail: SystemStatusWidget.percent(value) + " · " + TimeProgress.remaining(span, at: now), color: color, unit: unit)
    }
}

/// Every day of the year as a dot, one row per month: gone, today, still to come.
private struct YearDots: View {
    let now: Date
    let unit: CGFloat

    var body: some View {
        let cal = Calendar.current
        let year = cal.component(.year, from: now)
        let start = cal.startOfDay(for: now)
        Canvas { context, size in
            let columns = 31, rows = 12
            let pitch = min(size.width / CGFloat(columns), size.height / CGFloat(rows))
            let dot = pitch * 0.62
            let x0 = (size.width - pitch * CGFloat(columns)) / 2
            for month in 1...rows {
                guard let first = cal.date(from: DateComponents(year: year, month: month, day: 1)),
                      let days = cal.range(of: .day, in: .month, for: first)?.count else { continue }
                for day in 1...days {
                    guard let date = cal.date(from: DateComponents(year: year, month: month, day: day)) else { continue }
                    let rect = CGRect(x: x0 + CGFloat(day - 1) * pitch + (pitch - dot) / 2,
                                      y: CGFloat(month - 1) * pitch + (pitch - dot) / 2, width: dot, height: dot)
                    let color: Color = date < start ? .white.opacity(0.75) : date == start ? .cyan : .white.opacity(0.16)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: unit * 1.55)
    }
}

// MARK: - Battery

@MainActor
private enum BatteryReading {
    static var cache: (time: Date, mac: BatteryDetails?, accessories: [Accessory])?

    static func read() -> (mac: BatteryDetails?, accessories: [Accessory]) {
        if let cache, Date().timeIntervalSince(cache.time) < 10 { return (cache.mac, cache.accessories) }
        let fresh = (time: Date(), mac: BatteryDetails.read(), accessories: Accessory.read())
        cache = fresh
        return (fresh.mac, fresh.accessories)
    }
}

struct BatteryWidget: View {
    let size: WidgetItem.Size
    let unit: CGFloat
    let live: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: live ? 10 : 3600)) { _ in
            let (mac, accessories) = BatteryReading.read()
            let gauges = Self.gauges(mac: mac, accessories: accessories)
            if gauges.isEmpty {
                VStack(alignment: .leading, spacing: unit * 0.08) {
                    Image(systemName: "powerplug").font(.system(size: unit * 0.3))
                    Spacer(minLength: 0)
                    Text(String(localized: "没有可显示的电池")).font(.system(size: unit * 0.13, weight: .semibold))
                    Text(String(localized: "连接蓝牙键盘、鼠标或触控板后会显示在这里。"))
                        .font(.system(size: unit * 0.1)).opacity(0.6).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                switch size {
                case .small: small(mac: mac, first: gauges[0])
                case .medium:
                    if let mac, gauges.count == 1 {
                        HStack(spacing: unit * 0.24) {
                            small(mac: nil, first: gauges[0]).frame(width: unit * 1.2)
                            details(mac).frame(maxHeight: .infinity)
                        }
                    } else {
                        row(Array(gauges.prefix(4)))
                    }
                case .large:
                    VStack(alignment: .leading, spacing: unit * 0.16) {
                        if let mac {
                            hero(mac: mac, gauge: gauges[0]).frame(height: unit * 1.25)
                            if gauges.count > 1 {
                                row(Array(gauges.dropFirst().prefix(4))).frame(height: unit * 1.05)
                            }
                            Divider().opacity(0.4)
                            details(mac)
                        } else {
                            row(Array(gauges.prefix(4))).frame(height: unit * 1.3)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    struct Gauge: Identifiable {
        var id: String
        var name: String
        var symbol: String
        var level: Double
        var charging: Bool
    }

    static func gauges(mac: BatteryDetails?, accessories: [Accessory]) -> [Gauge] {
        var list: [Gauge] = []
        if let mac {
            list.append(Gauge(id: "mac", name: "Mac", symbol: "laptopcomputer", level: mac.level, charging: mac.charging))
        }
        list += accessories.map { Gauge(id: $0.name, name: $0.name, symbol: $0.symbol, level: $0.level, charging: false) }
        return list
    }

    static func color(_ level: Double) -> Color { level < 0.2 ? .red : level < 0.4 ? .yellow : .green }

    private func small(mac: BatteryDetails?, first: Gauge) -> some View {
        VStack(spacing: unit * 0.1) {
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                ZStack {
                    let line = d * 0.1
                    Circle().stroke(.primary.opacity(0.15), lineWidth: line)
                    Circle().trim(from: 0, to: max(0.001, first.level))
                        .stroke(Self.color(first.level), style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Image(systemName: first.charging ? "bolt.fill" : first.symbol)
                            .font(.system(size: d * 0.14, weight: .semibold))
                            .foregroundStyle(first.charging ? AnyShapeStyle(.yellow) : AnyShapeStyle(.primary.opacity(0.7)))
                        Text(SystemStatusWidget.percent(first.level))
                            .font(.system(size: d * 0.22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }
                .padding(d * 0.05)
                .frame(width: geo.size.width, height: geo.size.height)
            }
            Text(mac.map(Self.status) ?? first.name)
                .font(.system(size: unit * 0.11, weight: .medium))
                .opacity(0.7)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// The Mac's battery large: a ring and the charge beside it.
    private func hero(mac: BatteryDetails, gauge: Gauge) -> some View {
        HStack(spacing: unit * 0.24) {
            small(mac: nil, first: gauge).frame(width: unit * 1.25)
            VStack(alignment: .leading, spacing: unit * 0.04) {
                Text(verbatim: "Mac").font(.system(size: unit * 0.12, weight: .semibold)).opacity(0.6)
                Text(SystemStatusWidget.percent(mac.level))
                    .font(.system(size: unit * 0.42, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(Self.status(mac)).font(.system(size: unit * 0.12, weight: .medium)).opacity(0.7).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ gauges: [Gauge]) -> some View {
        HStack(spacing: unit * 0.1) {
            ForEach(gauges) { gauge in
                VStack(spacing: unit * 0.06) {
                    GeometryReader { geo in
                        let d = min(geo.size.width, geo.size.height)
                        ZStack {
                            Circle().stroke(.primary.opacity(0.15), lineWidth: d * 0.09)
                            Circle().trim(from: 0, to: max(0.001, gauge.level))
                                .stroke(Self.color(gauge.level), style: StrokeStyle(lineWidth: d * 0.09, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: gauge.charging ? "bolt.fill" : gauge.symbol)
                                .font(.system(size: d * 0.3, weight: .medium))
                                .foregroundStyle(gauge.charging ? AnyShapeStyle(.yellow) : AnyShapeStyle(.primary))
                        }
                        .padding(d * 0.05)
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                    Text(SystemStatusWidget.percent(gauge.level))
                        .font(.system(size: unit * 0.14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(gauge.name).font(.system(size: unit * 0.09)).opacity(0.6).lineLimit(1)
                }
                .frame(maxWidth: unit * 0.95)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func details(_ mac: BatteryDetails) -> some View {
        VStack(spacing: unit * 0.08) {
            Fact(title: String(localized: "状态"), value: Self.status(mac), unit: unit)
            if let cycles = mac.cycles {
                Fact(title: String(localized: "循环次数"), value: "\(cycles)", unit: unit)
            }
            if let health = mac.health {
                Fact(title: String(localized: "最大容量"), value: SystemStatusWidget.percent(health), unit: unit)
            }
            if let t = mac.temperature {
                Fact(title: String(localized: "温度"), value: t.formatted(.number.precision(.fractionLength(1))) + " °C", unit: unit)
            }
        }
    }

    static func status(_ mac: BatteryDetails) -> String {
        let time = mac.minutesLeft.map { String(format: "%d:%02d", $0 / 60, $0 % 60) }
        if mac.charging {
            return time.map { String(localized: "\($0) 后充满") } ?? String(localized: "正在充电")
        }
        if mac.pluggedIn { return String(localized: "已接通电源") }
        return time.map { String(localized: "可用 \($0)") } ?? String(localized: "正在估算剩余时间")
    }
}

// MARK: - Network

struct NetworkWidget: View {
    let size: WidgetItem.Size
    let unit: CGFloat
    let live: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: live ? 2 : 3600)) { _ in
            let stats = SystemStats.shared
            let s = stats.sample()
            let down = stats.history.map(\.download), up = stats.history.map(\.upload)
            let peak = max(64 * 1024, (down + up).max() ?? 0) * 1.15
            switch size {
            case .small:
                VStack(alignment: .leading, spacing: unit * 0.03) {
                    rate(s.download, symbol: "arrow.down", color: .cyan, big: true)
                    rate(s.upload, symbol: "arrow.up", color: .pink, big: false)
                    Spacer(minLength: unit * 0.06)
                    graph(down: down, up: up, peak: peak)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .medium:
                HStack(spacing: unit * 0.24) {
                    VStack(alignment: .leading, spacing: unit * 0.06) {
                        rate(s.download, symbol: "arrow.down", color: .cyan, big: true)
                        rate(s.upload, symbol: "arrow.up", color: .pink, big: true)
                        Spacer(minLength: 0)
                        if let ip = NetworkInfo.localAddress() {
                            Text(ip).font(.system(size: unit * 0.1, design: .monospaced)).opacity(0.6).lineLimit(1)
                        }
                    }
                    .frame(width: unit * 1.25, alignment: .leading)
                    graph(down: down, up: up, peak: peak)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .large:
                VStack(alignment: .leading, spacing: unit * 0.14) {
                    HStack(spacing: unit * 0.3) {
                        rate(s.download, symbol: "arrow.down", color: .cyan, big: true)
                        rate(s.upload, symbol: "arrow.up", color: .pink, big: true)
                    }
                    graph(down: down, up: up, peak: peak)
                    VStack(spacing: unit * 0.08) {
                        Fact(title: String(localized: "本机地址"), value: NetworkInfo.localAddress() ?? String(localized: "未连接"), unit: unit)
                        Fact(title: String(localized: "已下载"), value: SystemStatusWidget.bytes(Int64(stats.totalDown)), unit: unit)
                        Fact(title: String(localized: "已上传"), value: SystemStatusWidget.bytes(Int64(stats.totalUp)), unit: unit)
                        Fact(title: String(localized: "两分钟内最快"), value: "↓ " + SystemStatusWidget.rate(down.max() ?? 0) + "  ↑ " + SystemStatusWidget.rate(up.max() ?? 0), unit: unit)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func rate(_ value: Double, symbol: String, color: Color, big: Bool) -> some View {
        HStack(spacing: unit * 0.05) {
            Image(systemName: symbol).font(.system(size: unit * (big ? 0.13 : 0.11), weight: .bold)).foregroundStyle(color)
            Text(SystemStatusWidget.rate(value))
                .font(.system(size: unit * (big ? 0.2 : 0.14), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private func graph(down: [Double], up: [Double], peak: Double) -> some View {
        ZStack {
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    Spacer(minLength: 0)
                    Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5)
                }
            }
            Sparkline(values: up, peak: peak, color: .pink, lineWidth: max(1, unit * 0.018), filled: false)
            Sparkline(values: down, peak: peak, color: .cyan, lineWidth: max(1.2, unit * 0.022))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Storage

struct StorageWidget: View {
    let size: WidgetItem.Size
    let unit: CGFloat
    let live: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: live ? 30 : 3600)) { _ in
            let volumes = VolumeUsage.read()
            if let startup = volumes.first {
                switch size {
                case .small: small(startup)
                case .medium:
                    if volumes.count == 1 {
                        HStack(spacing: unit * 0.3) {
                            small(startup)
                            facts(startup).frame(maxHeight: .infinity)
                        }
                    } else {
                        list(Array(volumes.prefix(3)))
                    }
                case .large:
                    VStack(alignment: .leading, spacing: unit * 0.16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(String(localized: "可用 \(SystemStatusWidget.bytes(volumes.reduce(0) { $0 + $1.free }))"))
                                .font(.system(size: unit * 0.24, weight: .bold, design: .rounded))
                            Spacer()
                            Text(String(localized: "\(volumes.count) 个磁盘")).font(.system(size: unit * 0.12)).opacity(0.6)
                        }
                        if volumes.count == 1 {
                            donut(startup).frame(height: unit * 1.5).frame(maxWidth: .infinity)
                            Divider().opacity(0.4)
                            facts(startup)
                            Spacer(minLength: 0)
                        } else {
                            list(Array(volumes.prefix(6)))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    static func color(_ fraction: Double) -> Color { fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .blue }

    private func small(_ volume: VolumeUsage) -> some View {
        VStack(alignment: .leading, spacing: unit * 0.04) {
            Label(volume.name, systemImage: "internaldrive")
                .font(.system(size: unit * 0.12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(SystemStatusWidget.bytes(volume.free))
                .font(.system(size: unit * 0.32, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(String(localized: "可用，共 \(SystemStatusWidget.bytes(volume.total))"))
                .font(.system(size: unit * 0.1))
                .opacity(0.6)
                .lineLimit(1)
            meter(volume.fraction).padding(.top, unit * 0.06)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func list(_ volumes: [VolumeUsage]) -> some View {
        VStack(spacing: unit * 0.14) {
            ForEach(volumes) { volume in
                HStack(spacing: unit * 0.1) {
                    Image(systemName: volume.removable ? "externaldrive.fill" : "internaldrive.fill")
                        .font(.system(size: unit * 0.18))
                        .opacity(0.8)
                        .frame(width: unit * 0.26)
                    VStack(alignment: .leading, spacing: unit * 0.04) {
                        HStack {
                            Text(volume.name).font(.system(size: unit * 0.12, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: unit * 0.1)
                            Text(String(localized: "可用 \(SystemStatusWidget.bytes(volume.free))"))
                                .font(.system(size: unit * 0.1)).opacity(0.65).monospacedDigit().lineLimit(1)
                        }
                        meter(volume.fraction)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func facts(_ volume: VolumeUsage) -> some View {
        VStack(spacing: unit * 0.08) {
            Fact(title: String(localized: "已用"), value: SystemStatusWidget.bytes(volume.used), unit: unit)
            Fact(title: String(localized: "可用"), value: SystemStatusWidget.bytes(volume.free), unit: unit)
            Fact(title: String(localized: "总容量"), value: SystemStatusWidget.bytes(volume.total), unit: unit)
        }
    }

    /// How full one disk is, as a ring with the name and percentage inside.
    private func donut(_ volume: VolumeUsage) -> some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().stroke(.primary.opacity(0.15), lineWidth: d * 0.09)
                Circle().trim(from: 0, to: max(0.001, volume.fraction))
                    .stroke(Self.color(volume.fraction), style: StrokeStyle(lineWidth: d * 0.09, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: d * 0.02) {
                    Image(systemName: volume.removable ? "externaldrive.fill" : "internaldrive.fill")
                        .font(.system(size: d * 0.12)).opacity(0.7)
                    Text(SystemStatusWidget.percent(volume.fraction))
                        .font(.system(size: d * 0.2, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(volume.name).font(.system(size: d * 0.08)).opacity(0.6).lineLimit(1)
                }
                .frame(width: d * 0.7)
            }
            .padding(d * 0.05)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func meter(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                Capsule().fill(Self.color(fraction)).frame(width: max(unit * 0.06, geo.size.width * fraction))
            }
        }
        .frame(height: unit * 0.06)
    }
}
