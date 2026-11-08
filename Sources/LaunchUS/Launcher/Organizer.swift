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
        .frame(width: 420)
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
        .frame(width: 420)
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

/// 编辑智能栏: every smart folder in one place. On the left the list, in smart-bar order, with
/// whether each shows in the smart bar and on the pages; on the right the picked one's name and
/// condition, which apply as they're typed.
struct SmartBarEditor: View {
    let model: LauncherModel
    /// The folder to start on; nil with a query starts a new one from it.
    var initialFolder: String?
    var initialQuery = ""
    let close: () -> Void

    /// nil while a new folder is being written.
    @State private var selected: String?
    @State private var name = ""
    @State private var query = ""
    /// Set while a picked folder's name and condition are being loaded, so loading them isn't
    /// taken for an edit (the name would otherwise be saved with the previous one's condition).
    @State private var loading = false
    @FocusState private var focus: Int?

    var body: some View {
        let tabs = model.allCategoryTabs
        let hidden = Set(model.settings.hiddenCategoryTabs)
        // Looked up once per render rather than once per row.
        let folders = Dictionary(model.smartFolders.map { (LauncherModel.smartTabPrefix + $0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let barOnly = Set(model.barFolders.map(\.id))
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("编辑智能栏").font(.system(size: 17, weight: .semibold))
                Spacer()
                Toggle(String(localized: "显示智能栏"), isOn: Binding(get: { model.settings.showCategoryBar },
                                                                  set: { model.settings.showCategoryBar = $0 }))
                    .toggleStyle(.switch).controlSize(.small)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("智能文件夹").frame(maxWidth: .infinity, alignment: .leading)
                        Text("智能栏").frame(width: 46)
                        Text("主界面").frame(width: 46)
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    List(selection: Binding(get: { selected }, set: { if let id = $0 { pick(id) } })) {
                        ForEach(tabs, id: \.key) { tab in
                            if let folder = folders[tab.key] {
                                HStack(spacing: 0) {
                                    Text(folder.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    Toggle("", isOn: Binding(get: { !hidden.contains(tab.key) },
                                                             set: { model.setCategoryTab(tab.key, hidden: !$0) }))
                                        .toggleStyle(.checkbox).labelsHidden().frame(width: 46)
                                    Toggle("", isOn: Binding(get: { !barOnly.contains(folder.id) },
                                                             set: { model.setSmartFolder(folder.id, onPages: $0) }))
                                        .toggleStyle(.checkbox).labelsHidden().frame(width: 46)
                                }
                                .tag(folder.id)
                            }
                        }
                        .onMove { from, to in
                            var keys = tabs.map(\.key)
                            keys.move(fromOffsets: from, toOffset: to)
                            model.setCategoryTabOrder(keys)
                        }
                    }
                    .listStyle(.inset)
                    .overlay {
                        if tabs.isEmpty {
                            Text("还没有智能文件夹").font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                    }
                    Divider()
                    HStack(spacing: 6) {
                        Button { startNew("") } label: { Image(systemName: "plus").frame(width: 18, height: 16) }
                            .help(String(localized: "新建智能文件夹"))
                        Button { if let selected { delete(selected) } } label: { Image(systemName: "minus").frame(width: 18, height: 16) }
                            .help(String(localized: "删除智能文件夹"))
                            .disabled(selected == nil)
                        Spacer()
                        if !model.importableCategories.isEmpty {
                            Button(String(localized: "导入系统分类")) { model.importSystemCategories() }
                                .help(String(localized: "按 App Store 分类建好智能文件夹，只放在智能栏里"))
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .frame(width: 290)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack {
                Spacer()
                if selected == nil {
                    if !model.allCategoryTabs.isEmpty {
                        Button(String(localized: "取消")) {
                            if let first = model.allCategoryTabs.first.flatMap({ model.smartFolder(forTab: $0.key) }) { pick(first.id) }
                        }
                    }
                    Button(String(localized: "创建"), action: create)
                        .keyboardShortcut(.defaultAction)
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || !AppSearch.isComplete(AppSearch.tokens(query)))
                    Button(String(localized: "关闭"), action: close)
                } else {
                    Button(String(localized: "关闭"), action: close).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .onAppear {
            if let initialFolder, model.folder(initialFolder) != nil {
                pick(initialFolder)
            } else if initialFolder == nil, !initialQuery.isEmpty || model.allCategoryTabs.isEmpty {
                startNew(initialQuery)
            } else if let first = model.allCategoryTabs.first.flatMap({ model.smartFolder(forTab: $0.key) }) {
                pick(first.id)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView { fields.padding(20) }
                .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder private var fields: some View {
        let count = model.search(query).count
        let importable = selected == nil ? model.importableCategories : []
        VStack(alignment: .leading, spacing: 14) {
            Text(selected == nil ? String(localized: "新建智能文件夹") : String(localized: "内容由条件决定，符合条件的 App 会自动出现在里面"))
                .font(.system(size: selected == nil ? 15 : 12, weight: selected == nil ? .semibold : .regular))
                .foregroundStyle(selected == nil ? .primary : .secondary)
            if !importable.isEmpty, model.allCategoryTabs.isEmpty {
                // The first smart folders can simply be the system's categories.
                HStack(spacing: 10) {
                    Text("按 App Store 分类建好 \(importable.count) 个智能文件夹，放在智能栏里，新装的 App 会自动归进去")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(String(localized: "导入系统分类")) {
                        model.importSystemCategories()
                        if let first = model.allCategoryTabs.first.flatMap({ model.smartFolder(forTab: $0.key) }) { pick(first.id) }
                    }
                }
                .padding(10)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            FieldRow(label: String(localized: "文件夹名称")) {
                TextField(LauncherModel.smartFolderName(for: query), text: $name)
                    .textFieldStyle(CardFieldStyle()).focused($focus, equals: 0)
                    .onChange(of: name) { apply() }
            }
            FieldRow(label: String(localized: "规则")) {
                FormulaBuilder(query: $query, tags: model.allTags)
                let complete = AppSearch.isComplete(AppSearch.tokens(query))
                Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? " "
                     : complete ? String(localized: "符合条件的 App：\(count) 个") : String(localized: "规则还没写完：括号要配对，符号两边都要有内容"))
                    .font(.system(size: 11)).foregroundStyle(complete ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
        }
    }

    private func pick(_ id: String) {
        guard let folder = model.folder(id) else { return }
        loading = true
        selected = id
        name = folder.name
        query = folder.query ?? ""
        DispatchQueue.main.async { loading = false }
    }

    private func startNew(_ initial: String) {
        selected = nil
        name = ""
        query = initial
        DispatchQueue.main.async { focus = initial.isEmpty ? 1 : 0 }
    }

    /// Edits apply as they're typed; an empty condition waits until there's one.
    private func apply() {
        guard !loading, let selected, let folder = model.folder(selected) else { return }
        let q = query.trimmingCharacters(in: .whitespaces)
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, AppSearch.isComplete(AppSearch.tokens(q)),
              q != folder.query || (!n.isEmpty && n != folder.name) else { return }
        model.saveSmartFolder(selected, name: n, query: q, onPages: model.isOnPages(selected))
    }

    private func create() {
        // In the smart bar and on the pages; the list's checkboxes change either.
        guard let id = model.saveSmartFolder(nil, name: name, query: query, onPages: true) else { return }
        pick(id)
    }

    private func delete(_ id: String) {
        let order = model.allCategoryTabs.compactMap { model.smartFolder(forTab: $0.key)?.id }
        let next = order.firstIndex(of: id).flatMap { i in order.indices.contains(i + 1) ? order[i + 1] : (i > 0 ? order[i - 1] : nil) }
        model.dissolveFolder(id)
        if let next { pick(next) } else { startNew("") }
    }
}

/// A smart folder's rule, built by clicking: tags, categories, keywords and the set symbols
/// go into the formula as bubbles; clicking a bubble in the formula takes it out again.
struct FormulaBuilder: View {
    @Binding var query: String
    let tags: [String]
    @State private var keyword = ""

    /// The formula with the ∩ that two terms side by side mean anyway written out.
    private var tokens: [AppSearch.Token] {
        var out: [AppSearch.Token] = []
        for token in AppSearch.tokens(query) {
            if let last = out.last, Self.endsOperand(last), Self.startsOperand(token) { out.append(.and) }
            out.append(token)
        }
        return out
    }

    private static func endsOperand(_ t: AppSearch.Token) -> Bool { t.isTerm || t == .close }
    private static func startsOperand(_ t: AppSearch.Token) -> Bool { t.isTerm || t == .open || t == .not }

    var body: some View {
        let toks = tokens
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                FlowLayout(spacing: 5) {
                    if toks.isEmpty {
                        Text("点下面的标签、分类和符号，组成规则")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .frame(height: 24)
                    }
                    ForEach(Array(toks.enumerated()), id: \.offset) { i, token in
                        FormulaBubble(token: token) { remove(at: i, in: toks) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !toks.isEmpty {
                    Button { remove(at: toks.count - 1, in: toks) } label: { Image(systemName: "delete.left") }
                        .help(String(localized: "删掉最后一个"))
                    Button { set([]) } label: { Image(systemName: "xmark.circle.fill") }
                        .help(String(localized: "清空"))
                }
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .padding(8)
            .frame(minHeight: 40, alignment: .topLeading)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 6) {
                OperatorButton(symbol: "∩", title: String(localized: "交集（且）")) { add(.and) }
                OperatorButton(symbol: "∪", title: String(localized: "并集（或）")) { add(.or) }
                OperatorButton(symbol: "¬", title: String(localized: "补集（非）")) { add(.not) }
                OperatorButton(symbol: "(", title: nil) { add(.open) }
                OperatorButton(symbol: ")", title: nil) { add(.close) }
            }
            if !tags.isEmpty {
                section(String(localized: "标签"), items: tags.map { "#" + $0 })
            }
            section(String(localized: "App Store 分类"), items: AppCategoryName.Group.allCases.map(AppSearch.categoryToken))
            VStack(alignment: .leading, spacing: 5) {
                Text("名称").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField(String(localized: "名称里的关键词"), text: $keyword)
                        .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 150)
                        .onSubmit(addKeyword)
                    Button(String(localized: "加入"), action: addKeyword)
                        .controlSize(.small)
                        .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func section(_ title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            FlowLayout(spacing: 5) {
                ForEach(items, id: \.self) { item in
                    FormulaBubble(token: .term(item)) { add(.term(item)) }
                }
            }
        }
    }

    private func set(_ toks: [AppSearch.Token]) { query = AppSearch.formulaText(toks) }

    /// Adds at the end; a term, "(" or "¬" right after an operand gets the ∩ it means.
    private func add(_ token: AppSearch.Token) {
        var toks = tokens
        if let last = toks.last, Self.endsOperand(last), Self.startsOperand(token) { toks.append(.and) }
        toks.append(token)
        set(toks)
    }

    private func remove(at index: Int, in toks: [AppSearch.Token]) { set(Self.removing(index, from: toks)) }

    /// The formula without the bubble at `index`, and without what only made sense next to it:
    /// a bracket's partner, the ¬ in front of a term, and one ∩/∪ joining it (the one before
    /// it, so "a ∩ b ∪ c" without b is "a ∪ c").
    static func removing(_ index: Int, from tokens: [AppSearch.Token]) -> [AppSearch.Token] {
        var toks = tokens
        let removed = toks.remove(at: index)
        var i = index
        if removed == .open || removed == .close {
            // Its partner: the bracket that closes (or opens) the same level.
            var depth = 0
            let range: [Int] = removed == .open ? Array(i..<toks.count) : Array((0..<i).reversed())
            for j in range {
                if toks[j] == removed { depth += 1 }
                else if toks[j] == (removed == .open ? .close : .open) {
                    if depth == 0 {
                        toks.remove(at: j)
                        if j < i { i -= 1 }
                        break
                    }
                    depth -= 1
                }
            }
            return toks
        }
        func startsHere() -> Bool { toks.indices.contains(i) && startsOperand(toks[i]) }
        while i > 0, toks[i - 1] == .not, !startsHere() { toks.remove(at: i - 1); i -= 1 }
        let binary: Set<AppSearch.Token> = [.and, .or]
        if i > 0, binary.contains(toks[i - 1]), !startsHere() {
            toks.remove(at: i - 1)
        } else if toks.indices.contains(i), binary.contains(toks[i]), i == 0 || !endsOperand(toks[i - 1]) {
            toks.remove(at: i)
        }
        return toks
    }

    private func addKeyword() {
        let words = keyword.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return }
        for word in words { add(.term(word)) }
        keyword = ""
    }
}

/// One bubble: a term in the accent colour, an operator as a small grey symbol.
private struct FormulaBubble: View {
    let token: AppSearch.Token
    let tap: () -> Void

    var body: some View {
        let isTerm = token.isTerm
        Text(token.text)
            .font(.system(size: isTerm ? 12 : 14, weight: isTerm ? .regular : .semibold))
            .foregroundStyle(isTerm ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            .padding(.horizontal, isTerm ? 9 : 7)
            .frame(minWidth: 24, minHeight: 24)
            .background(isTerm ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.09), in: Capsule())
            .contentShape(Capsule())
            .onTapGesture(perform: tap)
    }
}

private struct OperatorButton: View {
    let symbol: String
    let title: String?
    let tap: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(symbol).font(.system(size: 15, weight: .semibold))
            if let title { Text(title).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: tap)
        .help(title ?? symbol)
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
