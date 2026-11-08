import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    // The list of layout profiles; the one being edited's settings; LaunchUS's own (what it
    // has only one of).
    case profiles
    case display, appearance, organize, general, behavior, hidden, apps, ai, manage
    case advanced
    var id: String { rawValue }

    static let profileTabs: [SettingsTab] = [.display, .appearance, .organize, .general, .behavior, .apps, .hidden, .ai, .manage]
    /// The pages along the top; a profile's tabs are under 布局方案.
    static let topTabs: [SettingsTab] = [.profiles, .advanced]

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
        case .ai: "AI"
        case .manage: String(localized: "方案（设置页）", defaultValue: "方案")
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

/// The launcher floats above modal windows; drop it below them while an alert or file panel is up.
@MainActor
enum Modal {
    static func run<T>(_ body: () -> T) -> T {
        let panels = NSApp.windows.filter { $0 is LauncherPanel && $0.isVisible }
        let levels = panels.map(\.level)
        panels.forEach { $0.level = .normal }
        defer { zip(panels, levels).forEach { $0.level = $1 } }
        return body()
    }
}

// MARK: - Root

/// The settings card shown over the launcher (right-click on empty space › 设置…). Two pages
/// at the top: 布局方案 lists the profiles, and 编辑 on one opens its own settings; 高级 holds
/// LaunchUS's own.
struct SettingsView: View {
    @Bindable var model: LauncherModel
    @Bindable var settings: Settings
    let actions: SettingsActions
    var height: CGFloat = 700

    var body: some View {
        let profile = model.currentProfile
        let tab = model.settingsTab
        VStack(spacing: 0) {
            if tab.isProfileTab {
                // Editing one profile: back to the list, its name, and its tabs.
                ProfileEditorBar(model: model, tab: tab)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .padding(.leading, 40)
                    .padding(.trailing, 16)
            } else {
                HStack(spacing: 2) {
                    TabButton(tab: .profiles, selected: tab == .profiles) { model.settingsTab = .profiles }
                    TabButton(tab: .advanced, selected: tab == .advanced) { model.settingsTab = .advanced }
                }
                .frame(width: 200)
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
        .frame(width: 600, height: height)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topLeading) {
            Button { model.closeSettings() } label: {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                    .overlay(Circle().strokeBorder(.black.opacity(0.12)))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
    }
}

/// 布局方案: every profile with what sets it apart; 编辑 opens its settings.
private struct ProfilesTab: View {
    let model: LauncherModel

    var body: some View {
        SettingsSection(title: String(localized: "布局方案")) {
            Text("每个方案有自己的页面、文件夹、隐藏的 App 和设置。点「编辑」进入它的设置。")
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
        }
    }
}

private struct ProfileRow: View {
    let model: LauncherModel
    let name: String

    var body: some View {
        let current = name == model.currentProfile
        let mode = model.profileMode(name)
        HStack(spacing: 12) {
            Image(nsImage: IconArt.image(model.appIcon(of: name), size: 64))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(LayoutProfiles.title(name)).font(.system(size: 13, weight: .medium))
                    if current {
                        Text("正在使用").font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                }
                Text(verbatim: details(mode: mode)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !current {
                Button(String(localized: "使用")) { model.switchProfile(name, reopen: false) }
                    .help(String(localized: "切换到这个方案"))
            }
            Button(String(localized: "编辑")) {
                model.switchProfile(name, reopen: false)
                model.settingsTab = .display
            }
            .keyboardShortcut(current ? .defaultAction : nil)
            Menu {
                Button(String(localized: "重命名…")) {
                    model.closeSettings()
                    model.sheet = .renameProfile(name)
                }
                Button(String(localized: "删除方案…"), role: .destructive) { confirmDelete() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button).menuIndicator(.hidden).fixedSize()
            .disabled(name.isEmpty)
            .help(name.isEmpty ? String(localized: "默认方案不能重命名或删除") : "")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

// MARK: - Building blocks

/// Why a row is greyed out: it only does something in another mode.
enum ModeNote {
    static var paged: String { String(localized: "仅在分页浏览时可用") }
    static var scroll: String { String(localized: "仅在滚动浏览时可用") }
    static var fullScreen: String { String(localized: "仅在全屏模式下可用") }
}

struct SettingsSection<Content: View>: View {
    var title: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.system(size: 14, weight: .semibold)).padding(.leading, 4)
            }
            content()
        }
    }
}

/// A rounded group of rows with hairlines between them.
struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content()) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                    if index > 0, !subview.containerValues.joinsRowAbove { Divider().padding(.horizontal, 14) }
                    subview
                }
            }
        }
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension ContainerValues {
    /// Belongs to the row above, so a card draws no hairline between them.
    @Entry var joinsRowAbove = false
}

/// A problem with the row above: why, and a button to fix it in System Settings.
struct SettingWarning: View {
    let text: String
    var openSettings: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let openSettings {
                Button(String(localized: "打开系统设置"), action: openSettings)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, -4)
        .padding(.bottom, 10)
        .containerValue(\.joinsRowAbove, true)
    }
}

struct Row<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var info: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 13))
                    if let info { InfoButton(text: info) }
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
    }
}

/// ⓘ after a setting's name: click for the explanation. Tooltips alone don't show
/// in the launcher's panel, which never becomes the key window.
struct InfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text).font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
    }
}

struct MenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.self) { Text(title($0)).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }
}

// MARK: - 通用

struct GeneralTab: View {
    let model: LauncherModel
    @Bindable var settings: Settings
    @State private var trusted = Permissions.accessibility
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsSection(title: String(localized: "打开这个方案")) {
            Card {
                Row(title: String(localized: "快捷键")) {
                    HotKeyRecorder(spec: $settings.hotKey)
                }
                if let spec = settings.hotKey, let conflict = model.shortcutConflict(spec, owner: nil) {
                    let fix: (() -> Void)? = ShortcutConflicts.isSystem(spec) ? { ShortcutConflicts.openSettings() } : nil
                    SettingWarning(text: conflict, openSettings: fix)
                }
                Row(title: String(localized: "系统 F4 键"), info: String(localized: "用键盘上的 F4 键打开这个方案（新款键盘上是「聚焦」键，打开后它不再打开聚焦）")) {
                    if trusted {
                        Toggle("", isOn: $settings.f4Key).toggleStyle(.switch).labelsHidden()
                    } else {
                        Button(String(localized: "授予权限")) { PermissionHelper.shared.request(.accessibility) }
                    }
                }
                if settings.f4Key, let other = model.otherProfile(opening: { $0.f4 }) {
                    SettingWarning(text: String(localized: "方案「\(LayoutProfiles.title(other))」也用 F4 键，只有一个会打开。"))
                }
                Row(title: String(localized: "触控板"), info: String(localized: "捏合打开，张开关闭，界面跟随手指；松手时过半就完成，否则退回。")) {
                    Toggle("", isOn: $settings.trackpadPinch).toggleStyle(.switch).labelsHidden()
                }
                if settings.trackpadPinch {
                    Row(title: String(localized: "捏合手指数"), info: String(localized: "包括拇指")) {
                        MenuPicker(selection: $settings.pinchFingers, options: [3, 4, 5, TrackpadPinch.fourOrFive]) {
                            $0 == TrackpadPinch.fourOrFive ? String(localized: "4 指或 5 指")
                                : String(format: String(localized: "%lld 指"), $0)
                        }
                    }
                    let mine = TrackpadPinch.fingerCounts(for: settings.pinchFingers)
                    if let other = model.otherProfile(opening: { !$0.fingers.isDisjoint(with: mine) }) {
                        SettingWarning(text: String(localized: "方案「\(LayoutProfiles.title(other))」也用这个手指数，只有一个会打开。"))
                    }
                    let pinchConflicts = SystemPinch.conflicts(fingers: settings.pinchFingers)
                    if !pinchConflicts.isEmpty {
                        SettingWarning(text: pinchConflicts.joined(separator: "\n") + "\n" + String(localized: "可以在「系统设置 › 触控板 › 更多手势」里关掉，或改用 3 指。"),
                                       openSettings: { SystemPinch.openSettings() })
                    }
                }
                Row(title: String(localized: "触发角"), info: String(localized: "把指针推到屏幕角落时打开或关闭。多台显示器时，只有不与其他显示器相邻的角落会响应。")) {
                    MenuPicker(selection: $settings.hotCorner, options: HotCorner.allCases, title: \.title)
                }
                if settings.hotCorner != .off, let other = model.otherProfile(opening: { $0.corner == settings.hotCorner }) {
                    SettingWarning(text: String(localized: "方案「\(LayoutProfiles.title(other))」也用这个角落，只有一个会打开。"))
                }
                if SystemHotCorners.isTaken(settings.hotCorner) {
                    SettingWarning(text: String(localized: "这个角落已设置了系统的触发角，两者会同时触发。"),
                                   openSettings: { SystemHotCorners.openSettings() })
                }
            }
            Text(model.profileNames.count > 1
                 ? String(localized: "这些打开「\(model.profileLabel(model.currentProfile))」。每套方案可以有自己的快捷键、手势和触发角，用哪个就打开哪套方案。")
                 : String(localized: "新建方案后，每套方案可以有自己的快捷键、手势和触发角，用哪个就打开哪套方案。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        MenuBarDockSection(model: model, settings: settings)
        StartupSection(model: model, settings: settings)
        .onReceive(poll) { _ in
            trusted = Permissions.accessibility
        }
    }
}

/// How the profile behaves once it's open: going back home, closing, editing and searching.
struct BehaviorTab: View {
    let model: LauncherModel
    @Bindable var settings: Settings

    var body: some View {
        SettingsSection(title: String(localized: "行为")) {
            Card {
                Row(title: String(localized: "回到主页面"), info: settings.browseStyle == .scroll
                        ? String(localized: "再次打开时，隔多久回到最上面；在这之前会停在上次浏览的位置")
                        : String(localized: "再次打开时，隔多久回到第一页；在这之前会停在上次浏览的位置")) {
                    MenuPicker(selection: $settings.returnHome, options: ReturnHome.allCases, title: \.title)
                }
                Row(title: String(localized: "点击空白区域关闭")) {
                    Toggle("", isOn: $settings.clickBackgroundToClose).toggleStyle(.switch).labelsHidden()
                }
            }
        }
        SettingsSection(title: String(localized: "编辑")) {
            Card {
                Row(title: String(localized: "多选"), info: String(localized: "按住所选按键点按 App 可多选，之后可一起拖进文件夹、新建文件夹、加标签或隐藏")) {
                    MenuPicker(selection: $settings.multiSelectKey, options: MultiSelectKey.allCases, title: \.title)
                }
                Row(title: String(localized: "卸载 App"), info: String(localized: "抖动模式（长按或按住 ⌥）下，可删除的 App 左上角显示 ✕")) {
                    MenuPicker(selection: $settings.deleteBadges, options: [true, false]) { $0 ? String(localized: "抖动时显示 ✕") : String(localized: "关") }
                }
            }
            Text(settings.displayMode == .window
                 ? String(localized: "把图标拖出窗口，即可放到程序坞、访达或其他 App")
                 : String(localized: "拖动图标到屏幕底边，即可放到程序坞、访达或其他 App"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        // What's offered when a search finds no app.
        SettingsSection(title: String(localized: "搜索")) {
            Card {
                Row(title: String(localized: "网页搜索"), info: String(localized: "搜索没有结果时，按 ↩ 用它搜索（配置了 AI 时改为 ⇥，↩ 问 AI）；按 ⌘↩ 在访达中搜索")) {
                    MenuPicker(selection: $settings.searchEngine, options: SearchEngine.allCases, title: \.title)
                }
                Row(title: String(localized: "搜索文件"), info: String(localized: "没有找到 App 时，列出聚焦找到的文件和文件夹")) {
                    Toggle("", isOn: $settings.searchFiles).toggleStyle(.switch).labelsHidden()
                }
                Row(title: String(localized: "AI 聊天"),
                    subtitle: AIClient.isConfigured ? settings.aiModel : String(localized: "未配置")) {
                    Button(String(localized: "设置…")) { model.settingsTab = .ai }
                }
            }
        }
    }
}

/// Click, then press the new shortcut. Esc cancels; Delete restores ⌥Space.
struct HotKeyRecorder: View {
    @Binding var spec: HotKeySpec?

    var body: some View {
        HStack(spacing: 6) {
            ShortcutRecorder(display: spec?.display, placeholder: String(localized: "未设置"), width: 160,
                             clear: { spec = nil }, record: { spec = $0 })
            Button(String(localized: "清除")) { spec = nil }
                .disabled(spec == nil)
        }
    }
}

/// Click, then press a shortcut. Esc cancels; Delete calls `clear`. Every global shortcut, the
/// system's included, is paused meanwhile, so pressing one that's in use records it instead of
/// firing it (⌘Space would otherwise open Spotlight behind the launcher).
struct ShortcutRecorder: View {
    /// The current shortcut; nil shows `placeholder`.
    let display: String?
    var placeholder = ""
    var width: CGFloat = 200
    /// The soft well of the app editor's form instead of a control box.
    var soft = false
    let clear: () -> Void
    let record: (HotKeySpec) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? String(localized: "请按下快捷键…") : display ?? placeholder)
                .font(.system(size: 13))
                .foregroundStyle(recording ? Color.accentColor : display == nil ? .secondary : .primary)
                .frame(width: width, height: soft ? 24 : 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(soft ? Color.primary.opacity(0.06) : Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(recording ? Color.accentColor : Color.primary.opacity(soft ? 0.08 : 0.15)))
        }
        .buttonStyle(.plain)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        HotKeyCenter.paused = true
        HotKeyGroup.all.forEach { $0.paused = true }
        SystemHotKeys.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = Int(event.keyCode)
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if code == kVK_Escape_ { stop(); return nil }
            if code == 51 && flags.isEmpty { clear(); stop(); return nil }
            // Plain letters would fire while typing elsewhere; require a modifier except for F-keys.
            let isFunctionKey = HotKeyFormat.functionKeys[code] != nil
            guard !flags.isEmpty || isFunctionKey else { NSSound.beep(); return nil }
            record(HotKeySpec(keyCode: code, modifiers: HotKeyFormat.carbon(flags),
                              display: HotKeyFormat.display(flags: flags, keyCode: code, characters: event.charactersIgnoringModifiers)))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        HotKeyCenter.paused = false
        HotKeyGroup.all.forEach { $0.paused = false }
        SystemHotKeys.paused = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private let kVK_Escape_ = 53

// MARK: - 布局方案

/// Layout profiles, each shown one way — full screen or window — with its own grid, browsing,
/// sizes and pages. Only the settings the current profile's way of showing uses are listed.
/// A new way of showing the launcher would be one more `DisplayMode`.
struct DisplayTab: View {
    let model: LauncherModel
    @Bindable var settings: Settings

    var body: some View {
        let full = settings.displayMode == .fullScreen
        SettingsSection(title: String(localized: "布局")) {
            Card {
                Row(title: String(localized: "显示方式"),
                    info: String(localized: "全屏：铺满屏幕，像原来的启动台。窗口：浮在桌面上，像一个 App 窗口")) {
                    Picker("", selection: $settings.displayMode) {
                        ForEach(DisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Row(title: String(localized: "显示在")) {
                    MenuPicker(selection: $settings.targetScreen, options: TargetScreen.allCases, title: \.title)
                }
                if full {
                    Row(title: String(localized: "隐藏程序坞"),
                        info: String(localized: "全屏时盖住程序坞和菜单栏；关掉则让程序坞留在最上面")) {
                        Toggle("", isOn: $settings.hideDock).toggleStyle(.switch).labelsHidden()
                    }
                } else {
                    Row(title: String(localized: "窗口大小"), subtitle: percent(settings.windowSize)) {
                        SizeSlider(value: $settings.windowSize, range: Settings.windowSizeRange, symbol: "macwindow")
                    }
                }
                Row(title: String(localized: "图标大小"), subtitle: percent(settings.iconScale)) {
                    SizeSlider(value: $settings.iconScale, range: 0.6...1.3, symbol: "app")
                }
                Row(title: String(localized: "网格布局"), subtitle: String(localized: "列 × 行")) {
                    HStack(spacing: 8) {
                        NumberStepper(value: $settings.columns, range: 4...10)
                        Text("×").foregroundStyle(.secondary)
                        NumberStepper(value: $settings.rows, range: 3...8)
                    }
                }
                Row(title: String(localized: "隐藏名称")) {
                    HStack(spacing: 14) {
                        Toggle("App", isOn: $settings.hideNames)
                        Toggle(String(localized: "文件夹"), isOn: $settings.hideFolderNames)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        if settings.displayMode == .fullScreen {
            SettingsSection(title: String(localized: "背景")) {
                Card {
                    Row(title: String(localized: "类型")) {
                        Picker("", selection: $settings.background) {
                            Text("系统壁纸").tag(BackgroundKind.wallpaper)
                            Text("毛玻璃").tag(BackgroundKind.glass)
                            Text("图片").tag(BackgroundKind.image)
                        }
                        .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().fixedSize()
                    }
                    if settings.background == .image {
                        Row(title: String(localized: "图片"), subtitle: BackgroundImage.url(settings.backgroundImage) == nil
                                ? String(localized: "还没有选择，暂时使用系统壁纸") : nil) {
                            Button(String(localized: "选择图片…"), action: chooseBackground)
                        }
                    }
                    Row(title: String(localized: "效果"),
                        info: String(localized: "模糊、颜色、色温、色调、暗角和颗粒感。选一个样式，或点「调整…」边看边调，调好的可以存成自己的样式")) {
                        HStack(spacing: 8) {
                            BackgroundStylePicker(settings: settings)
                            Button(String(localized: "调整…")) { model.openTuner(.background) }
                        }
                    }
                }
            }
        }
        SettingsSection(title: String(localized: "浏览")) {
            Card {
                Row(title: String(localized: "浏览样式"), info: String(localized: "分页：左右翻页，可以留出空位。滚动：所有页面连成一列上下滚动，顶部可以显示最近一行")) {
                    Picker("", selection: $settings.browseStyle) {
                        Text("分页").tag(BrowseStyle.paged)
                        Text("滚动").tag(BrowseStyle.scroll)
                    }
                    .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().fixedSize()
                }
                Row(title: String(localized: "最近一行"),
                    subtitle: settings.browseStyle == .paged ? ModeNote.scroll : nil,
                    info: String(localized: "滚动浏览时，在最上面一行显示最近打开的 App，下面用一条线隔开")) {
                    Toggle("", isOn: Binding(get: { settings.showFrequent && settings.browseStyle == .scroll },
                                             set: { settings.showFrequent = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                        .disabled(settings.browseStyle == .paged)
                }
                Row(title: String(localized: "文件夹内浏览"), info: String(localized: "文件夹里的 App 超过一屏时，分页左右翻，滚动上下滑")) {
                    Picker("", selection: $settings.folderBrowseStyle) {
                        Text("分页").tag(BrowseStyle.paged)
                        Text("滚动").tag(BrowseStyle.scroll)
                    }
                    .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().fixedSize()
                }
                Row(title: String(localized: "智能栏"),
                    info: String(localized: "搜索框下面的一排智能文件夹，点一个只看里面的 App。可以把 App Store 分类导入成智能文件夹，新装的 App 会自动归进去")) {
                    HStack(spacing: 8) {
                        SmartBarButton(model: model)
                        Toggle("", isOn: $settings.showCategoryBar).toggleStyle(.switch).labelsHidden()
                    }
                }
            }
        }
    }

    /// Shown only when it isn't the standard size.
    private func percent(_ value: Double) -> String? {
        value == 1 ? nil : "\(Int((value * 100).rounded()))%"
    }
}

/// A size slider between a small and a big symbol, with a reset to 100%.
private struct SizeSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 20)
            Slider(value: $value, in: range, step: 0.05).frame(width: 150)
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 20)
            Button(String(localized: "还原")) { value = 1 }
                .disabled(value == 1)
                .fixedSize()
        }
    }
}

/// Choosing how a profile is shown: a picture, a name and a line about it.
struct DisplayModeCard: View {
    let mode: DisplayMode
    let selected: Bool
    var thumbHeight: CGFloat = 100
    var compact = false
    let select: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button(action: select) {
            VStack(alignment: .leading, spacing: compact ? 7 : 10) {
                ModeThumb(windowed: mode == .window)
                    .frame(maxWidth: .infinity)
                    .frame(height: thumbHeight)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title).font(.system(size: 13, weight: .semibold))
                    Text(mode == .fullScreen ? String(localized: "铺满屏幕，像原来的启动台") : String(localized: "浮在桌面上，像一个 App 窗口"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 2)
            }
            .padding(compact ? 9 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(selected ? 0.07 : 0.035), in: shape)
            .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Little picture of full-screen vs window mode, drawn for a 100-point height and scaled.
struct ModeThumb: View {
    let windowed: Bool

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.height / 100
            ZStack {
                LinearGradient(colors: [Color(red: 0.25, green: 0.4, blue: 0.75), Color(red: 0.6, green: 0.7, blue: 0.9)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if windowed {
                    RoundedRectangle(cornerRadius: 7 * k, style: .continuous).fill(.white.opacity(0.78))
                        .frame(width: 120 * k, height: 72 * k)
                        .shadow(color: .black.opacity(0.2), radius: 6 * k, y: 3 * k)
                }
                let dot = windowed ? Color.gray.opacity(0.4) : Color.white.opacity(0.85)
                VStack(spacing: (windowed ? 6 : 9) * k) {
                    ForEach(0..<3, id: \.self) { _ in
                        HStack(spacing: (windowed ? 6 : 10) * k) {
                            ForEach(0..<(windowed ? 6 : 7), id: \.self) { _ in
                                RoundedRectangle(cornerRadius: (windowed ? 2 : 3) * k, style: .continuous).fill(dot)
                                    .frame(width: (windowed ? 10 : 14) * k, height: (windowed ? 10 : 14) * k)
                            }
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - 外观

struct AppearanceTab: View {
    let model: LauncherModel
    @Bindable var settings: Settings

    var body: some View {
        SettingsSection(title: String(localized: "界面")) {
            Card {
                Row(title: String(localized: "外观"), info: String(localized: "设置、菜单和窗口模式用浅色或深色；选「自动」时随 Mac 切换")) {
                    Picker("", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Row(title: String(localized: "液态玻璃"), info: String(localized: "文件夹、打开的文件夹和搜索栏透出并折射后面的内容；关掉则用烟灰玻璃")) {
                    Toggle("", isOn: $settings.liquidGlass).toggleStyle(.switch).labelsHidden()
                }
                Row(title: String(localized: "动画"),
                    subtitle: settings.animationsOff ? String(localized: "已关闭") : nil,
                    info: String(localized: "打开、关闭、翻页和文件夹的过渡快慢节奏。选一种预设，或点「调整…」拖动曲线、调速度，也可以关闭动画")) {
                    HStack(spacing: 8) {
                        MotionCurvePicker(curve: $settings.motionCurve)
                            .disabled(settings.animationsOff)
                        Button(String(localized: "调整…")) { model.openTuner(.motion) }
                    }
                }
            }
        }
        SettingsSection(title: String(localized: "图标")) {
            Card {
                Row(title: String(localized: "深色图标"), info: String(localized: "使用 App 自带的深色图标，就像深色模式下的程序坞；没有深色版本的 App 保持原样")) {
                    MenuPicker(selection: $settings.darkIcons, options: DarkIconMode.allCases, title: \.title)
                }
                Row(title: String(localized: "悬停浮起"), info: String(localized: "鼠标移到图标上时，图标轻轻浮起，和右键时一样")) {
                    Toggle("", isOn: $settings.hoverLift).toggleStyle(.switch).labelsHidden()
                }
            }
        }
        SettingsSection(title: String(localized: "图标标记")) {
            Card {
                mark("新 App 标记", $settings.showNewDot, "新安装的 App 图标下方亮起蓝色灯带，打开一次后熄灭")
                mark("运行指示", $settings.showRunningDot, "正在运行的 App 图标下方亮起白色灯带")
                mark("通知角标", $settings.showBadges, Permissions.accessibility
                     ? "显示程序坞上 App 的未读数" : "显示程序坞上 App 的未读数，需要辅助功能权限")
                mark("动态日历图标", $settings.dynamicCalendar, "「日历」的图标显示今天的日期")
                mark("淡化久未打开的 App", $settings.fadeStale, "超过 3 个月没打开的 App 图标变淡")
            }
        }
    }

    /// One mark on the icons, switched on or off, with an ⓘ for what it does.
    private func mark(_ title: String.LocalizationValue, _ isOn: Binding<Bool>, _ help: String.LocalizationValue) -> some View {
        Row(title: String(localized: title), info: String(localized: help)) {
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}

struct NumberStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 2) {
            Text("\(value)").font(.system(size: 13).monospacedDigit()).frame(width: 26)
            Stepper("", value: $value, in: range).labelsHidden()
        }
        .padding(.leading, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
    }
}


// MARK: - Apps

struct AppsTab: View {
    let model: LauncherModel
    @Bindable var settings: Settings
    let actions: SettingsActions
    @State private var selectedFolder: String?

    @State private var rescanning = false
    @State private var rescanMessage: String?
    var body: some View {
        SettingsSection(title: String(localized: "App 来源")) {
            VStack(spacing: 0) {
                SourceRow(name: String(localized: "应用程序"), detail: String(localized: "默认路径：/Applications、/System/Applications、~/Applications"),
                          selected: false) {}
                ForEach(settings.extraAppFolders, id: \.self) { path in
                    Divider().padding(.horizontal, 14)
                    SourceRow(name: (path as NSString).lastPathComponent, detail: path,
                              selected: selectedFolder == path) { selectedFolder = path }
                }
                Divider()
                HStack(spacing: 0) {
                    Button { addFolder() } label: { Image(systemName: "plus").frame(width: 32, height: 26) }
                    Divider().frame(height: 16)
                    Button {
                        settings.extraAppFolders.removeAll { $0 == selectedFolder }
                        selectedFolder = nil
                    } label: { Image(systemName: "minus").frame(width: 32, height: 26) }
                    .disabled(selectedFolder == nil)
                    Spacer()
                    if let rescanMessage {
                        Text(rescanMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .padding(.trailing, 8)
                            .transition(.opacity)
                    }
                    Button(rescanning ? String(localized: "正在扫描…") : String(localized: "重新扫描")) {
                        rescanning = true
                        rescanMessage = nil
                        actions.rescan { result in
                            rescanning = false
                            withAnimation { rescanMessage = result.message }
                        }
                    }
                    .disabled(rescanning)
                    .controlSize(.small).padding(.trailing, 10)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.03))
            }
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        SettingsSection(title: String(localized: "管理")) {
            Card {
                Row(title: String(localized: "App 管理"), info: String(localized: "按大小查看所有 App，找出 Intel App、有更新的和很久没打开的，直接卸载；还有使用统计")) {
                    Button(String(localized: "打开…")) {
                        model.closeSettings()
                        model.sheet = .manager
                    }
                }
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "添加")
        panel.message = String(localized: "选择包含 App 的文件夹")
        guard Modal.run({ panel.runModal() }) == .OK else { return }
        let defaults = ["/Applications", "/System/Applications",
                        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for url in panel.urls where !defaults.contains(url.path) && !settings.extraAppFolders.contains(url.path) {
            settings.extraAppFolders.append(url.path)
        }
    }
}

// MARK: - 隐藏

/// The profile's hidden apps and how they're reached.
struct HiddenAppsTab: View {
    let model: LauncherModel
    @Bindable var settings: Settings

    var body: some View {
        SettingsSection(title: String(localized: "隐藏的 App")) {
            let hidden = model.hiddenApps
            if model.hiddenGuarded {
                VStack(spacing: 10) {
                    Image(systemName: "lock").font(.system(size: 22)).foregroundStyle(.secondary)
                    Text("\(hidden.count) 个隐藏的 App").font(.system(size: 13, weight: .medium))
                    Text("入口、暗号和验证方式都已锁定").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button(String(localized: "验证后修改")) { model.whenHiddenUnlocked() }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Card {
                    let scrolling = settings.browseStyle == .scroll
                    Row(title: String(localized: "隐形圆点"), subtitle: scrolling ? ModeNote.paged : String(localized: "最后一个分页圆点后面，鼠标移上去才会出现")) {
                        Toggle("", isOn: $settings.hiddenDotEntrance).toggleStyle(.switch).labelsHidden()
                            .disabled(scrolling)
                    }
                    Row(title: String(localized: "隐形空位"), subtitle: scrolling
                            ? String(localized: "在最后一个 App 后面的空位上右键，点击出现的虚线框")
                            : String(localized: "在所选页最后一个 App 后面的空位上右键，点击出现的虚线框")) {
                        HStack(spacing: 8) {
                            if !scrolling {
                                Picker("", selection: $settings.hiddenSlotPage) {
                                    Text("最后一页").tag(0)
                                    ForEach(1...max(1, model.pageCount), id: \.self) { Text("第 \($0) 页").tag($0) }
                                }
                                .labelsHidden().fixedSize()
                                .disabled(!settings.hiddenSlotEntrance)
                            }
                            Toggle("", isOn: $settings.hiddenSlotEntrance).toggleStyle(.switch).labelsHidden()
                        }
                    }
                    Row(title: String(localized: "暗号"), subtitle: String(localized: "在搜索框输入暗号即可打开，留空则关闭")) {
                        SecureField(String(localized: "未设置"), text: $settings.hiddenPhrase)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                    }
                }
                Card {
                    Row(title: String(localized: "打开前验证"), subtitle: String(localized: "使用触控 ID 或登录密码")) {
                        Toggle("", isOn: $settings.hiddenRequireAuth).toggleStyle(.switch).labelsHidden()
                    }
                    Row(title: String(localized: "关闭后重新隐藏"), subtitle: String(localized: "关闭时，下次需要重新通过入口打开")) {
                        Toggle("", isOn: $settings.hiddenRelock).toggleStyle(.switch).labelsHidden()
                    }
                }
                if hidden.isEmpty {
                    VStack(spacing: 6) {
                        Text("没有隐藏的 App").font(.system(size: 15, weight: .medium))
                        Text("右键点按 App 即可隐藏").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Card {
                        ForEach(hidden) { app in
                            HStack(spacing: 10) {
                                if let icon = model.catalog.icons[app.id] {
                                    Image(decorative: icon, scale: 2).resizable().frame(width: 28, height: 28)
                                } else {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 28, height: 28)
                                }
                                Text(app.name).font(.system(size: 13))
                                Spacer()
                                Button(String(localized: "取消隐藏")) { model.setHidden(false, for: app.id) }.controlSize(.small)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                    }
                }
            }
        }
    }
}

private struct SourceRow: View {
    let name: String
    let detail: String
    let selected: Bool
    let select: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

// MARK: - 整理

struct OrganizeTab: View {
    let model: LauncherModel
    @Bindable var settings: Settings
    @State private var showRules = false
    @State private var rules = LayoutRules()

    var body: some View {
        SettingsSection(title: String(localized: "排列")) {
            Card {
                Row(title: String(localized: "排序方式"), info: String(localized: "按名称或时间排序时，App 位置由排序决定，不能拖动整理；文件夹内仍保持原样")) {
                    MenuPicker(selection: $settings.sortOrder, options: SortOrder.allCases, title: \.title)
                }
                Row(title: String(localized: "图标摆放"),
                    subtitle: settings.browseStyle == .scroll ? ModeNote.paged
                        : settings.sortOrder != .custom ? String(localized: "按自定义排序时生效") : nil,
                    info: String(localized: "随处摆放：图标落在松手处的格子里，可以留出空位；调整行列数时，图标保持原来的行和列。依次排列：图标一个挨一个，空位自动补上")) {
                    Picker("", selection: $settings.freePlacement) {
                        Text("依次排列").tag(false)
                        Text("随处摆放").tag(true)
                    }
                    .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().fixedSize()
                    .disabled(settings.browseStyle == .scroll)
                }
            }
        }
        SettingsSection(title: String(localized: "一键整理")) {
            Card {
                Row(title: String(localized: "整理空位"), subtitle: settings.browseStyle == .scroll ? ModeNote.paged : nil,
                    info: String(localized: "按当前行列，把 App 向前移动，填满前面页面的空位。")) {
                    Button(String(localized: "重新整理")) { model.compactLayout() }
                        .disabled(settings.browseStyle == .scroll)
                }
                Row(title: String(localized: "整理布局"), info: String(localized: "按所选规则重新整理所有页面")) {
                    HStack {
                        Button {
                            confirmAlert(String(localized: "恢复默认布局？"), String(localized: "所有文件夹会被解散，App 按名称重新排列。建议先导出备份。"), button: String(localized: "恢复")) {
                                model.resetLayout()
                            }
                        } label: { Text("恢复默认布局").foregroundStyle(.red) }
                        Button(String(localized: "自定义规则")) { showRules = true }
                    }
                }
                Row(title: String(localized: "从系统启动台导入"), info: String(localized: "用 macOS 15 及更早版本启动台里的页面和文件夹替换这个方案的布局")) {
                    Button(String(localized: "导入…")) { Self.importLaunchpad(into: model) }
                }
                Row(title: String(localized: "久未打开的 App"), info: String(localized: "选中超过 3 个月没打开的 App，再统一移进文件夹或隐藏")) {
                    Button(String(localized: "全部选中")) { model.selectStaleApps() }
                }
            }
        }
        Color.clear.frame(height: 0)
        .sheet(isPresented: $showRules) {
            RulesSheet(rules: $rules) {
                showRules = false
                model.applyRules(rules)
            } cancel: { showRules = false }
        }
    }
}

@MainActor
func confirmAlert(_ title: String, _ text: String, button: String, action: @escaping () -> Void) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: String(localized: "取消"))
    if Modal.run({ alert.runModal() }) == .alertFirstButtonReturn { action() }
}

@MainActor
func failAlert(_ title: String, _ error: Error) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = error.localizedDescription
    Modal.run { _ = alert.runModal() }
}

/// 整理 › 一键整理 › 从系统启动台导入: replaces this profile's pages with the system Launchpad's.
extension OrganizeTab {
    @MainActor static func importLaunchpad(into model: LauncherModel) {
        let url: URL
        if let found = LaunchpadImport.systemDatabase {
            url = found
        } else {
            let alert = NSAlert()
            alert.messageText = String(localized: "这台 Mac 上没有启动台数据")
            alert.informativeText = String(localized: "macOS 26 已移除启动台。如果旧 Mac 或时间机器备份里还有，可以在旧 Mac 的「终端」里运行下面的命令，把数据库拷到桌面，再选择这个文件：\n\n\(LaunchpadImport.copyCommand)")
            alert.addButton(withTitle: String(localized: "选择文件…"))
            alert.addButton(withTitle: String(localized: "拷贝命令"))
            alert.addButton(withTitle: String(localized: "取消"))
            switch Modal.run({ alert.runModal() }) {
            case .alertFirstButtonReturn:
                let panel = NSOpenPanel()
                panel.message = String(localized: "选择启动台数据库文件（db 或 launchpad.db）")
                guard Modal.run({ panel.runModal() }) == .OK, let picked = panel.url else { return }
                url = picked
            case .alertSecondButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(LaunchpadImport.copyCommand, forType: .string)
                return
            default:
                return
            }
        }
        confirmAlert(String(localized: "导入启动台的布局？"), String(localized: "会用启动台的页面和文件夹替换这个方案的布局，名称、标签和隐藏设置保持不变。现在的布局会先自动备份。"), button: String(localized: "导入")) {
            do { try model.importLaunchpad(from: url) } catch { failAlert(String(localized: "导入失败"), error) }
        }
    }

}

// MARK: - 高级

struct AdvancedTab: View {
    let model: LauncherModel
    @Bindable var settings: Settings
    @State private var autoCheck = Updater.shared.automaticallyChecks
    @State private var checkInterval = Updater.shared.checkInterval
    @State private var autoInstall = Updater.shared.automaticallyInstalls
    @State private var exporting = false
    @State private var showSharing = false

    var body: some View {
        SettingsSection(title: String(localized: "关于")) {
            Card {
                Row(title: String(localized: "版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")"),
                    subtitle: String(localized: "经典启动台的重制版。全部功能免费。")) {
                    if Updater.shared.isConfigured {
                        Button(String(localized: "检查更新…")) { Updater.shared.checkForUpdates() }
                    }
                }
                if Updater.shared.isConfigured {
                    Row(title: String(localized: "自动检查更新")) {
                        HStack(spacing: 10) {
                            if autoCheck {
                                MenuPicker(selection: $checkInterval, options: Updater.intervals, title: Updater.intervalTitle)
                                    .onChange(of: checkInterval) { _, value in Updater.shared.checkInterval = value }
                            }
                            Toggle("", isOn: $autoCheck).toggleStyle(.switch).labelsHidden()
                                .onChange(of: autoCheck) { _, on in Updater.shared.automaticallyChecks = on }
                        }
                    }
                    Row(title: String(localized: "自动安装更新"),
                        subtitle: autoCheck ? nil : String(localized: "需要先打开自动检查更新"),
                        info: String(localized: "在后台下载新版本，下载好后自动关闭并重新启动 LaunchUS，完成更新")) {
                        Toggle("", isOn: Binding(get: { autoInstall && autoCheck }, set: { autoInstall = $0 }))
                            .toggleStyle(.switch).labelsHidden()
                            .disabled(!autoCheck)
                            .onChange(of: autoInstall) { _, on in Updater.shared.automaticallyInstalls = on }
                    }
                }
            }
        }
        BackupSection(model: model, settings: settings)
        MCPSection()  // one server for every profile
        SettingsSection(title: String(localized: "数据与隐私")) {
            Card {
                Row(title: String(localized: "数据文件夹"), info: String(localized: "布局、文件夹、启动项、自定义图标和备份都存在这里")) {
                    Button(String(localized: "在访达中显示")) { model.reveal(LayoutStore.directory.path) }
                }
                Row(title: String(localized: "和开发者分享匿名使用信息"), subtitle: SharingSheet.summary(settings)) {
                    Button(String(localized: "查看详情")) { showSharing = true }
                }
                .sheet(isPresented: $showSharing) {
                    SharingSheet(settings: settings) { showSharing = false }
                }
            }
        }
        SettingsSection(title: String(localized: "帮助")) {
            Card {
                Row(title: String(localized: "使用引导"), info: String(localized: "再看一遍首次打开时的介绍")) {
                    Button(String(localized: "打开")) {
                        model.closeSettings()
                        model.openGuide()
                    }
                }
                Row(title: String(localized: "诊断信息"),
                    info: String(localized: "反馈问题时附上这个文件。包含版本、设置和最近的日志，不含 App 列表和暗号")) {
                    Button(exporting ? String(localized: "正在收集…") : String(localized: "导出…")) { exportDiagnostics() }
                        .disabled(exporting)
                }
            }
        }
        SettingsSection(title: String(localized: "还原")) {
            Card {
                Row(title: String(localized: "还原所有设置和布局"),
                    subtitle: String(localized: "回到刚安装时的样子，LaunchUS 会重新启动")) {
                    Button { confirmFactoryReset() } label: { Text("还原…").foregroundStyle(.red) }
                }
            }
        }
    }

    private func confirmFactoryReset() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "还原所有设置和布局？")
        alert.informativeText = String(localized: "所有设置都会恢复默认，布局、文件夹、隐藏的 App、启动项、自定义图标、布局方案、自动备份和 AI 聊天记录都会清空。现在的数据文件夹会移到废纸篓，需要时可以从那里找回。")
        let reset = alert.addButton(withTitle: String(localized: "还原并重新启动"))
        reset.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "取消"))
        guard Modal.run({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        // It brings hidden apps back into the grid, so it needs the same verification as showing them.
        model.whenHiddenUnlocked(reason: String(localized: "还原所有设置和布局")) {
            do { try FactoryReset.run() } catch { failAlert(String(localized: "还原失败"), error) }
        }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = String(localized: "LaunchUS 诊断信息 \(stamp).txt")
        panel.allowedContentTypes = [.plainText]
        guard Modal.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        exporting = true
        Task {
            let text = await Diagnostics.report(model: model)
            exporting = false
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                model.reveal(url.path)
            } catch {
                let alert = NSAlert(error: error)
                Modal.run { _ = alert.runModal() }
            }
        }
    }

}

/// 高级 › 备份与迁移: iCloud sync and the backup file that carries every profile.
struct BackupSection: View {
    let model: LauncherModel
    @Bindable var settings: Settings
    @State private var exporting = false
    @State private var importing: ImportedFile?

    /// A backup file that was read, waiting for its profiles to be picked.
    struct ImportedFile: Identifiable {
        let id = UUID()
        let backup: LayoutBackup
    }

    var body: some View {
        SettingsSection(title: String(localized: "备份与迁移")) {
            Card {
                Row(title: String(localized: "iCloud 同步"), subtitle: iCloudSubtitle) {
                    Toggle("", isOn: $settings.iCloudSync).toggleStyle(.switch).labelsHidden()
                        .disabled(!ICloudSync.isAvailable && !settings.iCloudSync)
                }
                Row(title: String(localized: "导入或导出布局"), info: String(localized: "导出一个或几个方案的页面、文件夹、隐藏的 App 和设置，用于备份或在设备之间迁移；导入时选择要导入文件里的哪些方案")) {
                    HStack {
                        Button(String(localized: "导入…")) { importBackup() }
                        Button(String(localized: "导出…")) { exporting = true }
                    }
                }
            }
        }
        .sheet(isPresented: $exporting) {
            ExportProfilesSheet(model: model) { exporting = false }
        }
        .sheet(item: $importing) { file in
            ImportProfilesSheet(model: model, backup: file.backup) { importing = nil }
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard Modal.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        do {
            importing = ImportedFile(backup: try JSONDecoder().decode(LayoutBackup.self, from: Data(contentsOf: url)))
        } catch {
            failAlert(String(localized: "导入失败"), error)
        }
    }

    private var iCloudSubtitle: String {
        if !ICloudSync.isAvailable { return String(localized: "需要先在「系统设置 › Apple 账户 › iCloud」里打开 iCloud 云盘") }
        guard settings.iCloudSync else {
            return String(localized: "通过 iCloud 云盘让多台 Mac 的布局、文件夹和 App 设置保持一致。开启时如果 iCloud 里已有其他 Mac 的布局，会先采用它（当前布局会自动备份）")
        }
        guard let last = ICloudSync.lastSync else { return String(localized: "已开启，等待第一次同步") }
        return String(localized: "上次同步：\(last.formatted(date: .abbreviated, time: .shortened))")
    }

}

/// 方案 › 自动备份: the profile's own backups, one per change.
struct AutoBackupSection: View {
    let model: LauncherModel
    @Bindable var settings: Settings

    var body: some View {
        SettingsSection(title: String(localized: "自动备份")) {
            Card {
                Row(title: String(localized: "自动备份"), subtitle: settings.autoBackupCount > 0
                        ? String(localized: "每次更改这个方案的布局后自动备份，保留最近 \(settings.autoBackupCount) 份")
                        : String(localized: "已关闭")) {
                    Stepper(settings.autoBackupCount > 0 ? String(localized: "\(settings.autoBackupCount) 份") : String(localized: "关"),
                            value: $settings.autoBackupCount, in: 0...50)
                        .monospacedDigit()
                }
                Row(title: String(localized: "恢复自动备份"), info: String(localized: "把这个方案的页面和隐藏的 App 换回之前某次更改前的样子")) {
                    HStack {
                        let backups = AutoBackup.list()
                        Menu(String(localized: "选择…")) {
                            ForEach(backups) { entry in
                                Button(entry.date.formatted(date: .abbreviated, time: .standard)) { restore(entry) }
                            }
                        }
                        .fixedSize()
                        .disabled(backups.isEmpty)
                        Button {
                            model.reveal(AutoBackup.directory.path)
                        } label: { Image(systemName: "folder") }
                        .help(String(localized: "在访达中显示备份文件夹"))
                        .disabled(backups.isEmpty)
                    }
                }
            }
        }
    }

    private func restore(_ entry: AutoBackup.Entry) {
        let when = entry.date.formatted(date: .abbreviated, time: .standard)
        confirmAlert(String(localized: "恢复 \(when) 的布局？"), String(localized: "会替换这个方案的页面和隐藏的 App，其他方案不受影响。当前的也已自动备份，可以随时换回来。"), button: String(localized: "恢复")) {
            model.whenHiddenUnlocked(reason: String(localized: "恢复布局备份")) {
                AutoBackup.snapshot()
                do { try model.restoreProfileBackup(from: entry.url) } catch { failAlert(String(localized: "恢复失败"), error) }
            }
        }
    }
}

/// 打开 › 启动: whether this profile starts with the Mac.
struct StartupSection: View {
    let model: LauncherModel
    @Bindable var settings: Settings
    @State private var loginNeedsApproval = LoginItem.needsApproval
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let current = model.currentProfile
        let otherAtLogin = model.profileNames.first { $0 != current && model.startsAtLogin($0) }
        SettingsSection(title: String(localized: "启动")) {
            Card {
                Row(title: String(localized: "开机自启动"), subtitle: loginSubtitle(otherAtLogin),
                    info: String(localized: "登录 Mac 时启动 LaunchUS，并切换到这个方案")) {
                    Toggle("", isOn: $settings.startAtLogin).toggleStyle(.switch).labelsHidden()
                }
            }
        }
        .onReceive(poll) { _ in loginNeedsApproval = LoginItem.needsApproval }
    }

    private func loginSubtitle(_ other: String?) -> String? {
        if (settings.startAtLogin || other != nil) && loginNeedsApproval {
            return String(localized: "需要在「系统设置 › 通用 › 登录项」里允许")
        }
        if settings.startAtLogin, let other {
            return String(localized: "「\(LayoutProfiles.title(other))」也开机自启动，登录时打开的是排在前面的那个")
        }
        return nil
    }
}

/// 打开 › 菜单栏与程序坞: this profile's own menu bar icon and Dock icon.
struct MenuBarDockSection: View {
    let model: LauncherModel
    @Bindable var settings: Settings

    var body: some View {
        SettingsSection(title: String(localized: "菜单栏与程序坞")) {
            Card {
                Row(title: String(localized: "菜单栏图标"),
                    subtitle: model.profileNames.count > 1 && settings.showMenuBarIcon ? String(localized: "这个方案自己的图标，点按就打开这个方案") : nil,
                    info: settings.showMenuBarIcon ? String(localized: "点按菜单栏图标即可打开或关闭这个方案")
                        : String(localized: "隐藏后，可以用上面的快捷键、手势或触发角打开这个方案，再从 ⋯ 菜单进入设置")) {
                    HStack(spacing: 10) {
                        if settings.showMenuBarIcon {
                            HStack(spacing: 6) {
                                ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                                    let picked = settings.menuBarIcon == style
                                    Button { settings.menuBarIcon = style } label: {
                                        Image(systemName: style.rawValue)
                                            .font(.system(size: 14))
                                            .frame(width: 30, height: 26)
                                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(picked ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
                                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(picked ? Color.accentColor : .clear, lineWidth: 1.5))
                                            .foregroundStyle(picked ? Color.accentColor : .primary)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        Toggle("", isOn: $settings.showMenuBarIcon).toggleStyle(.switch).labelsHidden()
                    }
                }
                Row(title: String(localized: "程序坞图标"), info: String(localized: "这个方案在程序坞有自己的图标，开着的方案各一个；点按打开这个方案，右键可直接打开 App")) {
                    HStack(spacing: 10) {
                        if settings.showDockIcon {
                            MenuPicker(selection: $settings.dockMenu, options: DockMenuContent.allCases, title: \.title)
                                .help(String(localized: "程序坞菜单"))
                        }
                        Toggle("", isOn: $settings.showDockIcon).toggleStyle(.switch).labelsHidden()
                    }
                }
                Row(title: String(localized: "此方案图标"), info: String(localized: "这个方案在方案列表和程序坞里的图标；默认方案的就是 LaunchUS 自己的图标")) {
                    HStack(spacing: 12) {
                        ForEach(AppIconStyle.allCases, id: \.self) { style in
                            Button { settings.appIcon = style } label: {
                                VStack(spacing: 4) {
                                    Image(nsImage: IconArt.image(style, size: 128))
                                        .resizable().frame(width: 44, height: 44)
                                    Circle().fill(settings.appIcon == style ? Color.accentColor : .clear)
                                        .frame(width: 5, height: 5)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

/// What each kind of anonymous usage information is and what it's for, each with its own switch.
struct SharingSheet: View {
    @Bindable var settings: Settings
    let done: () -> Void

    static func summary(_ settings: Settings) -> String {
        let on = settings.shareUsage
            ? 1 + [settings.shareFeatures, settings.shareOpens].filter { $0 }.count : 0
        let count = on + (settings.shareCrashes ? 1 : 0)
        return switch count {
        case 4: String(localized: "4 项都已开启")
        case 0: String(localized: "都已关闭")
        default: String(localized: "已开启 4 项中的 \(count) 项")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("匿名使用信息").font(.system(size: 15, weight: .semibold))
            Text("LaunchUS 免费，没有账号也没有广告，我们不知道是谁在用它。这些匿名信息是我们了解 LaunchUS 用得好不好的唯一办法，用来决定先修什么、先做什么。每一项都可以单独关掉。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                item(String(localized: "每日活跃"), isOn: $settings.shareUsage,
                     sends: String(localized: "一个随机生成的安装编号、LaunchUS 版本、macOS 版本、芯片类型和系统语言，每天最多一次。"),
                     why: String(localized: "知道有多少台 Mac 在用、新版本有没有装上、还要不要支持旧版 macOS 和 Intel 芯片、先翻译哪种语言。关掉后，下面两项也不会发送。"))
                Divider()
                item(String(localized: "用了哪些功能"), isOn: $settings.shareFeatures, enabled: settings.shareUsage,
                     sends: String(localized: "用全屏还是窗口，有没有开智能栏、iCloud 同步，有没有设置 AI（不含密钥和对话）。"),
                     why: String(localized: "知道哪些功能值得继续做好，哪些没人用可以简化。"))
                Divider()
                item(String(localized: "怎么打开的"), isOn: $settings.shareOpens, enabled: settings.shareUsage,
                     sends: String(localized: "每天打开了几次，分别是用快捷键、捏合、触发角、F4、程序坞图标还是菜单栏打开的。"),
                     why: String(localized: "优先把最常用的打开方式做顺手；某种方式突然没人用了，往往是它坏了。"))
                Divider()
                item(String(localized: "崩溃报告"), isOn: $settings.shareCrashes,
                     sends: String(localized: "LaunchUS 崩溃时 macOS 记下的崩溃类型、原因、出错的函数名和版本号，下次打开时发送。"),
                     why: String(localized: "找到并修好崩溃。没有它，只有你主动反馈我们才知道它崩溃了。"))
            }
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Label {
                Text("从不发送：App 列表、搜索内容、文件名和路径、文件夹名称、AI 对话、你的名字或邮箱。")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: "lock.fill") }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(String(localized: "完成"), action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func item(_ title: String, isOn: Binding<Bool>, enabled: Bool = true, sends: String, why: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                detail(String(localized: "发送"), sends)
                detail(String(localized: "用途"), why)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
                .disabled(!enabled)
        }
        .opacity(enabled ? 1 : 0.5)
        .padding(12)
    }

    private func detail(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RulesSheet: View {
    @Binding var rules: LayoutRules
    let apply: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("自定义整理规则").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) {
                Toggle(String(localized: "保留现有文件夹"), isOn: $rules.keepFolders)
                Toggle(String(localized: "系统自带 App 放进「系统」文件夹"), isOn: $rules.systemAppsFolder)
                Toggle(String(localized: "按分类建文件夹"), isOn: $rules.groupByCategory)
                if rules.groupByCategory {
                    Stepper(String(localized: "至少 \(rules.minFolderSize) 个 App 才建文件夹"), value: $rules.minFolderSize, in: 2...10)
                        .padding(.leading, 20)
                }
                Picker(String(localized: "文件夹位置"), selection: $rules.folderPlacement) {
                    Text("最前面").tag(LayoutRules.FolderPlacement.first)
                    Text("最后面").tag(LayoutRules.FolderPlacement.last)
                    Text("和 App 混排").tag(LayoutRules.FolderPlacement.mixed)
                }
                .pickerStyle(.radioGroup).horizontalRadioGroupLayout()
                Picker(String(localized: "排序"), selection: $rules.order) {
                    Text("名称").tag(LayoutRules.Order.name)
                    Text("最近安装").tag(LayoutRules.Order.recentlyAdded)
                    Text("上次打开").tag(LayoutRules.Order.lastOpened)
                    Text("颜色").tag(LayoutRules.Order.color)
                }
                .pickerStyle(.radioGroup).horizontalRadioGroupLayout()
            }
            Text("智能文件夹总会保留。整理会替换当前布局，建议先导出备份。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(String(localized: "取消"), action: cancel).keyboardShortcut(.cancelAction)
                Button(String(localized: "整理"), action: apply).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

extension DisplayTab {
    /// The picture is copied into LaunchUS's data, so moving or deleting the original is fine.
    func chooseBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "选择一张图片作为背景")
        guard Modal.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        do {
            Settings.shared.backgroundImage = try BackgroundImage.importImage(url)
        } catch {
            NSLog("LaunchUS: failed to copy background image: \(error)")
        }
    }
}

/// "编辑智能栏…" next to the smart bar setting: the same editor the launcher's right-click opens.
private struct SmartBarButton: View {
    let model: LauncherModel
    @State private var shown = false

    var body: some View {
        Button(String(localized: "编辑智能栏…")) { shown = true }
            .sheet(isPresented: $shown) {
                SmartBarEditor(model: model) { shown = false }
                    .frame(width: 760, height: 540)
            }
    }
}
