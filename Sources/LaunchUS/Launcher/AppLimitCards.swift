import SwiftUI

/// 限时使用: how long an app may be in front each day, and what happens when the time is up.
struct AppLimitCard: View {
    let model: LauncherModel
    let app: AppItem
    @State private var on = true
    @State private var minutes = 60
    @State private var action = AppUsage.Action.hide
    @State private var locked = false

    private static let presets = [15, 30, 45, 60, 90, 120, 180, 240, 360, 480]
    private var key: String { app.bundleID ?? app.id }

    var body: some View {
        let usage = AppUsage.shared
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(model: model, app: app, title: String(localized: "限时使用"),
                       subtitle: String(localized: "今天已用 \(usageText(usage.seconds(key)))"))
            Toggle(String(localized: "每天限时"), isOn: $on)
            if on {
                Picker(String(localized: "每天可以用"), selection: $minutes) {
                    ForEach(Self.presets, id: \.self) { m in
                        Text(m < 60 ? String(localized: "\(m) 分钟") : usageText(Double(m * 60))).tag(m)
                    }
                }
                Picker(String(localized: "时间到了"), selection: $action) {
                    ForEach(AppUsage.Action.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(actionHint).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(String(localized: "延长和修改限时需要 Touch ID 或登录密码"), isOn: $locked)
            Text(String(localized: "用时按这个 App 在最前面的时间计算，离开电脑超过 5 分钟不算。记录只存在这台 Mac 上。"))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(String(localized: "取消")) { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button(String(localized: "好")) { save() }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .onAppear {
            // Opening the card is asking for a limit, so the switch starts on.
            let limit = usage.limit(key)
            on = true
            minutes = limit?.minutes ?? 60
            action = limit?.action ?? .hide
            locked = usage.locked
        }
    }

    private var actionHint: String {
        switch action {
        case .remind: String(localized: "到时间发一条通知，App 照常可以用。")
        case .hide: String(localized: "到时间隐藏 App，再切回去也会马上隐藏。在启动台里点它可以再用 15 分钟。")
        case .quit: String(localized: "到时间让 App 退出（有没存的内容它会先问你）。在启动台里点它可以再用 15 分钟。")
        }
    }

    private func save() {
        let usage = AppUsage.shared
        let old = usage.limit(key)
        let new = on ? AppUsage.Limit(minutes: minutes, action: action, extraUntil: old?.extraUntil) : nil
        let apply = {
            usage.setLimit(new, for: key)
            usage.setLocked(locked)
            model.sheet = nil
        }
        // Tightening a limit or adding one never needs unlocking; loosening does.
        let loosens = old != nil && (new == nil || new!.minutes > old!.minutes || (old!.action != .remind && new!.action == .remind))
            || (usage.locked && !locked)
        if loosens {
            usage.authorize(String(localized: "更改 \(app.name) 的限时")) { apply() }
        } else {
            apply()
        }
    }
}

/// Clicking an app whose time is up.
struct LimitReachedCard: View {
    let model: LauncherModel
    let app: AppItem

    var body: some View {
        let usage = AppUsage.shared
        let key = app.bundleID ?? app.id
        let limit = usage.limit(key)
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(model: model, app: app, title: String(localized: "\(app.name) 今天的时间到了"),
                       subtitle: String(localized: "今天已用 \(usageText(usage.seconds(key)))，限额 \(limit?.minutes ?? 0) 分钟。"))
            HStack {
                Button(String(localized: "修改限时…")) { model.sheet = .appLimit(app.id) }
                Spacer()
                Button(String(localized: "再用 15 分钟")) {
                    usage.authorize(String(localized: "让 \(app.name) 再用 15 分钟")) {
                        usage.extend(key)
                        model.sheet = nil
                        model.launch(app)
                    }
                }
                Button(String(localized: "好")) { model.sheet = nil }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
    }
}
