import AppKit
import Charts
import SwiftUI

/// The App manager: every installed app with its size, chip and last use, to find what can
/// go (Intel apps, big ones, ones not opened for months) and which have updates; and how
/// LaunchUS has been used.
struct AppManagerCard: View {
    let model: LauncherModel

    enum Section: Hashable, CaseIterable {
        case all, intel, updates, stale, duplicates, leftovers, stats

        var title: String {
            switch self {
            case .all: String(localized: "全部 App")
            case .intel: "Intel"
            case .updates: String(localized: "有更新")
            case .stale: String(localized: "很久没打开")
            case .duplicates: String(localized: "重复的 App")
            case .leftovers: String(localized: "残留文件")
            case .stats: String(localized: "使用统计")
            }
        }

        var symbol: String {
            switch self {
            case .all: "square.grid.2x2"
            case .intel: "cpu"
            case .updates: "arrow.down.circle"
            case .stale: "moon.zzz"
            case .duplicates: "square.on.square"
            case .leftovers: "archivebox"
            case .stats: "chart.bar.xaxis"
            }
        }

        var tint: Color {
            switch self {
            case .all: .blue
            case .intel: .orange
            case .updates: .green
            case .stale: .indigo
            case .duplicates: .teal
            case .leftovers: .brown
            case .stats: .pink
            }
        }
    }

    // Debug aid: LAUNCHUS_SHEET=stats opens on the statistics.
    @State private var section = Self.debugSection

    private static var debugSection: Section {
        switch ProcessInfo.processInfo.environment["LAUNCHUS_SHEET"] {
        case "stats": .stats
        case "duplicates": .duplicates
        case "leftovers": .leftovers
        default: .all
        }
    }
    private var inventory: AppInventory { .shared }

    private var apps: [AppItem] {
        model.catalog.apps.filter { $0.custom == nil && !SettingsPanes.isPane($0.id) }
    }

    func matches(_ app: AppItem, _ section: Section) -> Bool {
        switch section {
        case .all, .stats, .duplicates, .leftovers: true
        case .intel: inventory.infos[app.id]?.architecture == .intel
        case .updates: inventory.updates[app.id] != nil
        case .stale: LauncherModel.isStale(app, recent: model.recentIDs)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                if section == .stats {
                    UsageStatsView(model: model)
                } else if section == .duplicates {
                    DuplicateAppsView(model: model)
                } else if section == .leftovers {
                    LeftoversView(model: model)
                } else {
                    ManagedAppList(model: model, section: section,
                                   apps: apps.filter { matches($0, section) }, allApps: apps)
                        .id(section)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            inventory.scan(apps)
            inventory.scanCleanup()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("App 管理")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 12)
            ForEach([Section.all, .intel, .updates, .stale], id: \.self) { item in
                sidebarItem(item, count: apps.filter { matches($0, item) }.count)
            }
            Divider().padding(.vertical, 8).padding(.horizontal, 10)
            sidebarItem(.duplicates, count: inventory.duplicates?.count)
            sidebarItem(.leftovers, count: inventory.leftovers?.count)
            Divider().padding(.vertical, 8).padding(.horizontal, 10)
            sidebarItem(.stats, count: nil)
            Spacer()
            Button { model.dismissSheet() } label: {
                Text("完成").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(14)
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.035))
    }

    private func sidebarItem(_ item: Section, count: Int?) -> some View {
        let selected = section == item
        return Button { section = item } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(item.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(item.title).font(.system(size: 13))
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                if item == .updates && inventory.checking != nil || (item == .duplicates || item == .leftovers) && inventory.cleaning {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.primary.opacity(0.09) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Apps

private struct ManagedAppList: View {
    let model: LauncherModel
    let section: AppManagerCard.Section
    let apps: [AppItem]
    let allApps: [AppItem]
    private var inventory: AppInventory { .shared }

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

    @State private var sort = Sort.size
    @State private var filter = ""

    private var shown: [AppItem] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        let list = text.isEmpty ? apps : AppSearch.search(text, in: apps)
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

    private var subtitle: String {
        let total = apps.compactMap { inventory.sizes[$0.id] }.reduce(0, +)
        var text = String(localized: "\(apps.count) 个 App，共 \(Uninstaller.format(total))")
        switch section {
        case .intel: text += " · " + String(localized: "需要 Rosetta 才能运行，留意开发者是否已推出 Apple 芯片版本")
        case .stale: text += " · " + String(localized: "超过 3 个月没打开")
        default: break
        }
        return text
    }

    var body: some View {
        let shown = shown
        let largest = max(shown.compactMap { inventory.sizes[$0.id] }.max() ?? 1, 1)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(section.title).font(.system(size: 20, weight: .bold))
                    Spacer()
                    if section == .updates { updateButton }
                }
                Text(subtitle)
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1)
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                        TextField(String(localized: "筛选"), text: $filter).textFieldStyle(.plain)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    MenuPicker(selection: $sort, options: Sort.allCases, title: \.title)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 20)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { app in
                        ManagedAppRow(model: model, app: app, largest: largest)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .overlay { if shown.isEmpty { emptyState } }

            if inventory.sizes.count < allApps.count {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在计算大小… \(inventory.sizes.count)/\(allApps.count)").monospacedDigit()
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var updateButton: some View {
        if let checking = inventory.checking {
            HStack(spacing: 8) {
                ProgressView(value: Double(checking.done), total: Double(max(checking.total, 1)))
                    .frame(width: 90)
                Text("\(checking.done)/\(checking.total)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        } else {
            Button {
                inventory.checkUpdates(allApps)
            } label: {
                Label(inventory.lastChecked == nil ? String(localized: "检查更新") : String(localized: "重新检查"),
                      systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .help(String(localized: "向使用 Sparkle 的 App 各自的更新服务器、App Store 和 Homebrew 查询最新版本，只查询，不会自动更新"))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: section == .updates && inventory.lastChecked != nil ? "checkmark.seal" : section.symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(section.tint.opacity(0.8))
            Group {
                if !filter.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("没有这样的 App")
                } else {
                    switch section {
                    case .updates where inventory.checking != nil: Text("正在检查…")
                    case .updates where inventory.lastChecked != nil:
                        Text("已检查 \(inventory.checkable) 个 App，都是最新版本")
                    case .updates: Text("点「检查更新」看看哪些 App 有新版本")
                    case .intel: Text("所有 App 都能直接在 Apple 芯片上运行")
                    case .stale: Text("没有超过 3 个月没打开的 App")
                    default: Text("没有这样的 App")
                    }
                }
            }
            .font(.system(size: 13)).foregroundStyle(.secondary)
            if section == .updates, inventory.lastChecked == nil, inventory.checking == nil {
                Text("只查询使用 Sparkle 自动更新的 App、从 App Store 和 Homebrew 安装的 App，不会自动更新")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(30)
    }
}

private struct ManagedAppRow: View {
    let model: LauncherModel
    let app: AppItem
    let largest: Int64
    private var inventory: AppInventory { .shared }
    @State private var hovering = false

    var body: some View {
        let info = inventory.infos[app.id]
        let size = inventory.sizes[app.id]
        let stale = LauncherModel.isStale(app, recent: model.recentIDs)
        HStack(spacing: 12) {
            Group {
                if let icon = model.catalog.icons[app.id] {
                    Image(decorative: icon, scale: 2).resizable()
                } else {
                    Color.clear
                }
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if info?.architecture == .intel {
                        Badge(text: "Intel", color: .orange).help(AppInfo.Architecture.intel.title)
                    }
                }
                HStack(spacing: 0) {
                    Text(verbatim: info?.version.map { String(localized: "版本 \($0)") } ?? "")
                    if info?.version != nil { Text(verbatim: "  ·  ") }
                    Text(app.lastUsedDate.map { String(localized: "\(Self.relative($0))打开过") } ?? String(localized: "没有打开记录"))
                        .foregroundStyle(stale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer(minLength: 8)

            if let update = inventory.updates[app.id] {
                Button { open(update) } label: {
                    Text("更新到 \(update.version)").lineLimit(1)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .help(help(for: update))
            }

            if hovering {
                HStack(spacing: 0) {
                    iconButton("info.circle", String(localized: "简介…")) { model.openFromManager(.appInfo(app.id)) }
                    if app.isRemovable {
                        iconButton("trash", String(localized: "卸载…")) { model.openFromManager(.confirmTrash(app.id)) }
                    }
                }
            }

            VStack(alignment: .trailing, spacing: 4) {
                Text(size.map(Uninstaller.format) ?? "—")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                Capsule().fill(Color.primary.opacity(0.08))
                    .frame(width: 70, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.accentColor.opacity(0.7))
                            .frame(width: size.map { max(3, 70 * CGFloat($0) / CGFloat(largest)) } ?? 0, height: 4)
                    }
            }
            .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(String(localized: "简介…")) { model.openFromManager(.appInfo(app.id)) }
            Button(String(localized: "在访达中显示")) { model.sheet = nil; model.reveal(app.url.path) }
            if app.isRemovable {
                Divider()
                Button(String(localized: "卸载…")) { model.openFromManager(.confirmTrash(app.id)) }
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.secondary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func help(for update: AppUpdate) -> String {
        switch update.source {
        case .appStore: String(localized: "在 App Store 中打开")
        case .sparkle: String(localized: "打开这个 App，用它自己的更新功能更新")
        case .homebrew(let token): String(localized: "用 Homebrew 安装的。点按拷贝 brew upgrade --cask \(token)，在终端中运行")
        }
    }

    private func open(_ update: AppUpdate) {
        if case .homebrew(let token) = update.source {
            let command = "brew upgrade --cask \(token)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            model.showNotice(String(localized: "已拷贝「\(command)」，在终端中粘贴运行"))
            return
        }
        model.close()
        NSWorkspace.shared.open(update.page ?? app.url)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Usage statistics

private struct UsageStatsView: View {
    let model: LauncherModel
    @State private var log = LaunchLog.load()
    @State private var hours = LaunchHours.load()

    var body: some View {
        let top = LaunchLog.top(log, days: 7).compactMap { item in model.app(item.id).map { ($0, item.count) } }
        let days = LaunchLog.perDay(log, days: 14)
        let thisWeek = days.suffix(7).reduce(0) { $0 + $1.count }
        let lastWeek = days.prefix(7).reduce(0) { $0 + $1.count }
        let byHour = (0..<24).map { h in hours.values.reduce(0) { $0 + ($1.count == 24 ? $1[h] : 0) } }
        let system = model.catalog.apps.filter { $0.custom == nil && $0.useCount > 0 }
            .sorted { $0.useCount > $1.useCount }.prefix(8)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("使用统计").font(.system(size: 20, weight: .bold))
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
                    .controlSize(.small)
                    .disabled(log.isEmpty && hours.isEmpty)
                }

                HStack(spacing: 10) {
                    tile(String(localized: "今天"), days.last?.count ?? 0, symbol: "sun.max.fill", tint: .orange)
                    tile(String(localized: "最近 7 天"), thisWeek, symbol: "calendar", tint: .blue,
                         note: lastWeek > 0 ? change(thisWeek, lastWeek) : nil)
                    tile(String(localized: "常用 App"), top.count, symbol: "star.fill", tint: .pink)
                }

                if log.isEmpty {
                    panel {
                        VStack(spacing: 10) {
                            Image(systemName: "chart.bar.xaxis").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                            Text("用 LaunchUS 打开 App 后，这里会显示你常用哪些 App、每天打开多少次")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                } else {
                    panel(String(localized: "最近 7 天最常打开")) {
                        let most = max(top.first?.1 ?? 1, 1)
                        VStack(spacing: 8) {
                            ForEach(Array(top.prefix(6)), id: \.0.id) { app, count in
                                HStack(spacing: 10) {
                                    appIcon(app, 22)
                                    Text(app.name).font(.system(size: 12)).lineLimit(1).frame(width: 120, alignment: .leading)
                                    GeometryReader { geo in
                                        Capsule().fill(Color.accentColor.gradient)
                                            .frame(width: max(6, geo.size.width * CGFloat(count) / CGFloat(most)), height: 8)
                                            .frame(maxHeight: .infinity)
                                    }
                                    .frame(height: 22)
                                    Text("\(count)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                                        .frame(width: 34, alignment: .trailing)
                                }
                            }
                        }
                    }
                    panel(String(localized: "每天打开次数")) {
                        Chart(days, id: \.date) { day in
                            BarMark(x: .value("日期", day.date, unit: .day), y: .value("次数", day.count), width: .ratio(0.6))
                                .foregroundStyle(Calendar.current.isDateInToday(day.date)
                                                 ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.accentColor.opacity(0.35)))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                                AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                                AxisValueLabel()
                            }
                        }
                        .frame(height: 140)
                    }
                }

                if let peak = byHour.indices.max(by: { byHour[$0] < byHour[$1] }), byHour[peak] > 0 {
                    panel(String(localized: "一天中的时段"), note: String(localized: "你最常在 \(peak) 点左右打开 App")) {
                        let most = max(byHour.max() ?? 1, 1)
                        VStack(spacing: 5) {
                            HStack(spacing: 3) {
                                ForEach(0..<24, id: \.self) { h in
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color.accentColor.opacity(byHour[h] == 0 ? 0.06 : 0.15 + 0.85 * Double(byHour[h]) / Double(most)))
                                        .frame(height: 26)
                                        .help(Text(verbatim: "\(h):00"))
                                }
                            }
                            HStack {
                                ForEach([0, 6, 12, 18], id: \.self) { h in
                                    Text(verbatim: "\(h):00").frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }

                if !system.isEmpty {
                    panel(String(localized: "macOS 记录的打开次数"), note: String(localized: "包括不经 LaunchUS 打开的")) {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())], spacing: 10) {
                            ForEach(Array(system.enumerated()), id: \.element.id) { index, app in
                                HStack(spacing: 8) {
                                    Text("\(index + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                                        .frame(width: 14)
                                    appIcon(app, 22)
                                    Text(app.name).font(.system(size: 12)).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(app.useCount.formatted()).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                }

                Label(String(localized: "统计只保存在这台 Mac 上，记录最近 8 周通过 LaunchUS 打开的 App"), systemImage: "lock.fill")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(20)
        }
    }

    private func change(_ now: Int, _ before: Int) -> String {
        let percent = Int((Double(now - before) / Double(before) * 100).rounded())
        let text = (percent >= 0 ? "+" : "") + "\(percent)%"
        return String(localized: "比上周 \(text)")
    }

    @ViewBuilder
    private func appIcon(_ app: AppItem, _ size: CGFloat) -> some View {
        if let icon = model.catalog.icons[app.id] {
            Image(decorative: icon, scale: 2).resizable().frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    private func tile(_ title: String, _ value: Int, symbol: String, tint: Color, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint)
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(value)").font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                if let note { Text(note).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private func panel<Content: View>(_ title: String? = nil, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}
