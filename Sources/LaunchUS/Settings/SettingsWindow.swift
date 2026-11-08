import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    // The list of layout profiles; the one being edited's settings; LaunchUS's own (what it
    // has only one of).
    case profiles
    case display, appearance, organize, general, behavior, hidden, apps, ai, manage
    /// LaunchUS's own MCP server: one for all profiles, so it's a page of its own.
    case mcp
    /// 激活码 and the conversation with the developer, LaunchUS's own like MCP.
    case license, feedback
    case advanced
    var id: String { rawValue }

    static let profileTabs: [SettingsTab] = [.display, .appearance, .organize, .general, .behavior, .apps, .hidden, .ai, .manage]
    /// The pages along the top; a profile's tabs are under 布局方案.
    static let topTabs: [SettingsTab] = [.profiles, .mcp, .license, .feedback, .advanced]

    var isProfileTab: Bool { Self.profileTabs.contains(self) }

    /// The settings group the tab shows, for copying it from another profile. 方案 has none: its
    /// name and language are what tell profiles apart.
    var group: ProfileSettings.Group? {
        switch self {
        case .display: .display
        case .appearance: .appearance
        case .organize: .organize
        case .general: .general
        case .behavior: .behavior
        case .hidden: .hidden
        case .apps: .apps
        case .ai: .ai
        default: nil
        }
    }

    /// Tab names used by links (`launchus://settings?tab=`), including ones from older versions.
    static func named(_ name: String) -> SettingsTab? {
        switch name.lowercased() {
        case "about": .advanced
        case "profile", "layouts": .profiles
        case "layout": .organize
        case "triggers", "open", "opening": .general
        case "backup", "backups": .manage
        case let other: SettingsTab(rawValue: other)
        }
    }

    var title: String {
        switch self {
        case .profiles: String(localized: "布局方案")
        case .general: String(localized: "打开（设置页）", defaultValue: "打开")
        case .behavior: String(localized: "行为（设置页）", defaultValue: "行为")
        case .display: String(localized: "显示（设置页）", defaultValue: "显示")
        case .appearance: String(localized: "外观")
        case .organize: String(localized: "整理")
        case .hidden: String(localized: "隐藏")
        case .apps: "Apps"
        case .ai: String(localized: "AI 网关")
        case .manage: String(localized: "方案（设置页）", defaultValue: "方案")
        case .mcp: "MCP"
        case .license: String(localized: "激活")
        case .feedback: String(localized: "反馈")
        case .advanced: String(localized: "通用")
        }
    }

    var symbol: String {
        switch self {
        case .profiles: "square.stack.3d.up"
        case .general: "hand.tap"
        case .behavior: "cursorarrow.click.2"
        case .display: "rectangle.3.group"
        case .appearance: "paintpalette"
        case .organize: "square.grid.3x3.topleft.filled"
        case .hidden: "eye.slash"
        case .apps: "square.grid.2x2"
        case .ai: "sparkles"
        case .manage: "rectangle.stack"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .license: "key"
        case .feedback: "bubble.left.and.text.bubble.right"
        case .advanced: "gearshape"
        }
    }
}

/// Things the settings window asks the app to do.
@MainActor
struct SettingsActions {
    var rescan: (_ done: @escaping (RescanResult) -> Void) -> Void
}

/// What a manual rescan found, for the notice shown afterwards.
struct RescanResult {
    var total: Int
    var added: Int
    var removed: Int

    var message: String {
        var parts = [String(localized: "已重新扫描，共 \(total) 个 App")]
        if added > 0 { parts.append(String(localized: "新增 \(added) 个")) }
        if removed > 0 { parts.append(String(localized: "移除 \(removed) 个")) }
        if added == 0 && removed == 0 { parts.append(String(localized: "没有变化")) }
        return parts.joined(separator: String(localized: "，"))
    }
}

/// The launcher, the settings and the cards over it float above modal windows; drop them below
/// while an alert or file panel is up.
@MainActor
enum Modal {
    static func run<T>(_ body: () -> T) -> T {
        let panels = CardWindows.floating()
        let levels = panels.map(\.level)
        panels.forEach { $0.level = .normal }
        defer { zip(panels, levels).forEach { $0.level = $1 } }
        return body()
    }
}

// MARK: - Root

/// The settings, in a window of their own (`CardWindows`; right-click on empty space › 设置…). Pages at
/// the top: 布局方案 lists the profiles, and 编辑 on one opens its own settings; MCP and 通用
/// hold LaunchUS's own.
struct SettingsView: View {
    @Bindable var model: LauncherModel
    @Bindable var settings: Settings
    let actions: SettingsActions

    var body: some View {
        let profile = model.currentProfile
        let tab = model.settingsTab
        VStack(spacing: 0) {
            if tab.isProfileTab {
                // Editing one profile: back to the list, its name, and its tabs.
                ProfileEditorBar(model: model, tab: tab)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .padding(.horizontal, 16)
            } else {
                HStack(spacing: 2) {
                    ForEach(SettingsTab.topTabs) { item in
                        TabButton(tab: item, selected: tab == item) { model.settingsTab = item }
                    }
                }
                .frame(width: 480)
                .padding(.vertical, 10)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch tab {
                    case .profiles: ProfilesTab(model: model)
                    case .display: DisplayTab(model: model, settings: settings)
                    case .appearance: AppearanceTab(model: model, settings: settings)
                    case .organize: OrganizeTab(model: model, settings: settings)
                    case .general: GeneralTab(model: model, settings: settings)
                    case .behavior: BehaviorTab(model: model, settings: settings)
                    case .hidden: HiddenAppsTab(model: model, settings: settings)
                    case .ai: AITab(settings: settings).id(profile)  // its key and chats are the profile's
                    case .apps: AppsTab(model: model, settings: settings, actions: actions)
                    case .manage: ManageTab(model: model, settings: settings)
                    case .mcp: MCPSection()
                    case .license: LicenseTab()
                    case .feedback: FeedbackTab()
                    case .advanced: AdvancedTab(model: model, settings: settings)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .id("\(tab.rawValue)/\(profile)")
        }
        .frame(width: 600)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 布局方案: every profile with what sets it apart; 编辑 opens its settings.
private struct ProfilesTab: View {
    let model: LauncherModel

    var body: some View {
        SettingsSection(title: String(localized: "布局方案")) {
            Text("每个方案有自己的页面、文件夹、隐藏的 App 和设置。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
            Card {
                ForEach(model.profileNames, id: \.self) { name in
                    ProfileRow(model: model, name: name)
                }
            }
            HStack {
                Spacer()
                Button {
                    model.closeSettings()
                    model.sheet = .newProfile
                } label: {
                    Label(String(localized: "新建方案…"), systemImage: "plus")
                }
            }
            .padding(.top, 2)
        }
    }
}

private struct ProfileRow: View {
    let model: LauncherModel
    let name: String

    var body: some View {
        let current = name == model.currentProfile
        let mode = model.profileMode(name)
        HStack(spacing: 14) {
            Image(nsImage: IconArt.image(model.appIcon(of: name), size: 96))
                .resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(LayoutProfiles.title(name)).font(.system(size: 14, weight: .semibold))
                    if current {
                        Text("正在使用").font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                Text(verbatim: details(mode: mode)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                if !current {
                    Button(String(localized: "使用")) { model.switchProfile(name, reopen: false) }
                        .help(String(localized: "切换到这个方案"))
                }
                Button(String(localized: "编辑")) {
                    model.switchProfile(name, reopen: false)
                    model.settingsTab = .display
                }
                Menu {
                    Button(String(localized: "重命名…")) {
                        model.closeSettings()
                        model.sheet = .renameProfile(name)
                    }
                    Button(String(localized: "删除方案…"), role: .destructive) { confirmDelete() }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 16)).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(name.isEmpty)
                .opacity(name.isEmpty ? 0.35 : 1)
                .help(name.isEmpty ? String(localized: "默认方案不能重命名或删除") : String(localized: "更多"))
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: model.profileLabel(name)))
    }

    /// "全屏 · 3 页 · ⌥Space"
    private func details(mode: DisplayMode) -> String {
        var parts = [mode.title]
        let pages = name == model.currentProfile ? model.layout.count : model.profiles.saved[name]?.count ?? 0
        parts.append(String(localized: "\(pages) 页"))
        if let key = model.profileSetting("hotKey", of: name, current: model.settings.hotKey, as: HotKeySpec?.self) ?? nil {
            parts.append(key.display)
        }
        if model.showsDockIcon(name) { parts.append(String(localized: "程序坞图标")) }
        if model.menuBarIcon(of: name) != nil { parts.append(String(localized: "菜单栏图标")) }
        return parts.joined(separator: " · ")
    }

    private func confirmDelete() {
        confirmAlert(String(localized: "删除方案「\(LayoutProfiles.title(name))」？"),
                     String(localized: "它的页面和设置会一起删除，App 本身不受影响。"),
                     button: String(localized: "删除")) { model.deleteProfile(name) }
    }
}

/// Above a profile's settings: back to the list, whose settings these are (copied from
/// another profile from here), and its tabs.
private struct ProfileEditorBar: View {
    let model: LauncherModel
    let tab: SettingsTab

    var body: some View {
        let profile = model.currentProfile
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { model.settingsTab = .profiles } label: {
                    Label(String(localized: "布局方案"), systemImage: "chevron.left").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help(String(localized: "返回方案列表"))
                Divider().frame(height: 14)
                Image(systemName: model.profileMode(profile).symbol).font(.system(size: 12)).foregroundStyle(Color.accentColor)
                Text(verbatim: model.profileLabel(profile)).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .help(String(localized: "这些设置只属于这个方案，切换方案时一起切换。"))
                Spacer(minLength: 8)
                if let group = tab.group {
                    CopySettingsMenu(model: model, group: group).controlSize(.small)
                }
            }
            HStack(spacing: 2) {
                ForEach(SettingsTab.profileTabs) { item in
                    TabButton(tab: item, selected: tab == item) { model.settingsTab = item }
                }
            }
        }
    }
}

private struct TabButton: View {
    let tab: SettingsTab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tab.symbol).font(.system(size: 17))
                    .frame(height: 21)
                Text(tab.title).font(.system(size: 12)).lineLimit(1).fixedSize()
            }
            .overlay(alignment: .topTrailing) {
                if tab == .feedback, Feedback.shared.unread > 0 {
                    Text(verbatim: "\(Feedback.shared.unread)")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                        .background(Color.red, in: Capsule())
                        .offset(x: 10, y: -4)
                }
            }
            .foregroundStyle(selected ? Color.accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(selected ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Takes another profile's settings in this group once; afterwards each changes on its own.
private struct CopySettingsMenu: View {
    let model: LauncherModel
    let group: ProfileSettings.Group

    var body: some View {
        let others = model.profileNames.filter { $0 != model.currentProfile }
        Menu {
            Section(String(localized: "用另一套方案的「\(group.title)」设置替换这里的")) {
                ForEach(others, id: \.self) { name in
                    Button(model.profileLabel(name)) { model.copySettings(group, from: name) }
                }
            }
        } label: {
            Text("从其他方案复制…").font(.system(size: 12))
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(others.isEmpty)
        .help(others.isEmpty ? String(localized: "新建第二套方案后，可以从它复制这些设置") : "")
    }
}
