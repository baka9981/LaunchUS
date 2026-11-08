import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 添加小组件: every widget there is, built in or from a plugin, each shown live in every size
/// it comes in. Plugins are installed by choosing or dropping a `.launchuswidget` folder.
struct WidgetGallery: View {
    let model: LauncherModel
    private var registry: WidgetRegistry { WidgetRegistry.shared }

    @State private var selection = BuiltInWidget.clock.rawValue
    @State private var size = WidgetItem.Size.small
    @State private var search = ""
    @State private var message: String?
    @State private var dropping = false

    static let docsURL = URL(string: "https://github.com/baka9981/LaunchUS/blob/main/docs/WIDGETS.md")!

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 248)
                .background(Color.primary.opacity(0.035))
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topTrailing) {
            Button { model.sheet = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(String(localized: "关闭"))
            .padding(16)
        }
        .overlay {
            if dropping {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.accentColor.opacity(0.08))
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [9, 6]))
                    Label(String(localized: "松开以安装插件"), systemImage: "puzzlepiece.extension")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Capsule().fill(.regularMaterial))
                }
                .padding(6)
                .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for item in providers {
                _ = item.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { install(url) }
                }
            }
            return true
        }
        .onAppear { size = current?.fit(size) ?? .small }
    }

    private var current: WidgetProvider? { registry.provider(selection) }

    private func select(_ provider: WidgetProvider) {
        selection = provider.id
        size = provider.fit(size)
        message = nil
    }

    // MARK: Sidebar

    private var filtered: [WidgetProvider] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return registry.all }
        return registry.all.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "小组件"))
                .font(.system(size: 22, weight: .bold))
                .padding(.horizontal, 20)
                .padding(.top, 24)
            searchField
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let list = filtered
                    ForEach(BuiltInWidget.Category.allCases, id: \.self) { category in
                        let items = list.filter { $0.category == category }
                        if !items.isEmpty || (category == .plugin && search.isEmpty) {
                            sectionHeader(category.title)
                            ForEach(items) { row($0) }
                        }
                    }
                    if search.isEmpty {
                        if registry.plugins.isEmpty && registry.problems.isEmpty {
                            Text(String(localized: "还没有安装插件。把 .launchuswidget 文件夹拖到这个窗口，或点下面的“安装插件…”。"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                        ForEach(registry.problems, id: \.folder) { problemRow($0) }
                    } else if list.isEmpty {
                        Text(String(localized: "没有找到“\(search)”"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 14)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            Divider()
            VStack(alignment: .leading, spacing: 1) {
                FooterLink(title: String(localized: "安装插件…"), symbol: "plus.circle", action: choosePlugin)
                FooterLink(title: String(localized: "打开插件文件夹"), symbol: "folder") { revealFolder(WidgetRegistry.pluginsFolder) }
                FooterLink(title: String(localized: "插件开发文档"), symbol: "book") { NSWorkspace.shared.open(Self.docsURL) }
            }
            .padding(10)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextField(String(localized: "搜索小组件"), text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { if let first = filtered.first { select(first) } }
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    private func row(_ provider: WidgetProvider) -> some View {
        SidebarRow(provider: provider, selected: provider.id == selection) { select(provider) }
    }

    private func problemRow(_ problem: (folder: String, problem: String)) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.15))
                .frame(width: 26, height: 26)
                .overlay(Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange))
            VStack(alignment: .leading, spacing: 2) {
                Text(problem.folder).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(problem.problem).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let provider = current {
            VStack(alignment: .leading, spacing: 0) {
                header(provider)
                    .padding(.horizontal, 32)
                    .padding(.top, 30)
                stage(provider)
                    .padding(.horizontal, 32)
                    .padding(.top, 22)
                    .padding(.bottom, 22)
                Divider()
                footer(provider)
                    .padding(.horizontal, 24)
                    .frame(height: 64)
            }
        } else {
            Color.clear.onAppear { selection = BuiltInWidget.clock.rawValue }
        }
    }

    private func header(_ provider: WidgetProvider) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                ProviderIcon(provider: provider, side: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.name)
                        .font(.system(size: 22, weight: .bold))
                        .lineLimit(1)
                    Text(meta(provider))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 40)
            }
            if !provider.summary.isEmpty {
                Text(provider.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 540, alignment: .leading)
            }
            if case .plugin(_, let manifest) = provider.source {
                permissions(manifest)
            }
        }
    }

    private func meta(_ provider: WidgetProvider) -> String {
        let sizes = String(localized: "\(provider.sizes.count) 种尺寸")
        switch provider.source {
        case .builtIn: return [String(localized: "系统小组件"), sizes].joined(separator: "  ·  ")
        case .plugin(_, let manifest):
            return [manifest.version.map { String(localized: "版本 \($0)") }, manifest.author, sizes]
                .compactMap { $0 }.joined(separator: "  ·  ")
        }
    }

    private func permissions(_ manifest: WidgetManifest) -> some View {
        HStack(spacing: 6) {
            let online = manifest.permissions.contains(.network)
            chip(online ? String(localized: "可以联网") : String(localized: "不联网"),
                 symbol: online ? "network" : "network.slash", tint: online ? .orange : .green)
            if manifest.permissions.contains(.system) {
                chip(String(localized: "读取系统状态"), symbol: "gauge.with.dots.needle.33percent", tint: .blue)
            }
            Text(verbatim: manifest.id)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .textSelection(.enabled)
                .padding(.leading, 4)
        }
    }

    private func chip(_ title: String, symbol: String, tint: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    /// Every size the widget comes in, side by side and live, over a backdrop like the launcher's.
    private func stage(_ provider: WidgetProvider) -> some View {
        GeometryReader { geo in
            let sizes = provider.sizes
            let pad: CGFloat = 26, caption: CGFloat = 40, gap: CGFloat = 0.4
            let width = geo.size.width - pad * 2, height = geo.size.height - pad * 2
            // A card is (cells - 1) cells plus one icon's art, as on the grid; art is 0.8 of a cell.
            let across = sizes.reduce(0) { $0 + CGFloat($1.cells.width) - 0.2 } + CGFloat(sizes.count - 1) * gap
            let down = sizes.map { CGFloat($0.cells.height) - 0.2 }.max() ?? 1.8
            let inRow = min(width / across, (height - caption) / down)
            // All three: small over medium on the left, large on the right.
            let stacked = sizes.count == 3
            let stackedCell = min(width / (3.8 + gap + 3.8), (height - caption) / 3.8, (height - caption * 2) / (3.6 + gap))
            let cell = min(96, stacked ? stackedCell : inRow)
            ZStack {
                StageBackdrop()
                if stacked {
                    HStack(alignment: .center, spacing: cell * gap) {
                        VStack(alignment: .leading, spacing: cell * gap * 0.6) {
                            preview(provider, size: .small, cell: cell)
                            preview(provider, size: .medium, cell: cell)
                        }
                        preview(provider, size: .large, cell: cell)
                    }
                } else {
                    HStack(alignment: .center, spacing: cell * gap) {
                        ForEach(sizes, id: \.self) { s in
                            preview(provider, size: s, cell: cell)
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func preview(_ provider: WidgetProvider, size s: WidgetItem.Size, cell: CGFloat) -> some View {
        let card = CGSize(width: (CGFloat(s.cells.width) - 0.2) * cell, height: (CGFloat(s.cells.height) - 0.2) * cell)
        let radius = min(card.width, card.height) * 0.12
        let selected = s == size
        return VStack(spacing: 12) {
            WidgetCard(widget: WidgetItem(id: "preview-" + s.rawValue, kind: provider.id, size: s), size: card)
                .environment(\.windowedStyle, false)
                .id(provider.id + s.rawValue)
                .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                .overlay {
                    RoundedRectangle(cornerRadius: radius + 5, style: .continuous)
                        .strokeBorder(Color.white.opacity(selected ? 0.95 : 0), lineWidth: 2.5)
                        .padding(-5)
                }
            HStack(spacing: 5) {
                Text(s.title).fontWeight(.semibold)
                Text(verbatim: "\(s.cells.width)×\(s.cells.height)").opacity(0.7)
            }
            .font(.system(size: 12))
            .foregroundStyle(selected ? Color.black.opacity(0.85) : .white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? Color.white.opacity(0.92) : Color.white.opacity(0.12)))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { add(provider, size: s) }
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { size = s } }
        .help(String(localized: "单击选择这个尺寸，双击直接添加"))
    }

    private func footer(_ provider: WidgetProvider) -> some View {
        HStack(spacing: 10) {
            if case .plugin(let folder, _) = provider.source {
                Button { revealFolder(folder) } label: { Label(String(localized: "在访达中显示"), systemImage: "folder") }
                Button(role: .destructive) {
                    registry.trash(provider)
                    selection = BuiltInWidget.clock.rawValue
                    size = .small
                } label: { Label(String(localized: "移到废纸篓"), systemImage: "trash") }
            }
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if !model.canAddWidget {
                Text(String(localized: "先退出搜索或分类，回到主页再添加。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { add(provider, size: size) } label: {
                Label(String(localized: "添加小组件"), systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canAddWidget)
        }
        .controlSize(.regular)
    }

    // MARK: Actions

    private func add(_ provider: WidgetProvider, size: WidgetItem.Size) {
        guard model.canAddWidget else { return }
        model.sheet = nil
        model.addWidget(provider.id, size: size)
    }

    private func choosePlugin() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "安装")
        panel.message = String(localized: "选择 .launchuswidget 插件文件夹")
        guard Modal.run({ panel.runModal() }) == .OK else { return }
        panel.urls.forEach(install)
    }

    private func install(_ url: URL) {
        if let problem = registry.install(url) {
            message = "\(url.lastPathComponent)：\(problem)"
            return
        }
        message = nil
        search = ""
        if case .success(let manifest) = WidgetManifest.load(url), let provider = registry.provider(manifest.id) {
            select(provider)
        }
    }

    private func revealFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: WidgetRegistry.pluginsFolder, withIntermediateDirectories: true)
        model.onClose?()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// One widget in the sidebar.
private struct SidebarRow: View {
    let provider: WidgetProvider
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ProviderIcon(provider: provider, side: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.name)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                    if case .plugin(_, let manifest) = provider.source, let author = manifest.author {
                        Text(author).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16) : hovering ? Color.primary.opacity(0.05) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The links under the sidebar.
private struct FooterLink: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 18)
                Text(title).font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A dark wallpaper-like backdrop so the widgets look as they will in the launcher.
private struct StageBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.13, green: 0.16, blue: 0.27), Color(red: 0.24, green: 0.16, blue: 0.27)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.75).opacity(0.55), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(red: 0.85, green: 0.45, blue: 0.5).opacity(0.35), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 380)
        }
    }
}

/// A plugin's own picture, or a symbol on a coloured tile.
struct ProviderIcon: View {
    let provider: WidgetProvider
    let side: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
        if let image = provider.icon {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: side, height: side)
                .clipShape(shape)
        } else {
            shape
                .fill(LinearGradient(colors: [tint.top, tint.bottom], startPoint: .top, endPoint: .bottom))
                .frame(width: side, height: side)
                .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .overlay(Image(systemName: provider.symbol)
                    .font(.system(size: side * 0.46, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5))
        }
    }

    private var tint: (top: Color, bottom: Color) {
        if case .builtIn(let kind) = provider.source { return kind.tint }
        return (Color(red: 0.72, green: 0.45, blue: 0.95), Color(red: 0.48, green: 0.25, blue: 0.82))
    }
}
