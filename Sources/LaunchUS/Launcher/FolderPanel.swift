import SwiftUI
import AppKit

enum LiquidGlass {
    /// Clear glass over the wallpaper, like the system's folder tiles; frosted in window mode,
    /// where a clear tile would vanish against the light panel.
    static func style(tint: Color?, windowed: Bool) -> Glass {
        let base: Glass = windowed ? .regular : .clear
        return tint.map { base.tint($0.opacity(0.35)) } ?? base
    }
}

/// The open folder: a rounded panel with an editable name and its own pages.
struct FolderPanel: View {
    let model: LauncherModel
    let metrics: GridMetrics
    let folder: Folder
    let apps: [AppItem]

    @State private var name = ""
    @FocusState private var renaming: Bool
    @Environment(\.windowedStyle) private var windowed
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let rect = metrics.folderPanelRect
        let grid = metrics.folderGridRect
        let perPage = model.folderPerPage
        let pageCount = max(1, (apps.count + perPage - 1) / perPage)
        // Collapsed, the panel sits exactly on the folder's tile; it grows out of it on open.
        let expanded = model.folderExpanded
        let tileSize = metrics.iconSize * 0.8
        let origin = model.folderOrigin ?? CGRect(x: rect.midX - tileSize / 2, y: rect.midY - tileSize / 2,
                                                   width: tileSize, height: tileSize)
        let box = expanded ? rect : origin
        let glass = RoundedRectangle(cornerRadius: expanded ? metrics.folderCornerRadius : origin.width * 0.225,
                                     style: .continuous)
        let contentScale = expanded ? 1 : origin.width / rect.width
        let contentShift = expanded ? CGSize.zero : CGSize(width: origin.midX - rect.midX, height: origin.midY - rect.midY)

        ZStack(alignment: .topLeading) {
            Group {
                if windowed && model.settings.liquidGlass {
                    // Liquid glass floating over the window, light or dark with the system.
                    glass
                        .fill(.clear)
                        .glassEffect(LiquidGlass.style(tint: folder.color.flatMap(FolderColor.init(rawValue:))?.color, windowed: true),
                                     in: glass)
                        .shadow(color: .black.opacity(expanded ? (colorScheme == .dark ? 0.4 : 0.16) : 0), radius: 24, y: 10)
                } else if windowed {
                    // A frosted card floating over the window, as in the system Apps window; its rim
                    // stays a faint highlight in dark mode instead of a bright outline.
                    glass
                        .fill(.thickMaterial)
                        .overlay(glass.strokeBorder(.white.opacity(colorScheme == .dark ? 0.1 : 0.5), lineWidth: 1))
                        .shadow(color: .black.opacity(expanded ? (colorScheme == .dark ? 0.4 : 0.18) : 0), radius: 24, y: 10)
                } else if model.settings.liquidGlass {
                    glass
                        .fill(.black.opacity(expanded ? 0.06 : 0))
                        .glassEffect(LiquidGlass.style(tint: folder.color.flatMap(FolderColor.init(rawValue:))?.color, windowed: false),
                                     in: glass)
                } else {
                    glass
                        .fill(.black.opacity(expanded ? 0.1 : 0.07))
                        .overlay(glass.strokeBorder(.white.opacity(expanded ? 0.16 : 0.3), lineWidth: 1))
                }
            }
                .contentShape(glass)
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { model.dragChanged($0.translation.width) }
                        .onEnded { model.dragEnded($0.translation.width, pageWidth: grid.width) }
                        .exclusively(before: TapGesture().onEnded { renaming = false })
                )
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)

            // Title and dots grow out of the tile with the glass.
            ZStack(alignment: .topLeading) {
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(windowed ? .system(size: 22, weight: .semibold) : .system(size: 26, weight: .light))
                    .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white.opacity(0.78)))
                    .tint(windowed ? .accentColor : .white)
                    .multilineTextAlignment(.center)
                    .focused($renaming)
                    .onSubmit { renaming = false }
                    .frame(width: windowed ? rect.width - 40 : rect.width * 0.4)
                    .position(x: rect.midX, y: metrics.folderTitleCenterY)

                // The folder as an app group: every app in it at once.
                if apps.count >= 2, !model.isEditing {
                    OpenAllButton(windowed: windowed) { model.openAll(folder.id) }
                        .position(x: rect.maxX - 56, y: metrics.folderTitleCenterY)
                }

                if let query = folder.query {
                    Label(query, systemImage: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.5)))
                        .position(x: rect.midX, y: metrics.folderTitleCenterY + 24)
                    if apps.isEmpty {
                        Text("没有符合条件的 App")
                            .font(.system(size: 14))
                            .foregroundStyle(windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.5)))
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)
                    }
                }

                if pageCount > 1 {
                    PageDots(count: pageCount, current: model.folderPage) { model.goToFolderPage($0) }
                        .position(x: rect.midX, y: rect.maxY + 22)
                }
            }
            .frame(width: metrics.size.width, height: metrics.size.height, alignment: .topLeading)
            .scaleEffect(contentScale, anchor: UnitPoint(x: rect.midX / metrics.size.width, y: rect.midY / metrics.size.height))
            .offset(contentShift)
            .opacity(expanded ? 1 : 0)

            // Each icon flies between its mini icon in the folder tile and its own slot, like
            // Launchpad; the clip grows from the tile to the grid along with them.
            let mini = origin.width * 0.232
            let step = origin.width * 0.263
            let miniScale = mini / metrics.iconSize
            let clip = expanded
                ? CGRect(x: grid.minX, y: grid.minY, width: grid.width, height: grid.height + metrics.labelOverflow).intersection(rect)
                : origin
            ZStack(alignment: .topLeading) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { position, app in
                    let page = position / perPage
                    let index = position % perPage
                    let slot = metrics.folderIconCenter(slot: index)
                    let pageShift = model.folderScrolls ? 0 : CGFloat(page - model.folderPage) * grid.width + model.folderDragOffset
                    let scrollShift = model.folderScrolls ? model.folderScrollOffset : 0
                    let inTile = position < 9
                    let target = expanded
                        ? CGPoint(x: slot.x + pageShift, y: slot.y - scrollShift)
                        : inTile
                            ? CGPoint(x: origin.midX + CGFloat(position % 3 - 1) * step,
                                      y: origin.midY + CGFloat(position / 3 - 1) * step)
                            : CGPoint(x: origin.midX, y: origin.midY)
                    let scale = expanded ? 1 : inTile ? miniScale : miniScale * 0.5
                    // Apps scrolled or paged out of the panel aren't drawn: a big folder would
                    // otherwise lay out every one of them on each frame of opening and closing.
                    let open = CGPoint(x: slot.x + pageShift, y: slot.y - scrollShift)
                    if inTile || grid.insetBy(dx: -grid.width, dy: -metrics.cellSize.height).contains(open) {
                    EntryView(
                        entry: .app(app), model: model, metrics: metrics, center: target, folderID: folder.id,
                        selected: model.selection == GridPos(page: page, slot: index), showsLabel: expanded
                    )
                    .frame(maxWidth: metrics.cellSize.width - 8)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaleEffect(scale)
                    // The icon (not the cell with its label) lands on the target.
                    .position(x: target.x, y: target.y + metrics.stackOffset * scale)
                    .opacity(expanded || inTile ? 1 : 0)
                    }
                }
            }
            .frame(width: metrics.size.width, height: metrics.size.height, alignment: .topLeading)
            .nativeContextMenu(at: { point in
                // Only the panel's visible apps; other pages sit outside it.
                guard expanded, grid.contains(point) else { return nil }
                let hit = apps.indices.first { position in
                    let slot = metrics.folderIconCenter(slot: position % perPage)
                    let pageShift = model.folderScrolls ? 0 : CGFloat(position / perPage - model.folderPage) * grid.width + model.folderDragOffset
                    let scrollShift = model.folderScrolls ? model.folderScrollOffset : 0
                    return metrics.cellContains(point, stack: CGPoint(x: slot.x + pageShift, y: slot.y - scrollShift + metrics.stackOffset),
                                                title: apps[position].name)
                }
                return hit.map { EntryView.menu(.app(apps[$0]), folderID: folder.id, model: model) }
            })
            .mask(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: expanded ? metrics.folderCornerRadius : origin.width * 0.225,
                                 style: .continuous)
                    .frame(width: clip.width, height: clip.height)
                    .offset(x: clip.minX, y: clip.minY)
            }
            .onChange(of: model.selection) { _, _ in model.revealFolderSelection() }
        }
        .frame(width: metrics.size.width, height: metrics.size.height, alignment: .topLeading)
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

/// The icon following the pointer while dragging.

/// "全部打开" beside an open folder's name.
private struct OpenAllButton: View {
    let windowed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(String(localized: "全部打开"), systemImage: "square.stack.3d.forward.dottedline")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white.opacity(hovering ? 0.95 : 0.75)))
                .background(Capsule().fill(windowed ? Color.primary.opacity(hovering ? 0.12 : 0.07)
                                                    : Color.white.opacity(hovering ? 0.22 : 0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(String(localized: "打开这个文件夹里的全部 App"))
    }
}
