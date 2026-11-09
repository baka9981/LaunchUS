import AppKit
import SwiftUI

// How much the Mac (or one app) was used each day, laid out week by week like a contribution
// graph. Time in front comes from AppUsage; launches from the launcher's own log.

struct HeatmapWidget: View {
    let id: String
    let size: WidgetItem.Size
    let unit: CGFloat
    let card: CGSize
    let live: Bool

    /// The app this widget follows, nil for all of them.
    @MainActor static func hotspot(_ id: String) -> AppItem? {
        guard let appID = WidgetStore.shared.extras(id).hotspot else { return nil }
        return WidgetHost.model?.app(appID)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: live ? 60 : 3600)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let extras = WidgetStore.shared.extras(id)
        let launches = extras.countLaunches == true
        let app = Self.hotspot(id)
        let appKey = app.map { $0.bundleID ?? $0.id }
        let launchLog = launches ? LaunchLog.load() : [:]
        let value: (Date) -> Double = { date in
            if launches {
                let day = launchLog[LaunchLog.day(date)] ?? [:]
                return Double(app.map { day[$0.id] ?? 0 } ?? day.values.reduce(0, +))
            }
            return AppUsage.shared.total(on: date, app: appKey)
        }
        let area = ToolGrid.content(card).size
        let header = unit * 0.3
        let listHeight = size == .large ? area.height * 0.42 : 0
        let gridArea = CGSize(width: area.width, height: area.height - header - listHeight - (size == .large ? unit * 0.1 : 0))
        VStack(alignment: .leading, spacing: 0) {
            headerRow(app: app, today: value(now), launches: launches)
                .frame(height: header, alignment: .topLeading)
            grid(in: gridArea, now: now, value: value,
                 icon: extras.heatIcons == true ? { date in Self.icon(on: date, app: app, launches: launches, launchLog: launchLog) } : nil)
            if size == .large {
                Spacer(minLength: unit * 0.1)
                if app == nil {
                    topApps(now: now, launches: launches, launchLog: launchLog)
                        .frame(height: listHeight, alignment: .top)
                } else {
                    summary(now: now, value: value, launches: launches).frame(height: listHeight, alignment: .top)
                }
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
    }

    private func headerRow(app: AppItem?, today: Double, launches: Bool) -> some View {
        HStack(spacing: unit * 0.06) {
            if let app, let icon = WidgetHost.model?.catalog.icons[app.id] {
                Image(decorative: icon, scale: 2).resizable().interpolation(.high).frame(width: unit * 0.22, height: unit * 0.22)
            } else {
                Image(systemName: "square.grid.3x3.square").font(.system(size: unit * 0.13, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(app?.name ?? String(localized: "使用热点图")).font(.system(size: unit * 0.11, weight: .semibold)).lineLimit(1)
                Text(launches ? String(localized: "今天打开 \(Int(today)) 次") : String(localized: "今天 \(usageText(today))"))
                    .font(.system(size: unit * 0.09)).opacity(0.6).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// Columns are weeks, oldest on the left; rows are the days of the week.
    /// The icon a day shows in the App 图标 style: the followed app's, or that day's most used.
    @MainActor private static func icon(on date: Date, app: AppItem?, launches: Bool, launchLog: [String: [String: Int]]) -> CGImage? {
        guard let model = WidgetHost.model else { return nil }
        if let app { return model.catalog.icons[app.id] }
        let day = LaunchLog.day(date)
        let top: String? = launches
            ? launchLog[day]?.max { $0.value < $1.value }?.key
            : AppUsage.shared.log[day]?.max { $0.value < $1.value }?.key
                ?? (Calendar.current.isDateInToday(date) ? NSWorkspace.shared.frontmostApplication?.bundleIdentifier : nil)
        guard let top, let item = model.app(top) else { return nil }
        return model.catalog.icons[item.id]
    }

    private func grid(in area: CGSize, now: Date, value: (Date) -> Double, icon: ((Date) -> CGImage?)?) -> some View {
        let cal = Calendar.current
        let gap = max(1.5, unit * 0.025)
        let cell = max(4, (area.height - gap * 6) / 7)
        let weeks = max(1, Int((area.width + gap) / (cell + gap)))
        let today = cal.startOfDay(for: now)
        // The column of today ends on today; days before the week's start fill earlier columns.
        let weekday = (cal.component(.weekday, from: today) - cal.firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -(weeks - 1) * 7 - weekday, to: today) ?? today
        let days: [(Date, Double)] = (0..<(weeks * 7)).compactMap { i in
            guard let date = cal.date(byAdding: .day, value: i, to: start), date <= today else { return nil }
            return (date, value(date))
        }
        let peak = max(days.map(\.1).max() ?? 0, 1)
        let width = CGFloat(weeks) * cell + CGFloat(weeks - 1) * gap
        return ZStack(alignment: .topLeading) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                let level = day.1 / peak
                Group {
                    if day.1 > 0, let image = icon?(day.0) {
                        // Busier days are bigger and brighter.
                        Image(decorative: image, scale: 2).resizable().interpolation(.medium)
                            .frame(width: cell * (0.7 + 0.35 * level), height: cell * (0.7 + 0.35 * level))
                            .opacity(0.45 + 0.55 * level)
                    } else {
                        RoundedRectangle(cornerRadius: cell * 0.25, style: .continuous)
                            .fill(day.1 <= 0 ? AnyShapeStyle(.primary.opacity(0.09))
                                  : AnyShapeStyle(Color(red: 0.2, green: 0.78, blue: 0.4).opacity(0.3 + 0.7 * level)))
                    }
                }
                    .frame(width: cell, height: cell)
                    .help(Text(verbatim: "\(day.0.formatted(date: .abbreviated, time: .omitted))"))
                    .offset(x: CGFloat(i / 7) * (cell + gap), y: CGFloat(i % 7) * (cell + gap))
            }
        }
        .frame(width: width, height: cell * 7 + gap * 6, alignment: .topLeading)
        .frame(width: area.width, height: area.height, alignment: .trailing)
    }

    private func topApps(now: Date, launches: Bool, launchLog: [String: [String: Int]]) -> some View {
        let model = WidgetHost.model
        let rows: [(AppItem, Double)] = {
            let list: [(String, Double)] = launches
                ? LaunchLog.top(launchLog, days: 7, now: now).map { ($0.id, Double($0.count)) }
                : AppUsage.shared.top(days: 7, now: now).map { ($0.id, $0.seconds) }
            return list.compactMap { id, v in model?.app(id).map { ($0, v) } }.prefix(4).map { $0 }
        }()
        let peak = max(rows.first?.1 ?? 1, 1)
        return VStack(alignment: .leading, spacing: unit * 0.06) {
            Text(String(localized: "最近 7 天")).font(.system(size: unit * 0.09, weight: .semibold)).opacity(0.6)
            if rows.isEmpty {
                Text(String(localized: "用一会儿电脑，这里会列出用得最多的 App"))
                    .font(.system(size: unit * 0.09)).opacity(0.55).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows, id: \.0.id) { app, v in
                HStack(spacing: unit * 0.06) {
                    if let icon = model?.catalog.icons[app.id] {
                        Image(decorative: icon, scale: 2).resizable().frame(width: unit * 0.2, height: unit * 0.2)
                    }
                    VStack(alignment: .leading, spacing: unit * 0.015) {
                        HStack {
                            Text(app.name).font(.system(size: unit * 0.09, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(launches ? String(localized: "\(Int(v)) 次") : usageText(v))
                                .font(.system(size: unit * 0.08)).opacity(0.6).monospacedDigit()
                        }
                        GeometryReader { geo in
                            Capsule().fill(Color(red: 0.2, green: 0.78, blue: 0.4).opacity(0.85))
                                .frame(width: max(2, geo.size.width * v / peak))
                        }
                        .frame(height: unit * 0.035)
                    }
                }
            }
        }
    }

    private func summary(now: Date, value: (Date) -> Double, launches: Bool) -> some View {
        let cal = Calendar.current
        let week = (0..<7).compactMap { cal.date(byAdding: .day, value: -$0, to: now) }.map(value)
        let month = (0..<30).compactMap { cal.date(byAdding: .day, value: -$0, to: now) }.map(value)
        let fmt: (Double) -> String = { launches ? String(localized: "\(Int($0.rounded())) 次") : usageText($0) }
        return VStack(alignment: .leading, spacing: unit * 0.08) {
            line(String(localized: "最近 7 天"), fmt(week.reduce(0, +)))
            line(String(localized: "每天平均"), fmt(month.reduce(0, +) / 30))
            line(String(localized: "最多的一天"), fmt(month.max() ?? 0))
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: unit * 0.1)).opacity(0.65)
            Spacer()
            Text(value).font(.system(size: unit * 0.11, weight: .semibold)).monospacedDigit()
        }
    }
}
