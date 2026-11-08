import SwiftUI

/// At the end of 通用: rename or delete the current profile (also on the profile bar's right-click menu).
struct ProfileManageSection: View {
    let model: LauncherModel

    var body: some View {
        let name = model.currentProfile
        if !name.isEmpty {
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
                    }
                }
            }
        }
    }
}
