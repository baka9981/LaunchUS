import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, organize, apps, ai, advanced
    var id: String { rawValue }

    /// Tab names used by links (`launchus://settings?tab=`), including ones from older versions.
    static func named(_ name: String) -> SettingsTab? {
        switch name.lowercased() {
        case "about": .advanced
        case "layout": .organize
        case let other: SettingsTab(rawValue: other)
        }
    }

    var title: String {
        switch self {
        case .general: String(localized: "通用")
        case .appearance: String(localized: "外观")
        case .organize: String(localized: "整理")
        case .apps: "Apps"
        case .ai: "AI"
        case .advanced: String(localized: "高级")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "camera.filters"
        case .organize: "square.grid.3x3.topleft.filled"
        case .apps: "square.grid.2x2"
        case .ai: "sparkles"
        case .advanced: "switch.2"
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

/// The settings card shown over the launcher (right-click on empty space › 设置…).
struct SettingsView: View {
    @Bindable var model: LauncherModel
    @Bindable var settings: Settings
    let actions: SettingsActions
    var height: CGFloat = 700

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    TabButton(tab: tab, selected: model.settingsTab == tab) { model.settingsTab = tab }
                }
            }
            .padding(.top, 34)
            .padding(.bottom, 10)
            .padding(.horizontal, 24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch model.settingsTab {
                    case .general: GeneralTab(settings: settings)
                    case .appearance: AppearanceTab(model: model, settings: settings)
                    case .organize: OrganizeTab(model: model, settings: settings)
                    case .apps: AppsTab(model: model, settings: settings, actions: actions)
                    case .ai: AITab(settings: settings)
                    case .advanced: AdvancedTab(model: model, settings: settings)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .id(model.settingsTab)
        }
        .frame(width: 520, height: height)
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

private struct TabButton: View {
    let tab: SettingsTab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: tab.symbol).font(.system(size: 20))
                    .frame(height: 24)
                Text(tab.title).font(.system(size: 13))
            }
            .foregroundStyle(selected ? Color.accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(selected ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Building blocks

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
                    if index > 0 { Divider().padding(.horizontal, 14) }
                    subview
                }
            }
        }
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    @Bindable var settings: Settings
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var loginNeedsApproval = LoginItem.needsApproval
    @State private var trusted = Permissions.accessibility
    @State private var language = AppLanguage.current
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsSection(title: String(localized: "启动")) {
            Card {
                Row(title: String(localized: "开机自启动"), subtitle: loginNeedsApproval ? String(localized: "需要在「系统设置 › 通用 › 登录项」里允许") : nil) {
                    Toggle("", isOn: Binding(get: { loginEnabled }, set: { on in
                        LoginItem.set(on)
                        loginEnabled = LoginItem.isEnabled
                        loginNeedsApproval = LoginItem.needsApproval
                    }))
                    .toggleStyle(.switch).labelsHidden()
                }
                Row(title: String(localized: "语言")) {
                    MenuPicker(selection: Binding(get: { language }, set: { new in
                        guard new != language else { return }
                        language = new
                        new.apply()
                        let alert = NSAlert()
                        alert.messageText = String(localized: "重启 LaunchUS 后生效")
                        alert.addButton(withTitle: String(localized: "现在重启"))
                        alert.addButton(withTitle: String(localized: "稍后"))
                        if Modal.run({ alert.runModal() }) == .alertFirstButtonReturn { AppRelauncher.relaunch() }
                    }), options: AppLanguage.allCases, title: \.title)
                }
            }
        }
        SettingsSection(title: String(localized: "打开方式")) {
            Card {
                Row(title: String(localized: "快捷键")) { HotKeyRecorder(spec: $settings.hotKey) }
                Row(title: String(localized: "系统 F4 键"), info: String(localized: "用键盘上的 F4 键打开 LaunchUS（新款键盘上是「聚焦」键，打开后它不再打开聚焦）")) {
                    if trusted {
                        Toggle("", isOn: $settings.f4Key).toggleStyle(.switch).labelsHidden()
                    } else {
                        Button(String(localized: "授予权限")) { PermissionHelper.shared.request(.accessibility) }
                    }
                }
                Row(title: String(localized: "触控板"), info: String(localized: "捏合打开，张开关闭，界面跟随手指；松手时过半就完成，否则退回。建议在「系统设置 › 触控板 › 更多手势」里关掉系统自带的同一手势。")) {
                    Toggle("", isOn: $settings.trackpadPinch).toggleStyle(.switch).labelsHidden()
                }
                if settings.trackpadPinch {
                    Row(title: String(localized: "捏合手指数"), info: String(localized: "包括拇指")) {
                        MenuPicker(selection: $settings.pinchFingers, options: [3, 4, 5, TrackpadPinch.fourOrFive]) {
                            $0 == TrackpadPinch.fourOrFive ? String(localized: "4 指或 5 指")
                                : String(format: String(localized: "%lld 指"), $0)
                        }
                    }
                }
                Row(title: String(localized: "触发角"), info: String(localized: "把指针推到屏幕角落时打开或关闭。多台显示器时，只有不与其他显示器相邻的角落会响应。")) {
                    MenuPicker(selection: $settings.hotCorner, options: HotCorner.allCases, title: \.title)
                }
                if SystemHotCorners.isTaken(settings.hotCorner) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(String(localized: "这个角落已设置了系统的触发角，两者会同时触发。"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(String(localized: "打开系统设置")) { SystemHotCorners.openSettings() }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
            }
        }
        SettingsSection(title: String(localized: "行为")) {
            Card {
                Row(title: String(localized: "启动台显示在")) {
                    MenuPicker(selection: $settings.targetScreen, options: TargetScreen.allCases, title: \.title)
                }
                Row(title: String(localized: "回到主页面"), info: String(localized: "再次打开时，隔多久回到第一页；在这之前会停在上次浏览的位置")) {
                    MenuPicker(selection: $settings.returnHome, options: ReturnHome.allCases, title: \.title)
                }
                Row(title: String(localized: "点击空白区域关闭")) {
                    Toggle("", isOn: $settings.clickBackgroundToClose).toggleStyle(.switch).labelsHidden()
                }
                Row(title: String(localized: "网页搜索"), info: String(localized: "搜索没有结果时，按 ↩ 用它搜索；按 ⌘↩ 在访达中搜索")) {
                    MenuPicker(selection: $settings.searchEngine, options: SearchEngine.allCases, title: \.title)
                }
                Row(title: String(localized: "搜索文件"), info: String(localized: "在 App 下面列出聚焦找到的文件和文件夹")) {
                    Toggle("", isOn: $settings.searchFiles).toggleStyle(.switch).labelsHidden()
                }
            }
        }
        .onReceive(poll) { _ in
            trusted = Permissions.accessibility
            loginEnabled = LoginItem.isEnabled
            loginNeedsApproval = LoginItem.needsApproval
        }
    }
}

/// Click, then press the new shortcut. Esc cancels; Delete restores ⌥Space.
struct HotKeyRecorder: View {
    @Binding var spec: HotKeySpec

    var body: some View {
        ShortcutRecorder(display: spec.display, clear: { spec = .default }, record: { spec = $0 })
    }
}

/// Click, then press a shortcut. Esc cancels; Delete calls `clear`. Every global shortcut is
/// paused meanwhile, so pressing one that's in use records it instead of firing it.
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
        AppHotKeys.paused = true
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
        AppHotKeys.paused = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private let kVK_Escape_ = 53

// MARK: - 外观

struct AppearanceTab: View {
    let model: LauncherModel
    @Bindable var settings: Settings

    var body: some View {
        SettingsSection(title: String(localized: "显示")) {
            Card {
                Row(title: String(localized: "外观"), info: String(localized: "设置、菜单和窗口模式用浅色或深色；选「自动」时随 Mac 切换")) {
                    Picker("", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Row(title: String(localized: "显示模式")) {
                    HStack(spacing: 14) {
                        ModeThumb(title: String(localized: "全屏"), windowed: false, selected: settings.displayMode == .fullScreen) { settings.displayMode = .fullScreen }
                        ModeThumb(title: String(localized: "窗口"), windowed: true, selected: settings.displayMode == .window) { settings.displayMode = .window }
                    }
                }
                if settings.displayMode == .fullScreen {
                    Row(title: String(localized: "隐藏程序坞"), info: String(localized: "全屏时盖住程序坞和菜单栏；关掉则让程序坞留在最上面")) {
                        Toggle("", isOn: $settings.hideDock).toggleStyle(.switch).labelsHidden()
                    }
                }
                Row(title: String(localized: "动画速度")) {
                    Picker("", selection: $settings.animationSpeed) {
                        ForEach(AnimationSpeed.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
        }
        SettingsSection(title: String(localized: "网格")) {
            Card {
                Row(title: String(localized: "网格布局"), subtitle: String(localized: "列 × 行")) {
                    HStack(spacing: 8) {
                        NumberStepper(value: $settings.columns, range: 4...10)
                        Text("×").foregroundStyle(.secondary)
                        NumberStepper(value: $settings.rows, range: 3...8)
                    }
                }
                Row(title: String(localized: "图标大小"), subtitle: settings.iconScale == 1 ? nil : "\(Int((settings.iconScale * 100).rounded()))%") {
                    HStack(spacing: 8) {
                        Image(systemName: "app").font(.system(size: 10)).foregroundStyle(.secondary)
                        Slider(value: $settings.iconScale, in: 0.6...1.3, step: 0.05).frame(width: 180)
                        Image(systemName: "app").font(.system(size: 16)).foregroundStyle(.secondary)
                        Button(String(localized: "还原")) { settings.iconScale = 1 }
                            .disabled(settings.iconScale == 1)
                    }
                }
            }
        }
        SettingsSection(title: String(localized: "图标")) {
            Card {
                Row(title: String(localized: "液态玻璃"), info: String(localized: "文件夹、打开的文件夹和搜索栏透出并折射后面的内容；关掉则用烟灰玻璃")) {
                    Toggle("", isOn: $settings.liquidGlass).toggleStyle(.switch).labelsHidden()
                }
                Row(title: String(localized: "深色图标"), info: String(localized: "使用 App 自带的深色图标，就像深色模式下的程序坞；没有深色版本的 App 保持原样")) {
                    MenuPicker(selection: $settings.darkIcons, options: DarkIconMode.allCases, title: \.title)
                }
                Row(title: String(localized: "常用一行"), info: String(localized: "在搜索栏下方显示最近打开的 App")) {
                    Toggle("", isOn: $settings.showFrequent).toggleStyle(.switch).labelsHidden()
                }
                Row(title: String(localized: "隐藏名称")) {
                    HStack(spacing: 14) {
                        Toggle("App", isOn: $settings.hideNames)
                        Toggle(String(localized: "文件夹"), isOn: $settings.hideFolderNames)
                    }
                    .toggleStyle(.checkbox)
                }
                Row(title: String(localized: "图标标记")) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            mark("新 App 标记", $settings.showNewDot, "新安装的 App 图标下方亮起蓝色灯带，打开一次后熄灭")
                            mark("运行指示", $settings.showRunningDot, "正在运行的 App 图标下方亮起白色灯带")
                        }
                        GridRow {
                            mark("通知角标", $settings.showBadges, Permissions.accessibility
                                 ? "显示程序坞上 App 的未读数" : "显示程序坞上 App 的未读数，需要辅助功能权限")
                            mark("动态日历图标", $settings.dynamicCalendar, "「日历」的图标显示今天的日期")
                        }
                        GridRow {
                            mark("淡化久未打开的 App", $settings.fadeStale, "超过 3 个月没打开的 App 图标变淡")
                        }
                    }
                }
            }
        }
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
                if settings.background != .glass && settings.displayMode == .fullScreen {
                    Row(title: String(localized: "模糊壁纸"), info: String(localized: "拖到最左边关闭模糊")) {
                        Slider(value: $settings.blur, in: 0...240).frame(width: 220)
                    }
                }
                if settings.background == .glass && settings.displayMode == .fullScreen {
                    Row(title: String(localized: "玻璃强度")) {
                        Slider(value: $settings.glassStrength, in: 0.2...1).frame(width: 220)
                    }
                }
                Row(title: String(localized: "暗度")) {
                    Slider(value: $settings.dim, in: 0...0.6).frame(width: 220)
                }
                Row(title: String(localized: "深色时加深背景"), info: String(localized: "外观为深色时，背景再暗一些，图标和名称更清楚")) {
                    Toggle("", isOn: $settings.darkenBackground).toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }

    /// A small checkbox with an ⓘ that shows its explanation on click.
    private func mark(_ title: String.LocalizationValue, _ isOn: Binding<Bool>, _ help: String.LocalizationValue) -> some View {
        HStack(spacing: 4) {
            Toggle(String(localized: title), isOn: isOn)
                .toggleStyle(.checkbox)
            InfoButton(text: String(localized: help))
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

/// Little picture of full-screen vs window mode.
private struct ModeThumb: View {
    let title: String
    let windowed: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.25, green: 0.4, blue: 0.75), Color(red: 0.6, green: 0.7, blue: 0.9)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    if windowed {
                        RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.75)).frame(width: 64, height: 40)
                    }
                    let dot = Color.white.opacity(windowed ? 1 : 0.8)
                    VStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in
                            HStack(spacing: 4) {
                                ForEach(0..<5, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 1.5).fill(windowed ? Color.gray.opacity(0.35) : dot)
                                        .frame(width: windowed ? 6 : 8, height: windowed ? 6 : 8)
                                }
                            }
                        }
                    }
                }
                .frame(width: 96, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5).padding(-3))
                Text(title).font(.system(size: 12)).foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
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
        SettingsSection(title: String(localized: "应用来源")) {
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
        SettingsSection(title: String(localized: "隐藏的应用")) {
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
                    Row(title: String(localized: "隐形圆点"), subtitle: String(localized: "最后一个分页圆点后面，鼠标移上去才会出现")) {
                        Toggle("", isOn: $settings.hiddenDotEntrance).toggleStyle(.switch).labelsHidden()
                    }
                    Row(title: String(localized: "隐形空位"), subtitle: String(localized: "在所选页最后一个 App 后面的空位上右键，点击出现的虚线框")) {
                        HStack(spacing: 8) {
                            Picker("", selection: $settings.hiddenSlotPage) {
                                Text("最后一页").tag(0)
                                ForEach(1...max(1, model.pageCount), id: \.self) { Text("第 \($0) 页").tag($0) }
                            }
                            .labelsHidden().fixedSize()
                            .disabled(!settings.hiddenSlotEntrance)
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
                    Row(title: String(localized: "关闭启动台后重新隐藏"), subtitle: String(localized: "关闭时，下次需要重新通过入口打开")) {
                        Toggle("", isOn: $settings.hiddenRelock).toggleStyle(.switch).labelsHidden()
                    }
                }
                if hidden.isEmpty {
                    VStack(spacing: 6) {
                        Text("暂无应用").font(.system(size: 15, weight: .medium))
                        Text("右键点击应用即可隐藏").font(.system(size: 12)).foregroundStyle(.secondary)
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
                Row(title: String(localized: "浏览样式"), subtitle: settings.browseStyle == .scroll ? String(localized: "滚动模式下不能拖动整理图标") : nil) {
                    Picker("", selection: $settings.browseStyle) {
                        Text("分页").tag(BrowseStyle.paged)
                        Text("滚动").tag(BrowseStyle.scroll)
                    }
                    .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().fixedSize()
                }
                Row(title: String(localized: "文件夹内浏览"), info: String(localized: "App 超过一屏时上下滚动查看")) {
                    Picker("", selection: $settings.folderBrowseStyle) {
                        Text("分页").tag(BrowseStyle.paged)
                        Text("滚动").tag(BrowseStyle.scroll)
                    }
                    .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().fixedSize()
                }
            }
        }
        SettingsSection(title: String(localized: "编辑")) {
            Card {
                Row(title: String(localized: "多选"), info: String(localized: "按住所选按键点按 App 可多选，之后可一起拖进文件夹、新建文件夹、加标签或隐藏")) {
                    MenuPicker(selection: $settings.multiSelectKey, options: MultiSelectKey.allCases, title: \.title)
                }
                Row(title: String(localized: "卸载应用"), info: String(localized: "抖动模式（长按或按住 ⌥）下，可删除的 App 左上角显示 ✕")) {
                    MenuPicker(selection: $settings.deleteBadges, options: [true, false]) { $0 ? String(localized: "抖动时显示 ✕") : String(localized: "关") }
                }
            }
            Text(String(localized: "拖动图标到屏幕底边（窗口模式下拖出窗口），即可放到程序坞、访达或其他 App"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        SettingsSection(title: String(localized: "整理")) {
            Card {
                Row(title: String(localized: "整理空位"), info: String(localized: "按当前行列，把 App 向前移动，填满前面页面的空位。")) {
                    Button(String(localized: "重新整理")) { model.compactLayout() }
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
                Row(title: String(localized: "久未打开的 App"), info: String(localized: "选中超过 3 个月没打开的 App，再统一移进文件夹或隐藏")) {
                    Button(String(localized: "全部选中")) { model.selectStaleApps() }
                }
                Row(title: String(localized: "App 管理"), info: String(localized: "按大小查看所有 App，找出 Intel App、有更新的和很久没打开的，直接卸载；还有使用统计")) {
                    Button(String(localized: "打开…")) {
                        model.closeSettings()
                        model.sheet = .manager
                    }
                }
            }
        }
        SettingsSection(title: String(localized: "布局方案")) {
            Card {
                Row(title: String(localized: "当前方案"), info: String(localized: "每套方案各自保存页面和文件夹，App 的名称、标签和隐藏设置共用。也可以用链接 launchus://profile?name=名称 或快捷指令切换")) {
                    HStack {
                        MenuPicker(selection: Binding(get: { model.currentProfile }, set: { model.switchProfile($0) }),
                                   options: model.profileNames, title: LayoutProfiles.title)
                        Button(String(localized: "新建…")) {
                            model.closeSettings()
                            model.sheet = .newProfile
                        }
                        Button(String(localized: "删除")) { model.deleteProfile(model.currentProfile) }
                            .disabled(model.currentProfile.isEmpty)
                    }
                }
            }
        }
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

// MARK: - 高级

struct AdvancedTab: View {
    let model: LauncherModel
    @Bindable var settings: Settings
    @State private var autoCheck = Updater.shared.automaticallyChecks
    @State private var exporting = false

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: IconArt.image(settings.appIcon, size: 256)).resizable().frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text("LaunchUS").font(.system(size: 16, weight: .semibold))
                Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("经典启动台的重制版。全部功能免费。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if Updater.shared.isConfigured {
                VStack(alignment: .trailing, spacing: 6) {
                    Button(String(localized: "检查更新…")) { Updater.shared.checkForUpdates() }
                    Toggle(String(localized: "自动检查更新"), isOn: $autoCheck)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .onChange(of: autoCheck) { _, on in Updater.shared.automaticallyChecks = on }
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        SettingsSection(title: String(localized: "菜单栏与程序坞")) {
            Card {
                Row(title: String(localized: "菜单栏图标"), info: settings.showMenuBarIcon ? String(localized: "点按菜单栏图标即可打开或关闭启动台")
                        : String(localized: "隐藏后，可以再次打开 LaunchUS.app 或在启动台的 ⋯ 菜单里进入设置")) {
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
                Row(title: String(localized: "程序坞图标"), info: String(localized: "在程序坞显示图标，右键可直接打开 App，不用打开启动台")) {
                    HStack(spacing: 10) {
                        if settings.showDockIcon {
                            MenuPicker(selection: $settings.dockMenu, options: DockMenuContent.allCases, title: \.title)
                                .help(String(localized: "程序坞菜单"))
                        }
                        Toggle("", isOn: $settings.showDockIcon).toggleStyle(.switch).labelsHidden()
                    }
                }
                Row(title: String(localized: "应用图标"), info: String(localized: "程序坞和切换器里显示的图标")) {
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
        SettingsSection(title: String(localized: "同步与迁移")) {
            Card {
                Row(title: String(localized: "iCloud 同步"), subtitle: iCloudSubtitle) {
                    Toggle("", isOn: $settings.iCloudSync).toggleStyle(.switch).labelsHidden()
                        .disabled(!ICloudSync.isAvailable && !settings.iCloudSync)
                }
                Row(title: String(localized: "导入或导出布局"), info: String(localized: "导入或导出 LaunchUS 的布局、文件夹、名称、别名、标签和隐藏设置，用于备份或在设备之间迁移")) {
                    HStack {
                        Button(String(localized: "导入")) { importBackup() }
                        Button(String(localized: "导出")) { exportBackup() }
                    }
                }
                Row(title: String(localized: "从系统启动台导入"), info: String(localized: "沿用 macOS 15 及更早版本启动台里的页面和文件夹")) {
                    Button(String(localized: "导入…")) { importLaunchpad() }
                }
            }
        }
        SettingsSection(title: String(localized: "备份")) {
            Card {
                Row(title: String(localized: "自动备份"), subtitle: settings.autoBackupCount > 0
                        ? String(localized: "每次更改布局后自动备份，保留最近 \(settings.autoBackupCount) 份")
                        : String(localized: "已关闭")) {
                    Stepper(settings.autoBackupCount > 0 ? String(localized: "\(settings.autoBackupCount) 份") : String(localized: "关"),
                            value: $settings.autoBackupCount, in: 0...50)
                        .monospacedDigit()
                }
                Row(title: String(localized: "恢复自动备份"), info: String(localized: "回到之前某次更改前的布局")) {
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
        SettingsSection(title: String(localized: "帮助")) {
            HStack(spacing: 8) {
                Button(String(localized: "使用引导")) {
                    model.closeSettings()
                    model.openGuide()
                }
                Button(String(localized: "在访达中显示数据文件夹")) {
                    model.reveal(LayoutStore.directory.path)
                }
                Button(exporting ? String(localized: "正在收集…") : String(localized: "导出诊断信息…")) { exportDiagnostics() }
                    .disabled(exporting)
                    .help(String(localized: "反馈问题时附上这个文件。包含版本、设置和最近的日志，不含 App 列表和暗号"))
            }
            .padding(.horizontal, 4)
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

    private func exportBackup() {
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = String(localized: "LaunchUS 布局 \(stamp).json")
        panel.allowedContentTypes = [.json]
        guard Modal.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        do { try model.exportBackup(to: url) } catch { failAlert(String(localized: "导出失败"), error) }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard Modal.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        confirmAlert(String(localized: "导入这个布局备份？"), String(localized: "会替换当前的布局、文件夹和 App 设置。"), button: String(localized: "导入")) {
            // A backup can unhide apps, so it needs the same verification as showing them.
            model.whenHiddenUnlocked(reason: String(localized: "导入布局备份")) {
                do { try model.importBackup(from: url) } catch { failAlert(String(localized: "导入失败"), error) }
            }
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

    private func importLaunchpad() {
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
        confirmAlert(String(localized: "导入启动台的布局？"), String(localized: "会用启动台的页面和文件夹替换当前布局，名称、标签和隐藏设置保持不变。当前布局会先自动备份。"), button: String(localized: "导入")) {
            do { try model.importLaunchpad(from: url) } catch { failAlert(String(localized: "导入失败"), error) }
        }
    }

    private func restore(_ entry: AutoBackup.Entry) {
        let when = entry.date.formatted(date: .abbreviated, time: .standard)
        confirmAlert(String(localized: "恢复 \(when) 的布局？"), String(localized: "会替换当前的布局、文件夹和 App 设置。当前布局也已自动备份，可以随时换回来。"), button: String(localized: "恢复")) {
            model.whenHiddenUnlocked(reason: String(localized: "恢复布局备份")) {
                AutoBackup.snapshot()
                do { try model.importBackup(from: entry.url) } catch { failAlert(String(localized: "恢复失败"), error) }
            }
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

extension AppearanceTab {
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
