import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 高级 › 备份与迁移 › 导出: pick the layout profiles that go into the file.
struct ExportProfilesSheet: View {
    let model: LauncherModel
    let done: () -> Void
    @State private var chosen: Set<String> = []

    var body: some View {
        let names = model.profileNames
        VStack(alignment: .leading, spacing: 14) {
            Text("导出布局").font(.system(size: 15, weight: .semibold))
            Text("选择要导出的方案。每个方案带上它的页面、文件夹、隐藏的 App 和设置；App 的名称、标签和图标也会一起导出。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Card {
                ForEach(names, id: \.self) { name in
                    ProfileCheckRow(title: model.profileLabel(name), detail: name == model.currentProfile ? String(localized: "正在使用") : nil,
                                    isOn: Binding(get: { chosen.contains(name) },
                                                  set: { if $0 { chosen.insert(name) } else { chosen.remove(name) } }))
                }
            }
            HStack {
                Button(chosen.count == names.count ? String(localized: "全不选") : String(localized: "全选")) {
                    chosen = chosen.count == names.count ? [] : Set(names)
                }
                Spacer()
                Button(String(localized: "取消"), action: done).keyboardShortcut(.cancelAction)
                Button(String(localized: "导出…")) { export(names.filter(chosen.contains)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { chosen = Set(names) }
    }

    private func export(_ names: [String]) {
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = names.count == 1
            ? String(localized: "LaunchUS 布局「\(LayoutProfiles.title(names[0]))」\(stamp).json")
            : String(localized: "LaunchUS 布局 \(stamp).json")
        panel.allowedContentTypes = [.json]
        guard Modal.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        do {
            try model.exportBackup(of: names, to: url)
            done()
        } catch {
            failAlert(String(localized: "导出失败"), error)
        }
    }
}

/// 高级 › 备份与迁移 › 导入: after reading a file, pick which of its profiles come in, and
/// whether one with a name that's already here replaces it or comes in as a new profile.
struct ImportProfilesSheet: View {
    let model: LauncherModel
    let backup: LayoutBackup
    let done: () -> Void
    @State private var chosen: Set<String> = []
    /// Names already here that come in as a new profile instead of replacing it.
    @State private var asNew: Set<String> = []

    var body: some View {
        let found = backup.allProfiles
        VStack(alignment: .leading, spacing: 14) {
            Text("导入布局").font(.system(size: 15, weight: .semibold))
            Text(found.count == 1
                 ? String(localized: "这个文件里有 1 个方案。")
                 : String(localized: "这个文件里有 \(found.count) 个方案，选择要导入哪些。"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Card {
                ForEach(found) { profile in
                    let exists = LayoutProfiles.resolve(profile.name, in: model.profiles) != nil
                    HStack(spacing: 10) {
                        ProfileCheckRow(title: LayoutProfiles.title(profile.name),
                                        detail: String(localized: "\(profile.pages.count) 页"),
                                        isOn: Binding(get: { chosen.contains(profile.name) },
                                                      set: { if $0 { chosen.insert(profile.name) } else { chosen.remove(profile.name) } }))
                        if exists {
                            Picker("", selection: Binding(get: { asNew.contains(profile.name) },
                                                          set: { if $0 { asNew.insert(profile.name) } else { asNew.remove(profile.name) } })) {
                                Text("替换现有的").tag(false)
                                Text("另存为新方案").tag(true)
                            }
                            .labelsHidden().fixedSize()
                            .disabled(!chosen.contains(profile.name))
                            .padding(.trailing, 14)
                        }
                    }
                }
            }
            Text("App 的名称、标签、图标和启动项会合并进来。导入前会自动备份。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if found.count > 1 {
                    Button(chosen.count == found.count ? String(localized: "全不选") : String(localized: "全选")) {
                        chosen = chosen.count == found.count ? [] : Set(found.map(\.name))
                    }
                }
                Spacer()
                Button(String(localized: "取消"), action: done).keyboardShortcut(.cancelAction)
                Button(String(localized: "导入")) { importChosen(found) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { chosen = Set(found.map(\.name)) }
    }

    private func importChosen(_ found: [LayoutBackup.Profile]) {
        let picked = found.filter { chosen.contains($0.name) }
        // Names the file's profiles keep, so one saved as new doesn't land on another.
        var taken = Set(picked.map(\.name).filter { !asNew.contains($0) || LayoutProfiles.resolve($0, in: model.profiles) == nil })
        let picks = picked.map { profile in
            guard asNew.contains(profile.name), LayoutProfiles.resolve(profile.name, in: model.profiles) != nil else {
                return (profile: profile, as: profile.name)
            }
            let name = model.unusedProfileName(like: profile.name, avoiding: taken)
            taken.insert(name)
            return (profile: profile, as: name)
        }
        done()
        // A backup can unhide apps, so it needs the same verification as showing them.
        model.whenHiddenUnlocked(reason: String(localized: "导入布局备份")) {
            model.importProfiles(picks, from: backup)
        }
    }
}

private struct ProfileCheckRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
