import SwiftUI
import AppKit

struct FrequentRow: View {
    let model: LauncherModel
    let metrics: GridMetrics

    var body: some View {
        let apps = model.frequentApps
        // Grid-sized cells with names, then a line between them and the rest.
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(apps) { app in
                    VStack(spacing: metrics.labelGap) {
                        icon(app)
                        if !metrics.hideNames {
                            Text(app.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .font(.system(size: metrics.labelSize))
                                .foregroundStyle(metrics.windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white.opacity(0.95)))
                                .shadow(color: .black.opacity(metrics.windowed ? 0 : 0.28), radius: 2, y: 0.5)
                        }
                    }
                    .frame(width: metrics.cellSize.width - 8)
                    .offset(y: metrics.stackOffset)
                    .frame(width: metrics.cellSize.width)
                }
                Spacer(minLength: 0)
            }
            .frame(height: metrics.cellSize.height)
            Rectangle()
                .fill(metrics.windowed ? AnyShapeStyle(.primary.opacity(0.1)) : AnyShapeStyle(.white.opacity(0.22)))
                .frame(height: 1)
                .opacity(apps.isEmpty ? 0 : 1)
                .padding(.horizontal, 10)
                .offset(y: metrics.frequentLineY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func icon(_ app: AppItem) -> some View {
                EntryIcon(entry: .app(app), icons: model.catalog.icons, size: metrics.iconSize)
                    .overlay(alignment: .topTrailing) {
                        if let badge = model.badge(.app(app)) {
                            Circle().fill(Color(red: 1, green: 0.23, blue: 0.19))
                                .frame(width: 10, height: 10)
                                .help(badge)
                                .offset(x: -metrics.iconSize * 0.08, y: metrics.iconSize * 0.08)
                        } else if model.frequentPinned.contains(app.id) {
                            PinMark(size: max(13, metrics.iconSize * 0.3))
                                .offset(x: -metrics.iconSize * 0.04, y: metrics.iconSize * 0.04)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.frequentPinned.contains(app.id))
                    .overlay(alignment: .bottom) {
                        if let number = model.frequentShortcutNumber(of: app) {
                            Text(verbatim: "⌘\(number)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(.black.opacity(0.6)))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                                .offset(y: 6)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: metrics.iconSize * 0.18, style: .continuous)
                        .inset(by: metrics.iconSize * 0.1))
                    .scaleEffect(model.dropTargetID == "frequent:" + app.id ? 1.12 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: model.dropTargetID == "frequent:" + app.id)
                    .modifier(MenuLift(id: "frequent:" + app.id, size: metrics.iconSize, scale: 1.12, hoverable: model.settings.hoverLift && model.drag == nil))
                    .help(app.name)
                    .onTapGesture { model.launch(app) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(app.name)
                    .accessibilityValue(model.frequentPinned.contains(app.id) ? String(localized: "已固定") : "")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.launch(app) }
                    .nativeContextMenu { MenuTarget.tag(LauncherMenus.frequent(app, model: model), "frequent:" + app.id) }
                    .modifier(FileDrop(entry: .app(app), model: model, targetID: "frequent:" + app.id))
    }
}

/// The little pin on apps pinned to the recent row.
private struct PinMark: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: size * 0.5, weight: .bold))
            .rotationEffect(.degrees(45))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
    }
}

/// Files dragged from Finder onto an app icon open in that app.
private struct FileDrop: ViewModifier {
    let entry: GridEntry
    let model: LauncherModel
    /// Tells apart the same app in the grid and in the frequent row.
    var targetID: String?

    func body(content: Content) -> some View {
        let id = targetID ?? entry.id
        if case .app(let app) = entry, !app.isCustom {
            content.dropDestination(for: URL.self) { urls, _ in
                model.dropTargetID = nil
                return model.open(urls, with: app)
            } isTargeted: { targeted in
                if targeted { model.dropTargetID = id } else if model.dropTargetID == id { model.dropTargetID = nil }
            }
        } else {
            content
        }
    }
}

/// An app or folder cell: icon + name. Handles click, long press (jiggle) and drag start.
struct EntryView: View {
    let entry: GridEntry
    let model: LauncherModel
    let metrics: GridMetrics
    /// Icon centre in launcher coordinates, used to keep the grab point when dragging.
    let center: CGPoint
    /// The open folder this cell lives in, if any.
    let folderID: String?
    let selected: Bool
    /// False while the cell is flying in or out of a folder tile, where only the icon shows.
    var showsLabel = true

    /// True while the mouse is down on this cell and hasn't moved; resets itself if the gesture is cancelled.
    @GestureState private var pressing = false
    @State private var longPress: DispatchWorkItem?
    @State private var longPressFired = false

    var body: some View {
        let isDragged = model.draggedID == entry.id
        let picked: Bool = if case .app(let app) = entry { model.multiSelection.contains(app.id) } else { false }
        let isNew = model.isNew(entry)
        let running = model.isRunning(entry)
        let folderOpen: Bool = if case .folder(let folder, _) = entry { model.openFolderID == folder.id } else { false }
        VStack(spacing: metrics.labelGap) {
            EntryIcon(entry: entry, icons: model.catalog.icons, size: metrics.iconSize,
                      mergeTarget: model.mergeTargetID == entry.id,
                      contentsOut: folderOpen)
                .opacity(model.isStale(entry) && !model.isEditing ? 0.4 : 1)
                // Only the icon lifts while its right-click menu is open, to show where it came from.
                .modifier(MenuLift(id: entry.id, size: metrics.iconSize,
                                    hoverable: model.settings.hoverLift && model.drag == nil && !model.isEditing && !isDragged))
                // Icons carry ~10% transparent margin; only the visible tile is clickable.
                .contentShape(RoundedRectangle(cornerRadius: metrics.iconSize * 0.18, style: .continuous)
                    .inset(by: metrics.iconSize * 0.1))
                .overlay(alignment: .topLeading) {
                    if model.isEditing, model.settings.deleteBadges, !isDragged, case .app(let app) = entry, app.isRemovable || app.isCustom, !SettingsPanes.isPane(app.id) {
                        DeleteBadge {
                            if app.isCustom { model.sheet = .confirmDeleteCustom(app.id) } else { model.sheet = .confirmTrash(app.id) }
                        }
                            .offset(x: metrics.iconSize * 0.1 - 9, y: metrics.iconSize * 0.1 - 9)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottom) {
                    if isNew || running {
                        // A glowing strip under the artwork: blue until first opened, white while running.
                        let pulsing = isNew && model.isPresented
                            && (folderID != nil ? model.folderExpanded : model.openFolderID == nil)
                        LightStrip(color: isNew ? Color(red: 0.3, green: 0.65, blue: 1) : .white,
                                   pulsing: pulsing, windowed: metrics.windowed)
                            .id(pulsing)
                            .frame(width: metrics.iconSize * 0.58, height: 4)
                            .offset(y: -metrics.iconSize * 0.035)
                            .transition(.opacity.combined(with: .scale(scale: 0.4, anchor: .center)))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let badge = model.badge(entry), model.shortcutNumber(of: entry) == nil, !model.isEditing {
                        Text(verbatim: badge)
                            .font(.system(size: max(11, metrics.iconSize * 0.15), weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, badge.count > 1 ? 6 : 0)
                            .frame(minWidth: max(20, metrics.iconSize * 0.25), minHeight: max(20, metrics.iconSize * 0.25))
                            .background(Capsule().fill(Color(red: 1, green: 0.23, blue: 0.19)))
                            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                            .offset(x: -metrics.iconSize * 0.02, y: metrics.iconSize * 0.04)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let number = model.shortcutNumber(of: entry) {
                        Text(verbatim: "⌘\(number)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.black.opacity(0.55)))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                            .offset(x: -metrics.iconSize * 0.02, y: metrics.iconSize * 0.04)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if picked {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .offset(x: -metrics.iconSize * 0.06, y: -metrics.iconSize * 0.06)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

            if !metrics.hideNames {
                Text(entry.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                .font(.system(size: metrics.labelSize))
                .foregroundStyle(metrics.windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white.opacity(0.95)))
                .shadow(color: .black.opacity(metrics.windowed ? 0 : 0.28), radius: 2, y: 0.5)
                .opacity(showsLabel && !nameHidden ? 1 : 0)
            }
            // No frame(maxWidth:) or contentShape on the stack: either would stretch the
            // clickable area across the whole cell. Only the icon and text are hit.
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if selected || picked || dropTarget {
                let strong = picked || dropTarget
                RoundedRectangle(cornerRadius: metrics.iconSize * 0.2, style: .continuous)
                    .fill(metrics.windowed ? Color.primary.opacity(strong ? 0.14 : 0.09) : .white.opacity(strong ? 0.24 : 0.18))
            }
        }
        .scaleEffect(dropTarget ? 1.08 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dropTarget)
        .brightness(pressing ? -0.3 : 0)
        .modifier(Wiggle(active: model.isEditing && !isDragged, seed: entry.id.utf8.reduce(0) { $0 &+ Int($1) }))
        .opacity(isDragged ? 0 : 1)
        .gesture(pressGesture)
        .modifier(FileDrop(entry: entry, model: model))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(isNew: isNew, running: running))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.activate(entry) }
        // The right-click menu comes from the grid around it (`EntryView.menu`).
    }

    /// The right-click menu of a cell: the picked apps' when it's one of several picked.
    static func menu(_ entry: GridEntry, folderID: String?, model: LauncherModel) -> NSMenu {
        let picked: Bool = if case .app(let app) = entry { model.multiSelection.contains(app.id) } else { false }
        let menu = picked && model.multiSelection.count > 1
            ? LauncherMenus.selection(model)
            : LauncherMenus.entry(entry, model: model, folderID: folderID)
        return MenuTarget.tag(menu, entry.id)
    }

    private var dropTarget: Bool { model.dropTargetID != nil && model.dropTargetID == entry.id }

    /// App and folder names can be hidden separately; the space stays while either shows.
    private var nameHidden: Bool {
        if case .folder = entry { model.settings.hideFolderNames } else { model.settings.hideNames }
    }

    private func accessibilityLabel(isNew: Bool, running: Bool) -> String {
        var parts = [entry.title]
        if case .folder(_, let apps) = entry { parts.append(String(localized: "文件夹，\(apps.count) 个 App")) }
        if isNew { parts.append(String(localized: "新安装")) }
        if running { parts.append(String(localized: "正在运行")) }
        if model.isStale(entry) { parts.append(String(localized: "很久没有打开")) }
        return parts.joined(separator: String(localized: "，"))
    }

    /// One gesture for press highlight, click, long press and drag, so a drag never also clicks.
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(LauncherView.space))
            .updating($pressing) { value, state, _ in
                state = Self.distance(value) < 5 && model.drag == nil
            }
            .onChanged { value in
                // Once dragging, the controller follows the pointer.
                guard model.drag == nil, !model.dragJustEnded else { return }
                if Self.distance(value) < 5 {
                    guard longPress == nil, !model.isSearching else { return }
                    longPressFired = false
                    let work = DispatchWorkItem {
                        longPressFired = true
                        withAnimation { model.isEditing = true }
                    }
                    longPress = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
                } else {
                    longPress?.cancel()
                    longPress = nil
                    model.beginDrag(entry, inFolder: folderID, pointer: value.location, iconCenter: center)
                }
            }
            .onEnded { value in
                longPress?.cancel()
                longPress = nil
                defer { longPressFired = false }
                // The drag itself is finished by the controller's mouse-up monitor.
                guard Self.distance(value) < 5, !longPressFired, model.drag == nil, !model.dragJustEnded else { return }
                if let flag = model.settings.multiSelectKey.flag, NSEvent.modifierFlags.contains(flag),
                   case .app(let app) = entry {
                    model.toggleMultiSelect(app.id)
                    return
                }
                model.activate(entry)
            }
    }

    private static func distance(_ value: DragGesture.Value) -> CGFloat {
        hypot(value.translation.width, value.translation.height)
    }
}

extension GridEntry {
    var title: String {
        switch self {
        case .app(let app): app.name
        case .folder(let folder, _): folder.name
        case .widget(let widget): WidgetCard.title(widget)
        case .gap: ""
        }
    }
}

/// The square part of a cell: the app icon, or a folder tile with a 3 × 3 preview.
struct EntryIcon: View {
    let entry: GridEntry
    let icons: [String: CGImage]
    let size: CGFloat
    var mergeTarget = false
    /// The folder is open: its apps are flying out of (or back into) the tile, so the tile is empty.
    var contentsOut = false
    @Environment(\.windowedStyle) private var windowed

    var body: some View {
        let tile = size * 0.8
        ZStack {
            switch entry {
            case .app(let app):
                if mergeTarget {
                    // Hovering an app over another one previews the folder it would make.
                    FolderBackground(size: tile).scaleEffect(1.18)
                }
                // Settings panes show System Settings' icon.
                if let icon = icons[app.id] ?? (SettingsPanes.isPane(app.id) ? icons[SettingsPanes.settingsAppID] : nil) {
                    Image(decorative: icon, scale: 2).resizable().interpolation(.high)
                        .frame(width: size, height: size)
                        // Window mode: the soft shadow all round that the system Apps window gives its icons.
                        .modifier(WindowIconShadow(on: windowed, size: size))
                        .scaleEffect(mergeTarget ? 0.82 : 1)
                        .id(ObjectIdentifier(icon))
                        .transition(.opacity)
                } else {
                    RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous).fill(.white.opacity(0.12))
                        .frame(width: tile, height: tile)
                }
            case .folder(let folder, let apps):
                FolderBackground(size: tile, tint: folder.color.flatMap(FolderColor.init(rawValue:)))
                    .overlay {
                        // Visible mini icons are 19% of the tile, 26.3% apart.
                        let mini = tile * 0.232
                        let gap = tile * 0.031
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(mini), spacing: gap), count: 3), spacing: gap) {
                            ForEach(apps.prefix(9)) { app in
                                if let icon = icons[app.id] {
                                    ZStack {
                                        Image(decorative: icon, scale: 2).resizable().interpolation(.medium)
                                            .id(ObjectIdentifier(icon))
                                            .transition(.opacity)
                                    }
                                    .frame(width: mini, height: mini)
                                } else {
                                    Color.clear.frame(width: mini, height: mini)
                                }
                            }
                        }
                        .frame(width: mini * 3 + gap * 2, height: mini * 3 + gap * 2, alignment: .top)
                        .opacity(contentsOut ? 0 : 1)
                    }
                    .scaleEffect(mergeTarget ? 1.12 : 1)
            case .widget(let widget):
                // A widget shrunk to an icon (search results never show one).
                RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous).fill(.white.opacity(0.18))
                    .frame(width: tile, height: tile)
                    .overlay(Image(systemName: WidgetRegistry.shared.provider(widget.kind)?.symbol ?? "puzzlepiece.extension").font(.system(size: tile * 0.45)).foregroundStyle(.white))
            case .gap:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
    }
}

struct FolderBackground: View {
    let size: CGFloat
    var tint: FolderColor?
    @Environment(\.windowedStyle) private var windowed

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if Settings.shared.liquidGlass {
                // Liquid glass: bends and brightens whatever is behind the tile.
                shape
                    .fill(tint.map { AnyShapeStyle($0.color.opacity(0.18)) } ?? AnyShapeStyle(.clear))
                    .glassEffect(LiquidGlass.style(tint: tint?.color, windowed: windowed), in: shape)
            } else {
                // Smoked glass with a thin rim that catches light at the top.
                shape
                    .fill(tint.map { AnyShapeStyle($0.color.opacity(0.45)) } ?? AnyShapeStyle(.black.opacity(0.07)))
                    .overlay(shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.14), .white.opacity(0.26)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1))
            }
        }
        .frame(width: size, height: size)
    }
}
