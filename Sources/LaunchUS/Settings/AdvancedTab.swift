import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 高级

struct AdvancedTab: View {
    let model: LauncherModel
    @Bindable var settings: Settings
    @State private var autoCheck = Updater.shared.automaticallyChecks
    @State private var checkInterval = Updater.shared.checkInterval
    @State private var autoInstall = Updater.shared.automaticallyInstalls
    @State private var beta = Updater.shared.receivesBeta
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
                    Row(title: String(localized: "接收 Beta 版"),
                        info: String(localized: "提前收到还在测试的新版本，可能有问题，遇到了请在「反馈」里告诉开发者。关掉后不会退回旧版本，下一个正式版出来时照常更新。")) {
                        Toggle("", isOn: $beta).toggleStyle(.switch).labelsHidden()
                            .onChange(of: beta) { _, on in Updater.shared.receivesBeta = on }
                    }
                }
            }
        }
        BackupSection(model: model, settings: settings)
        SettingsSection(title: String(localized: "数据与隐私")) {
            Card {
                Row(title: String(localized: "数据文件夹"), info: String(localized: "布局、文件夹、启动项、自定义图标和备份都存在这里")) {
                    Button(String(localized: "在访达中显示")) { model.reveal(LayoutStore.directory.path) }
                }
                Row(title: String(localized: "和开发者分享匿名使用信息")) {
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
                     why: String(localized: "知道有多少台 Mac 在用、新版本有没有装上、还要不要支持旧版 macOS 和 Intel 芯片、先翻译哪种语言。关掉后，下面两项也不会发送；关掉的那一刻会发最后一条（只有安装编号），让我们知道这台 Mac 是关了统计，而不是卸载了。"))
                Divider()
                item(String(localized: "用了哪些功能"), isOn: $settings.shareFeatures, enabled: settings.shareUsage,
                     sends: String(localized: "用全屏、窗口还是圆环，有没有开智能栏、iCloud 同步，有没有设置 AI（不含密钥和对话）。"),
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
