import SwiftUI

enum AppRelauncher {
    /// Starts a fresh copy once this one has quit, handing it `url` (a `launchus://` link) if given.
    @MainActor static func relaunch(opening url: URL? = nil) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; if [ -n \"$1\" ]; then /usr/bin/open -a \"$0\" \"$1\"; else /usr/bin/open \"$0\"; fi",
                          Bundle.main.bundlePath, url?.absoluteString ?? ""]
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
    /// Space the launcher has for the card; the big editors shrink to fit it.
    var room = CGSize(width: 10_000, height: 10_000)

    private func fit(_ width: CGFloat, _ height: CGFloat) -> CGSize {
        CGSize(width: min(width, room.width), height: min(height, room.height))
    }

    var body: some View {
        if case .editSmartFolder(let id, let query) = sheet {
            SmartBarEditor(model: model, initialFolder: id, initialQuery: query) { model.sheet = nil }
                .frame(width: fit(760, 540).width, height: fit(760, 540).height)
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
                .environment(\.windowedStyle, true)
                .contentShape(Rectangle())
                .onTapGesture {}
        } else if case .manager = sheet {
            AppManagerCard(model: model)
                .frame(width: fit(820, 600).width, height: fit(820, 600).height)
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
                .environment(\.windowedStyle, true)
                .contentShape(Rectangle())
                .onTapGesture {}
        } else if case .widgetGallery = sheet {
            WidgetGallery(model: model)
                .frame(width: fit(920, 640).width, height: fit(920, 640).height)
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
                .environment(\.windowedStyle, true)
                .contentShape(Rectangle())
                .onTapGesture {}
        } else if case .confirmTrash(let id) = sheet {
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
    /// Taller than the launcher (a small window), it scrolls.
    private var card: some View {
        ViewThatFits(in: .vertical) {
            cardContent
            // Only when it doesn't fit: a frame on the card itself would stretch it to the room.
            ScrollView { cardContent }.scrollIndicators(.never).frame(height: room.height)
        }
        .frame(width: cardWidth)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        // Chips and other launcher controls take their on-window colours.
        .environment(\.windowedStyle, true)
        // Clicks inside the card must not reach the dimmed background.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    /// The photo editor sets its preview beside the sliders; everything else is one column.
    private var cardWidth: CGFloat {
        if case .photoWidget = sheet { return 700 }
        return 420
    }

    private var cardContent: some View {
        Group {
            switch sheet {
            case .editApp(let id):
                if let app = model.app(id) { AppEditor(model: model, app: app) }
            case .confirmTrash, .manager, .editSmartFolder, .widgetGallery:
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
            case .renameProfile(let name):
                ProfileEditor(model: model, renaming: name)
            case .folderShortcut(let id):
                FolderShortcutCard(model: model, folderID: id)
            case .photoWidget(let id):
                PhotoWidgetCard(model: model, id: id)
            case .message(let title, let text, let revealPath):
                MessageCard(model: model, title: title, text: text, revealPath: revealPath)
            }
        }
        .padding(24)
        .frame(width: cardWidth)
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

/// One line of a grouped form: the label on the left, the field and an optional hint on the right.
struct FormLine<Content: View>: View {
    let label: String
    var hint: String?
    var hintIsError = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                content()
                if let hint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(hintIsError ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                }
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

struct FormDivider: View {
    var body: some View { Divider().padding(.leading, 78) }
}

/// A small "+ tag" suggestion under the tag field.
struct TagSuggestion: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: "+ " + title)
                .font(.system(size: 11))
                .foregroundStyle(hovering ? .primary : .secondary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Color.primary.opacity(hovering ? 0.1 : 0.05), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
    @State private var shortcutTick = 0
    @FocusState private var focus: Int?

    private var originalName: String { model.catalog.apps.first { $0.id == app.id }?.name ?? app.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(model: model, app: app, title: originalName, subtitle: app.bundleID ?? app.url.path)
            VStack(spacing: 0) {
                FormLine(label: String(localized: "名称")) {
                    TextField(originalName, text: $name).textFieldStyle(.plain).focused($focus, equals: 0)
                        .onSubmit(save)
                }
                FormDivider()
                FormLine(label: String(localized: "别名"), hint: String(localized: "只用于搜索，多个用逗号分隔")) {
                    TextField(String(localized: "例如：wx, 聊天"), text: $aliases).textFieldStyle(.plain).focused($focus, equals: 1)
                        .onSubmit(save)
                }
                FormDivider()
                FormLine(label: String(localized: "标签")) {
                    TextField(String(localized: "例如：设计, 常用"), text: $tags).textFieldStyle(.plain).focused($focus, equals: 2)
                        .onSubmit(save)
                    // Every known tag; while one is being typed, the ones it matches (pinyin too),
                    // and picking one completes it.
                    let list = LauncherModel.splitList(tags)
                    let typing = tags.last.map { !",，、;；\n ".contains($0) } == true ? list.last ?? "" : ""
                    let done = Set(typing.isEmpty ? list : list.dropLast())
                    let others = model.allTags.filter { !done.contains($0) && $0 != typing }
                    let shown = typing.isEmpty ? others : AppSearch.tagsMatching(typing, in: others)
                    if !shown.isEmpty {
                        FlowLayout(spacing: 5) {
                            ForEach(shown, id: \.self) { tag in
                                TagSuggestion(title: tag) {
                                    tags = ((typing.isEmpty ? list : Array(list.dropLast())) + [tag]).joined(separator: ", ")
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                FormDivider()
                let shortcutProblem = model.shortcutConflict(model.meta(for: app.id).shortcut, owner: app.id)
                FormLine(label: String(localized: "快捷键"), hint: shortcutProblem ?? String(localized: "在任何地方按下就打开它，再按一次隐藏"),
                         hintIsError: shortcutProblem != nil) {
                    HStack(spacing: 6) {
                        let shortcut = model.meta(for: app.id).shortcut
                        ShortcutRecorder(display: shortcut?.display, placeholder: String(localized: "点按后按下快捷键"), width: 170,
                                         soft: true,
                                         clear: { model.setShortcut(nil, for: app.id) },
                                         record: { model.setShortcut($0, for: app.id) })
                            .id(shortcutTick)
                        if shortcut != nil {
                            Button { model.setShortcut(nil, for: app.id); shortcutTick += 1 } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "清除"))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75))

            HStack(spacing: 8) {
                HStack(spacing: 14) {
                    Button { store(); model.sheet = .chooseIcon(app.id) } label: {
                        Label(String(localized: "更换图标…"), systemImage: "photo")
                    }
                    let inDock = DockPins.contains(app.url)
                    Button { DockPins.add(app.url); dockTick += 1 } label: {
                        Label(inDock ? String(localized: "已在程序坞中") : String(localized: "添加到程序坞"),
                              systemImage: inDock ? "checkmark" : "dock.rectangle")
                    }
                    .disabled(inDock)
                    .id(dockTick)
                }
                .buttonStyle(.borderless)
                .labelStyle(.titleAndIcon)
                .controlSize(.small)
                .font(.system(size: 12))
                Spacer()
                Button(String(localized: "取消")) { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button(String(localized: "存储"), action: save).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
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
