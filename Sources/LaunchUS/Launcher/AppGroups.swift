import AppKit
import SwiftUI

/// Folders double as app groups: "全部打开" (or the folder's own shortcut, or the Shortcuts
/// action) opens every app in it at once, e.g. a "写代码" folder with an editor, a terminal
/// and a browser.
extension LauncherModel {
    /// Prefix of shortcut IDs that belong to a folder rather than an app.
    static let folderShortcutPrefix = "folder:"

    func folder(_ id: String) -> Folder? {
        for case .folder(let folder) in layout.joined() where folder.id == id { return folder }
        return barFolders.first { $0.id == id }
    }

    func folder(named name: String) -> Folder? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        for case .folder(let folder) in layout.joined()
        where folder.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame { return folder }
        return nil
    }

    /// The apps a folder holds now: its list, or what a smart folder's search finds.
    func apps(in folder: Folder) -> [AppItem] {
        if let query = folder.query { return search(query) }
        let byID = Dictionary(visibleApps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return folder.apps.compactMap { byID[$0] }
    }

    /// Opens every app in the folder; the last one ends up in front.
    func openAll(_ folderID: String) {
        guard let folder = folder(folderID) else { return }
        let apps = apps(in: folder).filter { !SettingsPanes.isPane($0.id) }
        guard !apps.isEmpty else { return }
        for app in apps { RecentLaunches.record(app.id) }
        recentIDs = RecentLaunches.load()
        updateFrequentApps()
        onOpenGroup?(apps)
    }
}

/// Sets the shortcut that opens every app in a folder.
struct FolderShortcutCard: View {
    let model: LauncherModel
    let folderID: String
    @State private var tick = 0

    var body: some View {
        let folder = model.folder(folderID)
        let id = LauncherModel.folderShortcutPrefix + folderID
        let shortcut = model.meta(for: id).shortcut
        let apps = folder.map(model.apps(in:)) ?? []
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(folder?.name ?? "").font(.system(size: 17, weight: .semibold))
                Text("在任何地方按下快捷键，就打开这个文件夹里的全部 \(apps.count) 个 App")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: -6) {
                ForEach(apps.prefix(9)) { app in
                    if let icon = model.catalog.icons[app.id] {
                        Image(decorative: icon, scale: 2).resizable().frame(width: 34, height: 34)
                    }
                }
            }
            HStack(spacing: 8) {
                ShortcutRecorder(display: shortcut?.display, placeholder: String(localized: "点按后按下快捷键"), width: 200,
                                 soft: true,
                                 clear: { model.setShortcut(nil, for: id) },
                                 record: { model.setShortcut($0, for: id) })
                    .id(tick)
                if shortcut != nil {
                    Button { model.setShortcut(nil, for: id); tick += 1 } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "清除"))
                }
                if AppHotKeys.failed.contains(id) {
                    Text("已被占用，换一个").font(.system(size: 11)).foregroundStyle(.red)
                }
            }
            Text("也可以在快捷指令里用「打开 App 组」，或链接 launchus://openall?name=\(folder?.name ?? "")")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button(String(localized: "好")) { model.sheet = nil }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
    }
}
