import SwiftUI

enum AppRelauncher {
    /// Starts a fresh copy once this one has quit.
    @MainActor static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// The ✕ on removable apps in jiggle mode.
struct DeleteBadge: View {
    let action: () -> Void

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.black.opacity(0.65))
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color(white: 0.88)))
            .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .contentShape(Circle().inset(by: -4))
            .onTapGesture(perform: action)
    }
}

/// Card shown over the launcher for editors and confirmations.
struct SheetCard: View {
    let model: LauncherModel
    let sheet: LauncherSheet

    var body: some View {
        if case .confirmTrash(let id) = sheet {
            if let app = model.app(id) {
                // A wider card for the file list.
                UninstallCard(model: model, app: app)
                    .frame(width: 560)
                    .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
                    .contentShape(Rectangle())
                    .onTapGesture {}
            }
        } else {
            card
        }
    }

    /// Same look as the settings window: the system window colour, light or dark with the Mac.
    private var card: some View {
        Group {
            switch sheet {
            case .editApp(let id):
                if let app = model.app(id) { AppEditor(model: model, app: app) }
            case .editSmartFolder(let id, let query):
                SmartFolderEditor(model: model, folderID: id, initialQuery: query)
            case .confirmTrash:
                EmptyView()
            case .appInfo(let id):
                if let app = model.app(id) { AppInfoCard(model: model, app: app) }
            case .editCustom(let id):
                CustomItemEditor(model: model, item: id.flatMap(model.customItem))
            case .confirmDeleteCustom(let id):
                if let app = model.app(id) { DeleteCustomItemCard(model: model, app: app) }
            case .chooseIcon(let id):
                if let app = model.app(id) { IconPicker(model: model, app: app) }
            case .newProfile:
                ProfileEditor(model: model)
            case .message(let title, let text, let revealPath):
                MessageCard(model: model, title: title, text: text, revealPath: revealPath)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        // Chips and other launcher controls take their on-window colours.
        .environment(\.windowedStyle, true)
        // Clicks inside the card must not reach the dimmed background.
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

struct CardHeader: View {
    let model: LauncherModel
    let app: AppItem?
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            if let app, let icon = model.catalog.icons[app.id] {
                Image(decorative: icon, scale: 2).resizable().frame(width: 52, height: 52)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
    }
}

struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 2)
            content()
        }
    }
}

/// A text field in a soft rounded well, like the rows of the settings window.
struct CardFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75))
    }
}

struct CardButtons: View {
    let confirmTitle: String
    var destructive = false
    var confirmDisabled = false
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(String(localized: "取消"), action: cancel).keyboardShortcut(.cancelAction)
            Button(confirmTitle, role: destructive ? .destructive : nil, action: confirm)
                .keyboardShortcut(.defaultAction)
                .disabled(confirmDisabled)
        }
        .controlSize(.large)
    }
}

/// Display name, search aliases and tags of one app.
struct AppEditor: View {
    let model: LauncherModel
    let app: AppItem

    @State private var name = ""
    @State private var aliases = ""
    @State private var tags = ""
    @State private var dockTick = 0
    @FocusState private var focus: Int?

    private var originalName: String { model.catalog.apps.first { $0.id == app.id }?.name ?? app.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(model: model, app: app, title: originalName, subtitle: app.bundleID ?? app.url.path)
            FieldRow(label: String(localized: "显示名称")) {
                TextField(originalName, text: $name).textFieldStyle(CardFieldStyle()).focused($focus, equals: 0)
                    .onSubmit(save)
            }
            FieldRow(label: String(localized: "搜索别名（用逗号分隔，只用于搜索）")) {
                TextField(String(localized: "例如：wx, 聊天"), text: $aliases).textFieldStyle(CardFieldStyle()).focused($focus, equals: 1)
                    .onSubmit(save)
            }
            FieldRow(label: String(localized: "标签（用逗号分隔）")) {
                TextField(String(localized: "例如：设计, 常用"), text: $tags).textFieldStyle(CardFieldStyle()).focused($focus, equals: 2)
                    .onSubmit(save)
                let current = Set(LauncherModel.splitList(tags))
                let others = model.allTags.filter { !current.contains($0) }
                if !others.isEmpty {
                    FlowChips(items: Array(others.prefix(16))) { tag in
                        tags = (LauncherModel.splitList(tags) + [tag]).joined(separator: ", ")
                    }
                }
            }
            HStack(spacing: 8) {
                Button(String(localized: "更换图标…"), systemImage: "photo") {
                    store()
                    model.sheet = .chooseIcon(app.id)
                }
                let inDock = DockPins.contains(app.url)
                Button(inDock ? String(localized: "已在程序坞中") : String(localized: "添加到程序坞"), systemImage: "dock.rectangle") {
                    DockPins.add(app.url)
                    dockTick += 1
                }
                .disabled(inDock)
                .id(dockTick)
            }
            .controlSize(.small)
            CardButtons(confirmTitle: String(localized: "存储"), cancel: { model.sheet = nil }, confirm: save)
        }
        .onAppear {
            let m = model.meta(for: app.id)
            name = m.displayName ?? ""
            aliases = m.aliases.joined(separator: ", ")
            tags = m.tags.joined(separator: ", ")
            DispatchQueue.main.async { focus = 0 }
        }
    }

    private func store() {
        model.updateApp(app.id, displayName: name, aliases: LauncherModel.splitList(aliases),
                        tags: LauncherModel.splitList(tags))
    }

    private func save() {
        store()
        model.sheet = nil
    }
}

/// Name and condition of a smart folder.
struct SmartFolderEditor: View {
    let model: LauncherModel
    let folderID: String?
    let initialQuery: String

    @State private var name = ""
    @State private var query = ""
    @FocusState private var focus: Int?

    var body: some View {
        let count = AppSearch.search(query, in: model.visibleApps,
                                     aliases: model.meta.compactMapValues { $0.aliases.isEmpty ? nil : $0.aliases },
                                     tags: model.meta.compactMapValues { $0.tags.isEmpty ? nil : $0.tags }).count
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(model: model, app: nil, title: folderID == nil ? String(localized: "新建智能文件夹") : String(localized: "编辑智能文件夹"),
                       subtitle: String(localized: "内容由条件决定，打上标签的 App 会自动出现在里面"))
            FieldRow(label: String(localized: "名称")) {
                TextField(LauncherModel.smartFolderName(for: query), text: $name)
                    .textFieldStyle(CardFieldStyle()).focused($focus, equals: 0).onSubmit(save)
            }
            FieldRow(label: String(localized: "条件（#标签 取交集，也可以加关键词）")) {
                TextField(String(localized: "#设计 #常用"), text: $query)
                    .textFieldStyle(CardFieldStyle()).focused($focus, equals: 1).onSubmit(save)
                if !model.allTags.isEmpty {
                    FlowChips(items: Array(model.allTags.prefix(16))) { tag in
                        let trimmed = query.trimmingCharacters(in: .whitespaces)
                        query = (trimmed.isEmpty ? "" : trimmed + " ") + "#" + tag
                    }
                }
                Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? " " : String(localized: "符合条件的 App：\(count) 个"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            CardButtons(confirmTitle: folderID == nil ? String(localized: "创建") : String(localized: "存储"),
                        confirmDisabled: query.trimmingCharacters(in: .whitespaces).isEmpty,
                        cancel: { model.sheet = nil }, confirm: save)
        }
        .onAppear {
            query = initialQuery
            if let folderID, let folder = model.pages.joined().compactMap({ entry -> Folder? in
                if case .folder(let f, _) = entry, f.id == folderID { return f }
                return nil
            }).first {
                name = folder.name
            }
            DispatchQueue.main.async { focus = initialQuery.isEmpty ? 1 : 0 }
        }
    }

    private func save() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.saveSmartFolder(folderID, name: name, query: query)
        model.sheet = nil
    }
}

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
                Button { model.sheet = nil } label: { Text("取消").frame(width: 96) }
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

struct MessageCard: View {
    let model: LauncherModel
    let title: String
    let text: String
    let revealPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(model: model, app: nil, title: title, subtitle: text)
            HStack {
                Spacer()
                if let revealPath {
                    Button(String(localized: "在访达中显示")) { model.sheet = nil; model.reveal(revealPath) }
                }
                Button(String(localized: "好")) { model.sheet = nil }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
    }
}

/// Small tappable tag chips that wrap onto new lines.
struct FlowChips: View {
    let items: [String]
    let tap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Chip(title: item) { tap(item) }
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var index = 0
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for _ in 0..<row.count {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: .unspecified)
                x += size.width + spacing
                index += 1
            }
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(count: Int, y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(count: Int, y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var count = 0, x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if count > 0, x + size.width > width {
                rows.append((count, y, x - spacing, rowHeight))
                y += rowHeight + spacing
                count = 0; x = 0; rowHeight = 0
            }
            count += 1
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        if count > 0 { rows.append((count, y, x - spacing, rowHeight)) }
        return rows
    }
}

/// The Dock's pinned apps, read from and added to com.apple.dock.
enum DockPins {
    private static func urls() -> [String] {
        let apps = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        return apps.compactMap { (($0["tile-data"] as? [String: Any])?["file-data"] as? [String: Any])?["_CFURLString"] as? String }
    }

    static func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return urls().contains { URL(string: $0)?.standardizedFileURL.path == path }
    }

    /// Appends the app to the Dock and restarts the Dock so it shows up.
    static func add(_ url: URL) {
        guard !contains(url) else { return }
        let fileURL = url.absoluteString.hasSuffix("/") ? url.absoluteString : url.absoluteString + "/"
        let escaped = fileURL.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let tile = "<dict><key>tile-data</key><dict><key>file-data</key><dict>"
            + "<key>_CFURLString</key><string>\(escaped)</string><key>_CFURLStringType</key><integer>15</integer>"
            + "</dict></dict><key>tile-type</key><string>file-tile</string></dict>"
        run("/usr/bin/defaults", ["write", "com.apple.dock", "persistent-apps", "-array-add", tile])
        run("/usr/bin/killall", ["Dock"])
    }

    private static func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}

/// Finder's Get Info window (there is no public API for it, so ask Finder).
enum FinderInfo {
    @MainActor static func show(_ url: URL) {
        let path = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(path)" as alias)
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("LaunchUS: Get Info failed: \(error)") }
    }
}
