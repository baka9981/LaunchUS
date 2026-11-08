import AppKit
import SwiftUI

/// Uninstall: the app plus its leftovers in ~/Library, grouped by kind.
struct UninstallCard: View {
    let model: LauncherModel
    let app: AppItem

    @State private var groups: [Uninstaller.Group]?
    @State private var selected: Set<String> = []
    @State private var expanded: Set<String> = ["app"]
    @State private var working = false

    private var files: [Uninstaller.File] { groups?.flatMap(\.files) ?? [] }
    private var selectedSize: Int64 { files.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }
    private var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                if let icon = model.catalog.icons[app.id] {
                    Image(decorative: icon, scale: 2).resizable().frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.system(size: 20, weight: .semibold))
                    Text(groups == nil ? String(localized: "正在查找相关文件…")
                         : "\(Uninstaller.format(selectedSize)) / \(Uninstaller.format(totalSize))")
                        .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(24)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let groups {
                        ForEach(groups) { group in groupSection(group) }
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            }
            .frame(height: 270)

            if files.contains(where: \.restricted) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                    Text("部分数据受系统保护，大小可能偏小，也可能无法移除。点「打开设置」，把浮窗里的 LaunchUS 拖进「完全磁盘访问权限」列表并打开开关，即可完整清理。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(String(localized: "打开设置")) { model.openFullDiskAccessSettings(resuming: app.id) }
                        .controlSize(.small)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.08))
            }
            Divider()

            HStack(spacing: 12) {
                Toggle(String(localized: "全部"), isOn: Binding(
                    get: { !files.isEmpty && selected.count == files.count },
                    set: { selected = $0 ? Set(files.map(\.id)) : [] }))
                    .toggleStyle(.checkbox)
                    .disabled(groups == nil)
                Spacer()
                Button { model.dismissSheet() } label: { Text("取消").frame(width: 96) }
                    .keyboardShortcut(.cancelAction)
                Button(action: uninstall) { Text(working ? String(localized: "正在移除…") : String(localized: "移到废纸篓")).frame(width: 120) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || working)
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .task {
            let found = await Uninstaller.scan(app)
            groups = found
            selected = Set(found.flatMap(\.files).map(\.id))
        }
    }

    @ViewBuilder
    private func groupSection(_ group: Uninstaller.Group) -> some View {
        let ids = Set(group.files.map(\.id))
        let open = expanded.contains(group.id)
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { ids.isSubset(of: selected) },
                set: { if $0 { selected.formUnion(ids) } else { selected.subtract(ids) } })) {
                Text(group.id == "app" ? group.title : "\(group.title) (\(group.files.count))")
                    .font(.system(size: 15))
            }
            .toggleStyle(.checkbox)
            Spacer()
            if !open {
                Text(Uninstaller.format(group.size)).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 0 : -90))
                .frame(width: 20)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) {
                if open { expanded.remove(group.id) } else { expanded.insert(group.id) }
            }
        }

        if open {
            VStack(spacing: 0) {
                ForEach(group.files) { file in fileRow(file) }
            }
            .padding(.leading, 34)
            .padding(.bottom, 4)
        }
    }

    private func fileRow(_ file: Uninstaller.File) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selected.contains(file.id) },
                set: { if $0 { selected.insert(file.id) } else { selected.remove(file.id) } }))
                .toggleStyle(.checkbox).labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent).font(.system(size: 14)).lineLimit(1)
                Text((file.url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if file.restricted {
                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.orange).help(String(localized: "受系统保护"))
            }
            Text(Uninstaller.format(file.size)).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            Button { model.reveal(file.url.path) } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(String(localized: "在访达中显示"))
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func uninstall() {
        working = true
        let urls = files.filter { selected.contains($0.id) }.map(\.url)
        let quit = selected.contains(app.url.path) ? app.bundleID : nil
        Task {
            let failed = await Uninstaller.trash(urls, bundleID: quit)
            model.finishUninstall(app, failed: failed)
        }
    }
}
