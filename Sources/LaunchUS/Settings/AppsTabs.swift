import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

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
                    let scrolling = settings.pageStyle == .scroll
                    let ring = settings.displayMode == .ring
                    Row(title: String(localized: "隐形圆点"), subtitle: scrolling ? ModeNote.paged
                            : ring ? String(localized: "圆环中间，分页圆点后面，鼠标移上去才会出现")
                            : String(localized: "最后一个分页圆点后面，鼠标移上去才会出现")) {
                        Toggle("", isOn: $settings.hiddenDotEntrance).toggleStyle(.switch).labelsHidden()
                            .disabled(scrolling)
                    }
                    Row(title: String(localized: "隐形空位"), subtitle: ring ? ModeNote.grid : scrolling
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
                        .disabled(ring)
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
                    subtitle: settings.pageStyle == .scroll ? ModeNote.paged
                        : settings.sortOrder != .custom ? String(localized: "按自定义排序时生效") : nil,
                    info: String(localized: "随处摆放：图标落在松手处的格子里，可以留出空位；调整行列数时，图标保持原来的行和列。依次排列：图标一个挨一个，空位自动补上")) {
                    Picker("", selection: $settings.freePlacement) {
                        Text("依次排列").tag(false)
                        Text("随处摆放").tag(true)
                    }
                    .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().fixedSize()
                    .disabled(settings.pageStyle == .scroll)
                }
            }
        }
        SettingsSection(title: String(localized: "一键整理")) {
            Card {
                Row(title: String(localized: "整理空位"), subtitle: settings.pageStyle == .scroll ? ModeNote.paged : nil,
                    info: String(localized: "按当前行列，把 App 向前移动，填满前面页面的空位。")) {
                    Button(String(localized: "重新整理")) { model.compactLayout() }
                        .disabled(settings.pageStyle == .scroll)
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
