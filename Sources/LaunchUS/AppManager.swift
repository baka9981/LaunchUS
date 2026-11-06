import AppKit
import Charts
import SwiftUI

/// The App manager: every installed app with its size, chip and last use, to find what can
/// go (Intel apps, big ones, ones not opened for months) and which have updates; and how
/// LaunchUS has been used.
struct AppManagerCard: View {
    let model: LauncherModel

    enum Tab: Hashable { case apps, stats }
    // Debug aid: LAUNCHUS_SHEET=stats opens on the statistics.
    @State private var tab = ProcessInfo.processInfo.environment["LAUNCHUS_SHEET"] == "stats" ? Tab.stats : .apps

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("App 管理").font(.system(size: 17, weight: .semibold))
                Spacer()
                Picker("", selection: $tab) {
                    Text("App").tag(Tab.apps)
                    Text("使用统计").tag(Tab.stats)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Button(String(localized: "完成")) { model.sheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            switch tab {
            case .apps: ManagedAppList(model: model)
            case .stats: UsageStatsView(model: model)
            }
        }
    }
}

// MARK: - Apps

private struct ManagedAppList: View {
    let model: LauncherModel
    private var inventory: AppInventory { .shared }

    enum Filter: Hashable, CaseIterable { case all, intel, updates, stale }
    enum Sort: Hashable, CaseIterable {
        case size, lastUsed, name, added
        var title: String {
            switch self {
            case .size: String(localized: "按大小")
            case .lastUsed: String(localized: "按上次使用")
            case .name: String(localized: "按名称")
            case .added: String(localized: "按安装时间")
            }
        }
    }

    @State private var filter = Filter.all
    @State private var sort = Sort.size

    private var apps: [AppItem] {
        model.catalog.apps.filter { $0.custom == nil && !SettingsPanes.isPane($0.id) }
    }

    private func matches(_ app: AppItem, _ filter: Filter) -> Bool {
        switch filter {
        case .all: true
        case .intel: inventory.infos[app.id]?.architecture == .intel
        case .updates: inventory.updates[app.id] != nil
        case .stale: LauncherModel.isStale(app, recent: model.recentIDs)
        }
    }

    private var shown: [AppItem] {
        let list = apps.filter { matches($0, filter) }
        switch sort {
        case .size:
            return list.sorted { (inventory.sizes[$0.id] ?? -1) > (inventory.sizes[$1.id] ?? -1) }
        case .lastUsed:
            // Longest unused first: what's worth removing comes to the top.
            return list.sorted { ($0.lastUsedDate ?? .distantPast) < ($1.lastUsedDate ?? .distantPast) }
        case .name:
            return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .added:
            return list.sorted { ($0.addedDate ?? .distantPast) > ($1.addedDate ?? .distantPast) }
        }
    }

    private func title(_ filter: Filter) -> String {
        let name = switch filter {
        case .all: String(localized: "全部")
        case .intel: "Intel"
        case .updates: String(localized: "有更新")
        case .stale: String(localized: "3 个月没打开")
        }
        return "\(name) \(apps.filter { matches($0, filter) }.count)"
    }

    var body: some View {
        let shown = shown
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { f in
                    Chip(title: title(f), selected: filter == f) { filter = f }
                }
                Spacer()
                MenuPicker(selection: $sort, options: Sort.allCases, title: \.title)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { app in
                        ManagedAppRow(model: model, app: app)
                        Divider().padding(.leading, 64)
                    }
                }
                .padding(.horizontal, 12)
            }
            .overlay {
                if shown.isEmpty {
                    Text(filter == .updates && inventory.lastChecked == nil
                         ? String(localized: "点「检查更新」看看哪些 App 有新版本")
                         : String(localized: "没有这样的 App"))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }

            Divider()
            footer(shown)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .onAppear { inventory.scan(apps) }
    }

    @ViewBuilder
    private func footer(_ shown: [AppItem]) -> some View {
        HStack(spacing: 12) {
            let total = shown.compactMap { inventory.sizes[$0.id] }.reduce(0, +)
            Text("\(shown.count) 个 App，共 \(Uninstaller.format(total))")
                .monospacedDigit()
            if inventory.sizes.count < apps.count {
                ProgressView().controlSize(.small)
                Text("正在计算大小…")
            }
            Spacer()
            if let checking = inventory.checking {
                ProgressView(value: Double(checking.done), total: Double(max(checking.total, 1)))
                    .frame(width: 120)
                Text("\(checking.done)/\(checking.total)").monospacedDigit()
            } else {
                if let checked = inventory.lastChecked {
                    Text("已检查 \(inventory.checkable) 个，\(inventory.updates.count) 个有更新 · \(checked.formatted(date: .omitted, time: .shortened))")
                        .monospacedDigit()
                }
                Button(String(localized: "检查更新")) {
                    inventory.checkUpdates(apps)
                    filter = .updates
                }
                .help(String(localized: "向使用 Sparkle 的 App 各自的更新服务器和 App Store 查询最新版本，只查询，不会自动更新"))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
}

private struct ManagedAppRow: View {
    let model: LauncherModel
    let app: AppItem
    private var inventory: AppInventory { .shared }
    @State private var hovering = false

    var body: some View {
        let info = inventory.infos[app.id]
        HStack(spacing: 12) {
            if let icon = model.catalog.icons[app.id] {
                Image(decorative: icon, scale: 2).resizable().frame(width: 36, height: 36)
            } else {
                Color.clear.frame(width: 36, height: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if info?.architecture == .intel {
                        tag("Intel", .orange).help(AppInfo.Architecture.intel.title)
                    }
                    if let update = inventory.updates[app.id] {
                        Button { open(update) } label: {
                            tag(String(localized: "可更新到 \(update.version)"), .green)
                        }
                        .buttonStyle(.plain)
                        .help(update.source == .appStore ? String(localized: "在 App Store 中打开")
                              : String(localized: "打开这个 App，用它自己的更新功能更新"))
                    }
                }
                Text(verbatim: info?.version ?? " ")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(inventory.sizes[app.id].map(Uninstaller.format) ?? "—")
                .frame(width: 80, alignment: .trailing)
            Text(app.lastUsedDate.map(Self.relative) ?? String(localized: "没有记录"))
                .foregroundStyle(LauncherModel.isStale(app, recent: model.recentIDs) ? .orange : .secondary)
                .frame(width: 96, alignment: .trailing)
            HStack(spacing: 2) {
                iconButton("info.circle", String(localized: "简介…")) { model.openFromManager(.appInfo(app.id)) }
                iconButton("trash", String(localized: "卸载…")) { model.openFromManager(.confirmTrash(app.id)) }
                    .disabled(!app.isRemovable)
                    .opacity(app.isRemovable ? 1 : 0.3)
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
        .onHover { hovering = $0 }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func open(_ update: AppUpdate) {
        model.close()
        NSWorkspace.shared.open(update.page ?? app.url)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Usage statistics

private struct UsageStatsView: View {
    let model: LauncherModel
    @State private var log = LaunchLog.load()
    @State private var hours = LaunchHours.load()

    private func name(_ id: String) -> String? { model.app(id)?.name }

    var body: some View {
        let top = LaunchLog.top(log, days: 7).compactMap { item in name(item.id).map { (item.id, $0, item.count) } }
        let days = LaunchLog.perDay(log, days: 14)
        let week = days.suffix(7).reduce(0) { $0 + $1.count }
        let byHour = (0..<24).map { h in hours.values.reduce(0) { $0 + ($1.count == 24 ? $1[h] : 0) } }
        let system = model.catalog.apps.filter { $0.custom == nil && $0.useCount > 0 }
            .sorted { $0.useCount > $1.useCount }.prefix(8)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    figure(String(localized: "今天"), days.last?.count ?? 0)
                    figure(String(localized: "最近 7 天"), week)
                    figure(String(localized: "最近 14 天"), days.reduce(0) { $0 + $1.count })
                }
                if log.isEmpty {
                    Text("用 LaunchUS 打开 App 后，这里会显示你常用哪些 App、每天打开多少次")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        section(String(localized: "最近 7 天最常打开")) {
                            Chart(Array(top.prefix(8)), id: \.0) { item in
                                BarMark(x: .value("次数", item.2), y: .value("App", item.1))
                                    .annotation(position: .trailing) {
                                        Text("\(item.2)").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                            }
                            .chartXAxis(.hidden)
                            .frame(height: 200)
                        }
                        section(String(localized: "每天打开次数")) {
                            Chart(days, id: \.date) { day in
                                BarMark(x: .value("日期", day.date, unit: .day), y: .value("次数", day.count))
                            }
                            .chartXAxis {
                                AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                                }
                            }
                            .frame(height: 200)
                        }
                    }
                }
                if byHour.contains(where: { $0 > 0 }) {
                    section(String(localized: "一天中的时段")) {
                        Chart(Array(byHour.enumerated()), id: \.offset) { item in
                            BarMark(x: .value("时", item.offset), y: .value("次数", item.element))
                        }
                        .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) }
                        .chartYAxis(.hidden)
                        .frame(height: 110)
                    }
                }
                if !system.isEmpty {
                    section(String(localized: "系统记录的打开次数（包括不经 LaunchUS 打开）")) {
                        VStack(spacing: 6) {
                            ForEach(Array(system)) { app in
                                HStack(spacing: 8) {
                                    if let icon = model.catalog.icons[app.id] {
                                        Image(decorative: icon, scale: 2).resizable().frame(width: 20, height: 20)
                                    }
                                    Text(app.name)
                                    Spacer()
                                    Text("\(app.useCount) 次").foregroundStyle(.secondary).monospacedDigit()
                                }
                                .font(.system(size: 12))
                            }
                        }
                    }
                }
                HStack {
                    Text("统计只保存在这台 Mac 上，记录最近 8 周通过 LaunchUS 打开的 App")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "清空统计")) {
                        confirmAlert(String(localized: "清空使用统计？"),
                                     String(localized: "「猜你想找」也会重新学习你的习惯。"),
                                     button: String(localized: "清空")) {
                            LaunchLog.reset()
                            LaunchHours.reset()
                            log = [:]
                            hours = [:]
                        }
                    }
                    .disabled(log.isEmpty && hours.isEmpty)
                }
            }
            .padding(20)
        }
    }

    private func figure(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text("\(value)").font(.system(size: 22, weight: .semibold)).monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
    }
}
