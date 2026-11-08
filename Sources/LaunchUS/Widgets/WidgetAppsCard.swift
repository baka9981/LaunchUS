import SwiftUI

/// Picking the apps a frequent-apps or app group widget shows, by hand.
struct WidgetAppsCard: View {
    let model: LauncherModel
    let id: String
    @State private var picked: [String] = []
    @State private var query = ""

    private var widget: WidgetItem? { model.widget(id) }
    private var isGroup: Bool { widget?.kind == BuiltInWidget.group.rawValue }

    /// The frequent-apps widget only has room for so many.
    private var limit: Int? {
        guard !isGroup, let widget else { return nil }
        let (c, r) = AppsWidget.shape(widget.size)
        return c * r
    }

    private var results: [AppItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let apps = q.isEmpty ? model.visibleApps.sorted { $0.name.compare($1.name, options: [.caseInsensitive, .numeric], locale: .current) == .orderedAscending }
            : model.search(q)
        return apps.filter { !SettingsPanes.isPane($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isGroup ? String(localized: "App 组里的 App") : String(localized: "常用应用里的 App"))
                    .font(.system(size: 17, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            chosen
            TextField(String(localized: "搜索 App"), text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { app in row(app) }
                }
            }
            .frame(height: 260)
            HStack {
                Button(isGroup ? String(localized: "改用文件夹") : String(localized: "改回按使用频率")) {
                    WidgetStore.shared.setAppList(nil, id)
                    model.sheet = nil
                }
                Spacer()
                Button(String(localized: "取消")) { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button(String(localized: "好")) {
                    WidgetStore.shared.setAppList(picked.isEmpty ? nil : picked, id)
                    model.sheet = nil
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .onAppear {
            picked = WidgetStore.shared.appList(id) ?? (isGroup ? GroupWidget.apps(id).map(\.id) : [])
        }
    }

    private var subtitle: String {
        if let limit { return String(localized: "按勾选的顺序排列，这个大小最多显示 \(limit) 个；一个都不选就按使用频率") }
        return String(localized: "点一下小组件就全部打开，按勾选的顺序排列")
    }

    /// The picks so far, in order; a click takes one out.
    private var chosen: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if picked.isEmpty {
                    Text(String(localized: "还没有选 App")).font(.system(size: 12)).foregroundStyle(.tertiary)
                        .frame(height: 34)
                }
                ForEach(Array(picked.enumerated()), id: \.element) { i, appID in
                    icon(appID, side: 34)
                        .opacity(limit.map { i < $0 } ?? true ? 1 : 0.35)
                        .onTapGesture { picked.removeAll { $0 == appID } }
                        .help(model.app(appID)?.name ?? "")
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func row(_ app: AppItem) -> some View {
        let on = picked.contains(app.id)
        return Button {
            if on { picked.removeAll { $0 == app.id } } else { picked.append(app.id) }
        } label: {
            HStack(spacing: 10) {
                icon(app.id, side: 24)
                Text(app.name).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func icon(_ appID: String, side: CGFloat) -> some View {
        if let icon = model.catalog.icons[appID] {
            Image(decorative: icon, scale: 2).resizable().interpolation(.high).frame(width: side, height: side)
        } else {
            RoundedRectangle(cornerRadius: side * 0.225, style: .continuous).fill(.primary.opacity(0.12))
                .frame(width: side, height: side)
        }
    }
}
