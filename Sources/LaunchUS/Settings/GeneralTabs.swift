import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

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
                Row(title: String(localized: "鼠标连点"), info: String(localized: "快速连续按几下鼠标的某个键时打开或关闭。中键或侧键最合适，左右键本身的点击也会照常生效。")) {
                    MenuPicker(selection: $settings.clickButton, options: ClickButton.allCases, title: \.title)
                }
                if settings.clickButton != .off {
                    Row(title: String(localized: "连点次数")) {
                        MenuPicker(selection: $settings.clickCount, options: [2, 3, 4, 5]) {
                            String(format: String(localized: "%lld 下"), $0)
                        }
                    }
                    if let other = model.otherProfile(opening: { $0.clickButton == settings.clickButton }) {
                        SettingWarning(text: String(localized: "方案「\(LayoutProfiles.title(other))」也用这个键连点，只有一个会打开。"))
                    }
                    if settings.clickButton == .left, settings.clickCount <= 3 {
                        SettingWarning(text: String(localized: "左键双击打开文件、三击选中整段，连点这么几下时它们也会触发。建议用 4 下以上，或换成中键、侧键。"))
                    } else if settings.clickButton == .right {
                        SettingWarning(text: String(localized: "每次右键都会弹出菜单，连点时也一样。建议换成中键或侧键。"))
                    }
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
                Row(title: String(localized: "回到主页面"), info: settings.pageStyle == .scroll
                        ? String(localized: "再次打开时，隔多久回到最上面；在这之前会停在上次浏览的位置")
                        : String(localized: "再次打开时，隔多久回到第一页；在这之前会停在上次浏览的位置")) {
                    MenuPicker(selection: $settings.returnHome, options: ReturnHome.allCases, title: \.title)
                }
                Row(title: String(localized: "鼠标滚轮翻页"),
                    info: String(localized: "往左，要多滚几格才翻一页；中间，滚一下翻一页；往右，一直滚就一直翻。触控板不受影响")) {
                    HStack(spacing: 8) {
                        Text("慢").font(.system(size: 11)).foregroundStyle(.secondary)
                        Slider(value: $settings.wheelSpeed, in: 0...1).frame(width: 160)
                        Text("快").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button(String(localized: "还原")) { settings.wheelSpeed = 0.5 }
                            .disabled(abs(settings.wheelSpeed - 0.5) < 0.01)
                    }
                }
                Row(title: String(localized: "点击空白区域关闭")) {
                    Toggle("", isOn: $settings.clickBackgroundToClose).toggleStyle(.switch).labelsHidden()
                }
            }
        }
        // The ring has no jiggle mode, multi-select or dragging; its right-click menu does the editing.
        if settings.displayMode != .ring {
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
