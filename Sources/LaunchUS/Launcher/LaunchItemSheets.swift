import AppKit
import SwiftUI

// Cards for launch items, picked icons and layout profiles, shown by `SheetCard`.

/// A web address, file or command shown on the grid like an app.
struct CustomItemEditor: View {
    let model: LauncherModel
    /// `nil` creates a new item.
    let item: CustomItem?

    @State private var kind: CustomItem.Kind = .url
    @State private var name = ""
    @State private var target = ""
    @FocusState private var focus: Int?

    private var trimmedTarget: String { target.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var suggestedName: String {
        switch kind {
        case .url:
            let host = URL(string: trimmedTarget)?.host ?? URL(string: "https://" + trimmedTarget)?.host
            return host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
        case .file:
            return trimmedTarget.isEmpty ? "" : FileManager.default.displayName(atPath: (trimmedTarget as NSString).expandingTildeInPath)
        case .script:
            return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: IconRenderer.tileColors(for: kind == .script ? "terminal.fill" : "globe").1)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item == nil ? String(localized: "新建启动项") : String(localized: "编辑启动项"))
                        .font(.system(size: 17, weight: .semibold))
                    Text("可以像 App 一样放进文件夹、搜索和加标签")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Picker("", selection: $kind) {
                ForEach(CustomItem.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(item != nil)
            FieldRow(label: targetLabel) {
                HStack(spacing: 8) {
                    TextField(targetPlaceholder, text: $target)
                        .textFieldStyle(CardFieldStyle()).focused($focus, equals: 0).onSubmit(save)
                    if kind == .file {
                        Button(String(localized: "选择…"), action: chooseFile)
                    }
                }
                if kind == .script {
                    Text("用 zsh 在后台运行，不会打开终端窗口")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            FieldRow(label: String(localized: "名称")) {
                TextField(suggestedName.isEmpty ? String(localized: "显示在图标下方") : suggestedName, text: $name)
                    .textFieldStyle(CardFieldStyle()).focused($focus, equals: 1).onSubmit(save)
            }
            if let item {
                Button(String(localized: "更换图标…"), systemImage: "photo") {
                    if canSave { store() }
                    model.sheet = .chooseIcon(item.id)
                }
                .controlSize(.small)
            }
            CardButtons(confirmTitle: item == nil ? String(localized: "添加") : String(localized: "存储"),
                        confirmDisabled: !canSave, cancel: { model.sheet = nil }, confirm: save)
        }
        .onAppear {
            if let item {
                kind = item.kind
                name = item.name
                target = item.target
            }
            DispatchQueue.main.async { focus = 0 }
        }
    }

    private var targetLabel: String {
        switch kind {
        case .url: String(localized: "网址")
        case .file: String(localized: "路径")
        case .script: String(localized: "命令")
        }
    }

    private var targetPlaceholder: String {
        switch kind {
        case .url: "https://example.com"
        case .file: "~/Downloads"
        case .script: String(localized: "例如：open ~/Downloads && say 完成")
        }
    }

    private var canSave: Bool {
        guard !trimmedTarget.isEmpty else { return false }
        return !(name.trimmingCharacters(in: .whitespaces).isEmpty && suggestedName.isEmpty)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "选择")
        guard Modal.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        target = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    private func save() {
        guard canSave else { return }
        store()
        model.sheet = nil
    }

    private func store() {
        let typed = name.trimmingCharacters(in: .whitespaces)
        var saved = item ?? CustomItem(kind: kind, name: "", target: "")
        saved.kind = kind
        saved.name = typed.isEmpty ? suggestedName : typed
        saved.target = trimmedTarget
        model.saveCustomItem(saved)
    }
}

/// A picture or SF Symbol instead of an app's own icon, kept in LaunchUS's data only.
struct IconPicker: View {
    let model: LauncherModel
    let app: AppItem

    @State private var failed: String?

    static let symbols = [
        "star.fill", "heart.fill", "bolt.fill", "flame.fill", "leaf.fill", "moon.fill",
        "sun.max.fill", "cloud.fill", "globe", "terminal.fill", "doc.fill", "folder.fill",
        "briefcase.fill", "cart.fill", "gamecontroller.fill", "music.note", "film.fill", "camera.fill",
        "paintbrush.fill", "hammer.fill", "wrench.and.screwdriver.fill", "book.fill", "graduationcap.fill", "chart.bar.fill",
        "message.fill", "envelope.fill", "phone.fill", "person.fill", "house.fill", "gearshape.fill",
    ]

    var body: some View {
        let current = model.meta(for: app.id).icon
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(model: model, app: app, title: String(localized: "更换图标"),
                       subtitle: String(localized: "只在 LaunchUS 里显示，不会修改 App 本身"))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 6), spacing: 8) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    let value = IconRenderer.symbolPrefix + symbol
                    let (top, bottom) = IconRenderer.tileColors(for: symbol)
                    Button { choose(value) } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(LinearGradient(colors: [Color(nsColor: top), Color(nsColor: bottom)], startPoint: .top, endPoint: .bottom)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: current == value ? 2.5 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            if let failed {
                Text(failed).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                Button(String(localized: "选择图片…"), action: chooseImage)
                Button(String(localized: "恢复默认")) { choose(nil) }.disabled(current == nil)
                Spacer()
                // Back to the editor it was opened from.
                Button(String(localized: "完成")) {
                    model.sheet = app.isCustom ? .editCustom(app.id) : .editApp(app.id)
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
    }

    private func choose(_ value: String?) {
        model.setIcon(value, for: app.id)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .icns, .applicationBundle]
        panel.message = String(localized: "选择一张图片，或一个 App 来借用它的图标")
        guard Modal.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        do {
            if url.pathExtension.lowercased() == "app" {
                choose(try CustomIcons.importAppIcon(url))
            } else {
                choose(try CustomIcons.importImage(url))
            }
            failed = nil
        } catch {
            failed = String(localized: "无法使用这个文件：\(error.localizedDescription)")
        }
    }
}

/// A new layout profile: its name, how it's shown and what pages it starts with. Also renames one.
struct ProfileEditor: View {
    let model: LauncherModel
    var renaming: String?
    @State private var name = ""
    @State private var mode = Settings.shared.displayMode
    @State private var copyPages = true
    @State private var source = ""
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var taken: Bool {
        trimmed != renaming && model.profileNames.contains { LayoutProfiles.title($0).localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(model: model, app: nil, title: renaming == nil ? String(localized: "新建布局方案") : String(localized: "重命名布局方案"),
                       subtitle: renaming == nil ? String(localized: "每套方案有自己的显示方式、网格和页面，切换方案时一起切换") : nil)
            FieldRow(label: String(localized: "名称")) {
                TextField(String(localized: "例如：工作"), text: $name)
                    .textFieldStyle(CardFieldStyle()).focused($focused).onSubmit(save)
                Text(taken ? String(localized: "已经有同名的布局") : String(localized: "也可以用链接切换：launchus://profile?name=名称"))
                    .font(.system(size: 11)).foregroundStyle(taken ? .red : .secondary)
            }
            if renaming == nil {
                FieldRow(label: String(localized: "显示方式")) {
                    HStack(spacing: 10) {
                        ForEach(DisplayMode.allCases, id: \.self) { m in
                            DisplayModeCard(mode: m, selected: mode == m, thumbHeight: 64, compact: true) { mode = m }
                        }
                    }
                }
                FieldRow(label: String(localized: "页面")) {
                    Picker("", selection: $copyPages) {
                        Text("复制当前方案的页面").tag(true)
                        Text("按名称重新排列").tag(false)
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                }
                FieldRow(label: String(localized: "设置")) {
                    HStack(spacing: 6) {
                        Text("复制设置自").font(.system(size: 13))
                        MenuPicker(selection: $source, options: model.profileNames) { model.profileLabel($0) }
                    }
                    Text("之后两套方案各改各的。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            CardButtons(confirmTitle: renaming == nil ? String(localized: "创建") : String(localized: "重命名"),
                        confirmDisabled: trimmed.isEmpty || taken || trimmed == renaming,
                        cancel: { model.sheet = nil }, confirm: save)
        }
        .onAppear {
            name = renaming ?? ""
            source = model.currentProfile
            DispatchQueue.main.async { focused = true }
        }
    }

    private func save() {
        guard !trimmed.isEmpty, !taken else { return }
        model.sheet = nil
        if let renaming {
            model.renameProfile(renaming, to: trimmed)
        } else {
            model.createProfile(trimmed, mode: mode, copyPages: copyPages, settingsFrom: source)
        }
    }
}

/// Asks before the ✕ or the menu removes a launch item, the same as for apps.
struct DeleteCustomItemCard: View {
    let model: LauncherModel
    let app: AppItem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CardHeader(model: model, app: app, title: String(localized: "删除「\(app.name)」？"),
                       subtitle: String(localized: "只删除这个启动项，网址、文件或脚本本身不受影响。"))
            CardButtons(confirmTitle: String(localized: "删除"), destructive: true, cancel: { model.sheet = nil }) {
                model.sheet = nil
                model.deleteCustomItem(app.id)
            }
        }
    }
}
