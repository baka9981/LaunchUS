import AppKit
import SwiftUI

/// 方案: the profile itself — its name and language, its automatic backups, and putting
/// its settings back.
struct ManageTab: View {
    let model: LauncherModel
    @Bindable var settings: Settings

    var body: some View {
        let name = model.currentProfile
        SettingsSection(title: String(localized: "这个方案")) {
            Card {
                Row(title: String(localized: "名称"), subtitle: LayoutProfiles.title(name)) {
                    HStack(spacing: 8) {
                        Button(String(localized: "重命名…")) {
                            model.closeSettings()
                            model.sheet = .renameProfile(name)
                        }
                        Button(String(localized: "删除方案"), role: .destructive) {
                            confirmAlert(String(localized: "删除方案「\(LayoutProfiles.title(name))」？"),
                                         String(localized: "它的页面和设置会一起删除，App 本身不受影响。"),
                                         button: String(localized: "删除")) { model.deleteProfile(name) }
                        }
                    }
                    .disabled(name.isEmpty)
                    .help(name.isEmpty ? String(localized: "默认方案不能重命名或删除") : "")
                }
                Row(title: String(localized: "语言"), info: String(localized: "切换到语言不同的方案时，LaunchUS 会自动重启一下")) {
                    MenuPicker(selection: Binding(get: { settings.language }, set: { new in
                        guard new != settings.language else { return }
                        settings.language = new
                        let alert = NSAlert()
                        alert.messageText = String(localized: "重启 LaunchUS 后生效")
                        alert.addButton(withTitle: String(localized: "现在重启"))
                        alert.addButton(withTitle: String(localized: "稍后"))
                        if Modal.run({ alert.runModal() }) == .alertFirstButtonReturn {
                            AppRelauncher.relaunch(opening: URL(string: "launchus://settings?tab=manage"))
                        }
                    }), options: AppLanguage.allCases, title: \.title)
                }
            }
        }
        AutoBackupSection(model: model, settings: settings)
        SettingsSection(title: String(localized: "还原")) {
            Card {
                Row(title: String(localized: "还原设置"),
                    info: String(localized: "这个方案的设置回到刚安装时的样子；页面、隐藏的 App、显示方式、图标和语言不变")) {
                    Button(String(localized: "还原…")) {
                        confirmAlert(String(localized: "还原「\(model.profileLabel(name))」的设置？"),
                                     String(localized: "除了显示方式、图标和语言，这个方案的设置都会回到默认。页面和隐藏的 App 不变。"),
                                     button: String(localized: "还原")) { model.resetProfileSettings() }
                    }
                }
            }
        }
    }
}
