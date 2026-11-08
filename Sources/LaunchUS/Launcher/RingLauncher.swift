import SwiftUI

/// 圆环: the current page's apps and folders in rings round the pointer, with a search field in
/// the middle. A folder opens as rings of its own, with the way back in the middle; the wheel or a
/// swipe turns pages, and a click anywhere else closes it.
struct RingLauncher: View {
    @Bindable var model: LauncherModel
    @FocusState private var searchFocused: Bool
    @State private var hovered: String?

    var body: some View {
        GeometryReader { geo in
            let entries = self.entries
            let layout = RingLayout(count: entries.count, iconSize: 64 * model.settings.iconScale,
                                    in: geo.size, around: model.ringCenter ?? CGPoint(x: geo.size.width / 2, y: geo.size.height / 2))
            let shown = model.shownAmount
            ZStack(alignment: .topLeading) {
                // A soft shade round the rings so they read on any desktop; a click on it closes.
                RadialGradient(colors: [.black.opacity(0.42), .black.opacity(0.14)],
                               center: UnitPoint(x: layout.center.x / max(geo.size.width, 1), y: layout.center.y / max(geo.size.height, 1)),
                               startRadius: layout.outerRadius * 0.6, endRadius: layout.outerRadius * 1.6)
                    .opacity(shown)
                    .contentShape(Rectangle())
                    .onTapGesture { model.backgroundTapped() }
                    .nativeContextMenu { LauncherMenus.main(model) }

                Group {
                    ForEach(Array(layout.radii.enumerated()), id: \.offset) { _, r in
                        Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1)
                            .frame(width: r * 2, height: r * 2)
                            .position(layout.center)
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.entry.id) { index, item in
                        let p = layout.point(index)
                        RingItem(model: model, entry: item.entry, size: layout.iconSize,
                                 selected: model.selection.map { $0.slot == item.slot && ($0.page == model.currentPage || model.openFolderID != nil) } ?? false,
                                 hovered: $hovered)
                            .position(x: layout.center.x + (p.x - layout.center.x) * (0.35 + 0.65 * shown),
                                      y: layout.center.y + (p.y - layout.center.y) * (0.35 + 0.65 * shown))
                            .animation(model.settings.motion(.spring(response: 0.42, dampingFraction: 0.8), duration: 0.4)
                                .delay(Double(index) * 0.006), value: shown)
                    }
                }
                .id(model.showHiddenApps ? "hidden" : model.openFolderID ?? "page-\(model.currentPage)-\(model.isSearching)")
                .transition(.scale(scale: 0.85).combined(with: .opacity))
                .opacity(shown)

                hub(layout)
                    .position(layout.center)
                    .opacity(shown)
                    .scaleEffect(0.8 + 0.2 * shown)

                if let tip = model.tip, model.isPresented, !model.showSettings {
                    TipToast(model: model, tip: tip, windowed: true)
                        .position(x: layout.center.x,
                                  y: min(geo.size.height - 40, layout.center.y + layout.outerRadius + 36))
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }

                overlays(geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeOut(duration: 0.2), value: model.openFolderID)
            .animation(.easeOut(duration: 0.2), value: model.showHiddenApps)
            .animation(.easeOut(duration: 0.18), value: model.currentPage)
            .animation(.easeOut(duration: 0.18), value: model.sheet)
            .onAppear { model.screenSize = geo.size }
            .onChange(of: geo.size) { _, size in model.screenSize = size }
        }
        .ignoresSafeArea()
        .onChange(of: model.focusRequest) { _, _ in searchFocused = true }
        .transaction { model.settings.animationSpeed.adjust(&$0) }
    }

    /// What sits over the launcher in every mode: the shade under a card (the card is a window of
    /// its own), the click catcher while a tuning panel is open, and the guide and what's new.
    @ViewBuilder
    private func overlays(_ size: CGSize) -> some View {
        if model.sheet != nil {
            Color.black.opacity(0.3)
                .contentShape(Rectangle())
                .onTapGesture { model.dismissSheet() }
                .transition(.opacity)
        }
        if model.showSettings, model.tuner != nil {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.closeSettings() }
        }
        if model.showGuide {
            Color.black.opacity(0.3).contentShape(Rectangle()).transition(.opacity)
            GuideView(model: model)
                .position(x: size.width / 2, y: size.height / 2)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
        } else if model.showWhatsNew {
            Color.black.opacity(0.3)
                .contentShape(Rectangle())
                .onTapGesture { model.finishWhatsNew() }
                .transition(.opacity)
            WhatsNewView(model: model)
                .position(x: size.width / 2, y: size.height / 2)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
    }

    /// The open folder's apps, or the page's apps and folders (widgets and empty cells stay out),
    /// each with the slot it has in the grid so the keyboard selection lines up.
    private var entries: [(entry: GridEntry, slot: Int)] {
        if model.showHiddenApps {
            return model.hiddenApps.enumerated().map { (GridEntry.app($0.element), $0.offset) }
        }
        if let folder = model.openFolder {
            return folder.1.enumerated().map { (GridEntry.app($0.element), $0.offset) }
        }
        let pages = model.pages
        guard !pages.isEmpty else { return [] }
        let page = pages[min(max(0, model.currentPage), pages.count - 1)]
        return page.enumerated().compactMap { slot, entry in
            switch entry {
            case .app, .folder: (entry, slot)
            case .widget, .gap: nil
            }
        }
    }

    /// The middle: the search field (or the way out of a folder), the name under the pointer, and the pages.
    @ViewBuilder
    private func hub(_ layout: RingLayout) -> some View {
        let d = layout.hubRadius * 2
        ZStack {
            // Always dark glass, so the white writing on it reads on light wallpapers too.
            Circle().fill(.ultraThinMaterial)
                .overlay(Circle().fill(.black.opacity(0.35)))
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            VStack(spacing: 6) {
                if model.showHiddenApps {
                    HStack(spacing: 14) {
                        hubButton("chevron.backward.circle.fill", String(localized: "返回")) { model.closeHiddenApps() }
                        hubButton("lock.circle.fill", String(localized: "锁定隐藏的 App")) { model.lockHidden() }
                    }
                    Text("隐藏的 App").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                } else if let folder = model.openFolder {
                    hubButton("chevron.backward.circle.fill", String(localized: "返回")) { model.closeFolder() }
                    RingFolderName(model: model, folder: folder.0)
                        .frame(width: d * 0.72)
                } else {
                    TextField(String(localized: "搜索"), text: $model.query)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .focused($searchFocused)
                        .frame(width: d * 0.72)
                }
                Text(verbatim: hubCaption)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1).frame(width: d * 0.8)
                if model.openFolderID == nil, !model.showHiddenApps, !model.isSearching {
                    // The secret entrance to the hidden apps follows the dots, as on the grid.
                    PageDots(count: model.pageCount, current: model.currentPage,
                             phantom: model.settings.hiddenDotEntrance ? { model.revealHidden() } : nil,
                             pointAtPhantom: model.tip == .hiddenDot) { model.goToPage($0) }
                        .scaleEffect(0.8)
                        .frame(height: 14)
                }
            }
        }
        .frame(width: d, height: d)
        .environment(\.colorScheme, .dark)
    }

    private func hubButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.white).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var hubCaption: String {
        if let hovered, let entry = entries.first(where: { $0.entry.id == hovered })?.entry {
            return entry.title
        }
        if model.showHiddenApps && entries.isEmpty { return String(localized: "没有隐藏的 App") }
        if model.isSearching && entries.isEmpty { return String(localized: "没有找到") }
        return model.openFolderID == nil && !model.showHiddenApps && model.pageCount > 1 ? String(localized: "滚动翻页") : ""
    }
}

/// The open folder's name in the middle, edited in place (右键 › 重命名 starts it focused).
private struct RingFolderName: View {
    let model: LauncherModel
    let folder: Folder
    @State private var name = ""
    @FocusState private var renaming: Bool

    var body: some View {
        TextField("", text: $name)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .tint(.white)
            .focused($renaming)
            .onSubmit { renaming = false }
            .onAppear {
                name = folder.name
                if model.renameOnOpen {
                    model.renameOnOpen = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { renaming = true }
                }
            }
            .onChange(of: renaming) { _, editing in
                model.isRenaming = editing
                if !editing {
                    model.renameFolder(folder.id, to: name)
                    name = model.openFolder?.0.name ?? name
                }
            }
            .onChange(of: model.renameEndRequest) { _, _ in renaming = false }
            .onDisappear {
                if name != folder.name { model.renameFolder(folder.id, to: name) }
                model.isRenaming = false
            }
    }
}

/// One icon on the ring: click to open (a folder opens its own rings), with the running dot and
/// the app's own right-click menu.
private struct RingItem: View {
    let model: LauncherModel
    let entry: GridEntry
    let size: CGFloat
    let selected: Bool
    @Binding var hovered: String?

    var body: some View {
        let isHovered = hovered == entry.id
        let lifted = (isHovered && model.settings.hoverLift) || selected || MenuTarget.shared.id == entry.id
        EntryIcon(entry: entry, icons: model.catalog.icons, size: size)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            .opacity(model.isStale(entry) ? 0.45 : 1)
            .scaleEffect(lifted ? 1.14 : 1)
            .overlay(alignment: .bottom) {
                // Blue until first opened, white while running, as on the grid.
                let isNew = model.isNew(entry)
                if isNew || model.isRunning(entry) {
                    LightStrip(color: isNew ? Color(red: 0.3, green: 0.65, blue: 1) : .white,
                               pulsing: isNew && model.isPresented, windowed: false)
                        .frame(width: size * 0.58, height: 4)
                        .offset(y: 8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let badge = model.badge(entry) {
                    Text(verbatim: badge).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).frame(minWidth: 17, minHeight: 17)
                        .background(Color.red, in: Capsule())
                        .offset(x: 4, y: -4)
                }
            }
            .animation(.easeOut(duration: 0.12), value: lifted)
            .contentShape(Circle().inset(by: -size * 0.1))
            .onHover { inside in
                if inside { hovered = entry.id } else if hovered == entry.id { hovered = nil }
            }
            .onTapGesture { model.activate(entry) }
            .nativeContextMenu { EntryView.menu(entry, folderID: model.openFolderID, model: model) }
            .accessibilityLabel(Text(verbatim: entry.title))
            .accessibilityAddTraits(.isButton)
    }
}

/// Where the icons go: rings out from the middle, each as full as its circumference allows, the
/// last one spread evenly. Big pages shrink the icons so the outer ring stays on screen, and the
/// middle moves in from the edges so the whole ring shows.
struct RingLayout {
    let center: CGPoint
    let iconSize: CGFloat
    let hubRadius: CGFloat
    let radii: [CGFloat]
    private let slots: [(ring: Int, index: Int, count: Int)]

    var outerRadius: CGFloat { (radii.last ?? hubRadius) + iconSize / 2 }

    init(count: Int, iconSize base: CGFloat, in size: CGSize, around point: CGPoint) {
        let room = max(160, min(size.width, size.height) / 2 - 24)
        var s = base
        var plan = Self.plan(count, iconSize: s)
        while plan.outer > room, s > 34 {
            s *= 0.92
            plan = Self.plan(count, iconSize: s)
        }
        iconSize = s
        hubRadius = Self.hubRadius(s)
        radii = plan.radii
        slots = plan.slots
        let reach = min(plan.outer, room) + 8
        center = CGPoint(x: min(max(point.x, reach), size.width - reach),
                         y: min(max(point.y, reach), size.height - reach))
    }

    func point(_ index: Int) -> CGPoint {
        guard slots.indices.contains(index) else { return center }
        let slot = slots[index]
        // Starts at the top and goes clockwise; every other ring is turned half a step so
        // icons don't line up behind each other.
        let turn = slot.ring.isMultiple(of: 2) ? 0 : 0.5
        let angle = (Double(slot.index) + turn) / Double(slot.count) * 2 * .pi - .pi / 2
        let r = radii[slot.ring]
        return CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
    }

    private static func hubRadius(_ s: CGFloat) -> CGFloat { max(58, s * 1.15) }

    private static func plan(_ count: Int, iconSize s: CGFloat) -> (radii: [CGFloat], slots: [(ring: Int, index: Int, count: Int)], outer: CGFloat) {
        var radii: [CGFloat] = []
        var slots: [(ring: Int, index: Int, count: Int)] = []
        var left = count
        var r = hubRadius(s) + s * 0.85
        while left > 0 {
            let fits = max(1, Int((2 * .pi * r) / (s * 1.32)))
            let here = min(fits, left)
            for i in 0..<here { slots.append((radii.count, i, here)) }
            radii.append(r)
            left -= here
            r += s * 1.3
        }
        return (radii, slots, (radii.last ?? hubRadius(s)) + s / 2)
    }
}
