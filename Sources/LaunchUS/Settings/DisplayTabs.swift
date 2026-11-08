import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

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
                    info: String(localized: "全屏：铺满屏幕，像原来的启动台。窗口：浮在桌面上，像一个 App 窗口。圆环：在指针周围排成一圈，文件夹点开是里面的一圈")) {
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
                } else if settings.displayMode == .window {
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
                            Text("动态").tag(BackgroundKind.dynamic)
                        }
                        .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().fixedSize()
                    }
                    if settings.background == .image {
                        Row(title: String(localized: "图片"), subtitle: BackgroundImage.url(settings.backgroundImage) == nil
                                ? String(localized: "还没有选择，暂时使用系统壁纸") : nil) {
                            Button(String(localized: "选择图片…"), action: chooseBackground)
                        }
                    }
                    if settings.background == .dynamic {
                        DynamicWallpaperRows(model: model, settings: settings)
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
                ModeThumb(windowed: mode == .window, ring: mode == .ring)
                    .frame(maxWidth: .infinity)
                    .frame(height: thumbHeight)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title).font(.system(size: 13, weight: .semibold))
                    Text(mode.summary)
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
    var ring = false

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
                if ring {
                    // Two rings of icons round the pointer.
                    ForEach(0..<14, id: \.self) { i in
                        let inner = i < 6
                        let angle = Double(inner ? i : i - 6) / (inner ? 6 : 8) * 2 * .pi - .pi / 2
                        let r = (inner ? 19 : 36) * k
                        RoundedRectangle(cornerRadius: 3 * k, style: .continuous).fill(.white.opacity(0.85))
                            .frame(width: 12 * k, height: 12 * k)
                            .offset(x: cos(angle) * r, y: sin(angle) * r)
                    }
                    Image(systemName: "cursorarrow").font(.system(size: 11 * k)).foregroundStyle(.white)
                } else {
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
