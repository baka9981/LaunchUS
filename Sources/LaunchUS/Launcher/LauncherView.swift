import SwiftUI
import AppKit

/// Grid geometry derived from the screen size, following the classic Launchpad layout:
/// icon centres every 12.5% of the width starting at
/// 12.5%, rows every 15.9% of the height starting at 17.7%, visible icon art 6% of the width.
struct GridMetrics: Equatable {
    let size: CGSize
    let columns: Int
    let rows: Int
    var folderColumns: Int { columns }
    var folderRows: Int { rows }
    /// Window mode: a compact glass panel styled after macOS's own Apps window.
    var windowed = false
    var paged = true
    /// Room for the recently-opened row between the search field and the grid.
    var frequentRow = false

    var searchCenterY: CGFloat { windowed ? 38 : (size.height * 0.0615).rounded() }
    var searchSize: CGSize {
        windowed ? CGSize(width: size.width - 40, height: 48)
            : CGSize(width: max(240, size.width * 0.14).rounded(), height: max(32, size.height * 0.033).rounded())
    }
    /// Window mode: centre of the category tabs under the header.
    var categoryBarY: CGFloat { 96 }
    /// Vertical centre of the page dots.
    var dotsY: CGFloat { windowed ? size.height - 18 : size.height * 0.929 }
    var gridWidth: CGFloat { windowed ? size.width - 40 : size.width * 0.875 }
    var gridOriginX: CGFloat { (size.width - gridWidth) / 2 }
    /// Height taken by the recently-opened row; the grid moves down and its rows get shorter.
    var frequentHeight: CGFloat { frequentRow ? (windowed ? 56 : (size.height * 0.075).rounded()) : 0 }
    /// Centre of the recently-opened row.
    var frequentCenterY: CGFloat { gridTop - frequentHeight / 2 }
    var frequentIconSize: CGFloat { (frequentHeight * (windowed ? 0.86 : 0.8)).rounded() }
    var cellSize: CGSize {
        let height = windowed
            ? ((size.height - gridTop - (paged ? 34 : 8)) / CGFloat(rows)).rounded(.down)
            : (size.height * 0.159 * 5 - frequentHeight) / CGFloat(rows)
        return CGSize(width: gridWidth / CGFloat(columns), height: height)
    }
    /// Centre of the first row's icons; the grid view starts half a row above it.
    var firstIconCenterY: CGFloat { size.height * 0.177 }
    var gridTop: CGFloat {
        (windowed ? 124 : (firstIconCenterY - size.height * 0.159 * 5 / CGFloat(rows) / 2).rounded()) + frequentHeight
    }
    var gridHeight: CGFloat { cellSize.height * CGFloat(rows) }
    /// Frame of the icon image. macOS icons leave ~10% transparent margin on each side,
    /// so the visible artwork is 80% of this, i.e. 6% of the screen width.
    /// Larger settings may grow into the cell's spare room, but never past it or into the label.
    var iconSize: CGFloat {
        let s = iconScale
        return windowed
            ? min(80 * s, cellSize.width * min(0.6 * s, 0.85), cellSize.height * min(0.66 * s, hideNames ? 0.9 : 0.8)).rounded()
            : min(size.width * 0.075 * s, cellSize.width * min(0.62 * s, 0.9), cellSize.height * min(0.72 * s, hideNames ? 0.95 : 0.84)).rounded()
    }
    var labelSize: CGFloat { windowed ? 12 : 13 }
    /// Space between the icon frame and the label (the icon's own margin adds ~10% more).
    var labelGap: CGFloat { (iconSize * 0.02).rounded() }
    /// How far the icon+label stack's centre sits below the icon's centre.
    var stackOffset: CGFloat { hideNames ? 0 : (labelGap + labelSize * 1.25) / 2 }

    /// Whether `point` falls on a cell (icon and name) placed at `stack`, its `.position`.
    func cellContains(_ point: CGPoint, stack: CGPoint, scale: CGFloat = 1) -> Bool {
        let width = (cellSize.width - 8) * scale
        let height = (iconSize + 16 + (hideNames ? 0 : labelGap + labelSize * 1.25)) * scale
        return abs(point.x - stack.x) <= width / 2 && abs(point.y - stack.y) <= height / 2
    }

    /// Icon centre of a home-grid slot, in launcher coordinates.
    func iconCenter(slot: Int) -> CGPoint {
        CGPoint(
            x: gridOriginX + (CGFloat(slot % columns) + 0.5) * cellSize.width,
            y: gridTop + (CGFloat(slot / columns) + 0.5) * cellSize.height
        )
    }

    // Folder panel: as wide as the home grid, icons on the home
    // columns and row pitch, height fitted to its rows (up to 5), centred at 51% height,
    // name floating above the panel.
    var folderItemCount = 0
    var hideNames = false
    /// The icon size setting, 1 being the default.
    var iconScale: CGFloat = 1
    var folderVisibleRows: Int { min(folderRows, max(1, (folderItemCount + folderColumns - 1) / folderColumns)) }
    /// Panel top to the first row's icon centre.
    var folderIconInset: CGFloat { windowed ? (cellSize.height / 2 - 12).rounded() : (size.height * 0.0735).rounded() }
    var folderCornerRadius: CGFloat { windowed ? 26 : (size.width * 0.025).rounded() }
    var folderPanelRect: CGRect {
        let h = (CGFloat(folderVisibleRows) * cellSize.height + (windowed ? 32 : size.height * 0.01)).rounded()
        return CGRect(x: gridOriginX, y: (size.height * 0.51 - h / 2).rounded(), width: gridWidth, height: h)
    }
    var folderTitleCenterY: CGFloat { folderPanelRect.minY - (windowed ? 28 : (size.height * 0.04).rounded()) }
    var folderGridRect: CGRect {
        let panel = folderPanelRect
        return CGRect(x: panel.minX, y: panel.minY + folderIconInset - cellSize.height / 2,
                      width: panel.width, height: CGFloat(folderVisibleRows) * cellSize.height)
    }
    /// Icon centre of a slot on the current folder page, in launcher coordinates.
    func folderIconCenter(slot: Int) -> CGPoint {
        let grid = folderGridRect
        let s = slot
        return CGPoint(
            x: grid.minX + (CGFloat(s % folderColumns) + 0.5) * cellSize.width,
            y: grid.minY + (CGFloat(s / folderColumns) + 0.5) * cellSize.height
        )
    }
}

struct LauncherView: View {
    @Bindable var model: LauncherModel
    let wallpaper: WallpaperProvider
    @FocusState private var searchFocused: Bool
    /// The drag on empty space in progress is turning pages (not drawing a selection rectangle).
    @State private var dragIsPaging = false

    var body: some View {
        GeometryReader { geo in
            let folder = model.openFolder
            let settings = model.settings
            let windowed = settings.displayMode == .window
            let metrics = GridMetrics(size: geo.size, columns: model.columns, rows: model.rows,
                                      windowed: windowed, paged: settings.browseStyle == .paged,
                                      frequentRow: settings.showFrequent,
                                      folderItemCount: folder?.1.count ?? 0, hideNames: settings.hideNames && settings.hideFolderNames,
                                      iconScale: settings.iconScale)
            ZStack(alignment: .top) {
                Group {
                    if windowed {
                        WindowGlass()
                    } else {
                        BackgroundView(wallpaper: wallpaper, glass: settings.background == .glass,
                                       glassStrength: settings.glassStrength, dim: settings.dim)
                    }
                }
                    .opacity(model.shownAmount)
                    .gesture(pagingDrag(pageWidth: geo.size.width).exclusively(before: TapGesture().onEnded { model.backgroundTapped() }))
                    .nativeContextMenu { LauncherMenus.main(model) }

                ZStack(alignment: .top) {
                    if model.chat != nil {
                        // The chat card has its own field at the bottom.
                    } else if windowed {
                        WindowHeader(text: $model.query, focused: $searchFocused, chatting: false) { LauncherMenus.main(model, includeSearchItems: true) }
                            .frame(width: metrics.searchSize.width, height: metrics.searchSize.height)
                            .offset(y: metrics.searchCenterY - metrics.searchSize.height / 2)
                        Rectangle().fill(.primary.opacity(0.1))
                            .frame(width: metrics.searchSize.width, height: 1)
                            .offset(y: 66)
                        CategoryBar(model: model)
                            .frame(width: metrics.gridWidth, height: 30)
                            .offset(y: metrics.categoryBarY - 15)
                            .opacity(model.isSearching ? 0 : 1)
                    } else {
                        SearchField(text: $model.query, focused: $searchFocused, chatting: false) { LauncherMenus.main(model, includeSearchItems: true) }
                            .frame(width: metrics.searchSize.width, height: metrics.searchSize.height)
                            .offset(y: metrics.searchCenterY - metrics.searchSize.height / 2)
                    }

                    if settings.showFrequent {
                        FrequentRow(model: model, metrics: metrics)
                            .frame(width: metrics.gridWidth, height: metrics.frequentHeight)
                            .offset(y: metrics.frequentCenterY - metrics.frequentHeight / 2)
                            .opacity(model.isSearching ? 0 : 1)
                            .allowsHitTesting(!model.isSearching && !model.isEditing)
                            .animation(.easeOut(duration: 0.15), value: model.isSearching)
                    }

                    TagBar(model: model)
                        .opacity(model.chat == nil ? 1 : 0)
                        .frame(width: geo.size.width * 0.8)
                        .offset(y: windowed ? metrics.categoryBarY - 12 : metrics.searchCenterY + metrics.searchSize.height / 2 + 10)
                        .zIndex(1)

                    if model.chat != nil {
                        // The conversation takes the grid's place.
                    } else if settings.browseStyle == .scroll {
                        ScrollGrid(model: model, metrics: metrics)
                            .offset(y: metrics.gridTop)
                    } else {
                        PagesView(model: model, metrics: metrics)
                            .offset(y: metrics.gridTop)

                        PageDots(count: model.pageCount, current: model.currentPage,
                                 phantom: settings.hiddenDotEntrance && !model.isSearching ? { model.revealHidden() } : nil) {
                            model.goToPage($0)
                        }
                            .position(x: geo.size.width / 2, y: metrics.dotsY)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                // Window mode keeps the grid faintly behind the folder card, like the system Apps window.
                .blur(radius: windowed && model.folderExpanded ? 12 : 0)
                .opacity(model.folderExpanded || model.showHiddenApps ? (windowed ? 0.35 : 0) : 1)
                .allowsHitTesting(folder == nil && !model.showHiddenApps)
                .scaleEffect(1.1 - 0.1 * model.shownAmount)
                .opacity(model.shownAmount)

                if let rect = model.marquee {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                        .zIndex(4)
                }

                if let result = model.calculation {
                    CalculationCard(result: result, windowed: windowed) { model.copyCalculation() }
                        .position(x: geo.size.width / 2, y: metrics.gridTop + metrics.cellSize.height * 0.6)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .zIndex(3)
                }

                if let chat = model.chat {
                    // From where the search field was down to the page dots, as wide as reads well.
                    let top = max(16, metrics.searchCenterY - metrics.searchSize.height / 2)
                    let height = min(1000, max(320, metrics.dotsY - 8 - top))
                    let width = min(980, max(560, geo.size.width - 96))
                    ChatCard(chat: chat, windowed: windowed, width: width, height: height,
                             query: $model.query, focused: $searchFocused,
                             send: { model.sendChat() },
                             ask: { text in model.query = text; model.sendChat() },
                             openSettings: { model.openSettings(.ai) },
                             newChat: { model.newChat() }, close: { model.exitChat() })
                        .position(x: geo.size.width / 2, y: top + height / 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                        .zIndex(3)
                }

                if let text = model.fallbackQuery {
                    FallbackCard(text: text, engine: model.settings.searchEngine.title, windowed: windowed,
                                 web: { model.searchWeb() }, finder: { model.searchFinder() },
                                 ai: model.canAskAI ? { model.startChat() } : nil)
                        .position(x: geo.size.width / 2, y: metrics.gridTop + metrics.cellSize.height * 0.6)
                        .transition(.opacity)
                        .zIndex(3)
                }

                if let files = fileResults(metrics) {
                    FileResultsCard(files: files.list, text: model.query, windowed: windowed,
                                    open: { model.openFile($0) }, reveal: { model.revealFile($0) },
                                    showAll: { model.searchFilesInFinder() })
                        .position(x: geo.size.width / 2, y: files.y)
                        .transition(.opacity)
                        .zIndex(3)
                }

                if model.dragOutHint {
                    NoticeToast(text: String(localized: "拖到屏幕底边，可放到程序坞、访达或其他 App"), windowed: windowed)
                        .position(x: geo.size.width / 2, y: metrics.dotsY - 44)
                        .transition(.opacity)
                        .zIndex(5)
                } else if let tip = model.tip, model.isPresented {
                    TipToast(model: model, tip: tip, windowed: windowed)
                        .position(x: geo.size.width / 2, y: metrics.dotsY - 44)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                        .zIndex(5)
                } else if let notice = model.notice, model.isPresented {
                    NoticeToast(text: notice, windowed: windowed)
                        .position(x: geo.size.width / 2, y: metrics.dotsY - 44)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                        .zIndex(5)
                }

                if let folder {
                    Color.black.opacity(model.folderExpanded ? (windowed ? 0.06 : 0.28) : 0)
                        .contentShape(Rectangle())
                        .onTapGesture { model.closeFolder() }
                        .zIndex(10)
                    FolderPanel(model: model, metrics: metrics, folder: folder.0, apps: folder.1)
                        .id(folder.0.id)
                        .zIndex(10)
                }

                if model.showHiddenApps {
                    Color.black.opacity(windowed ? 0.06 : 0.28)
                        .contentShape(Rectangle())
                        .onTapGesture { model.closeHiddenApps() }
                        .transition(.opacity)
                        .zIndex(10)
                    HiddenAppsPanel(model: model, metrics: metrics)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .zIndex(10)
                }

                if let sheet = model.sheet {
                    Color.black.opacity(0.3)
                        .contentShape(Rectangle())
                        .onTapGesture { model.dismissSheet() }
                        .transition(.opacity)
                        .zIndex(10)
                    SheetCard(model: model, sheet: sheet)
                        .id(sheet)
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.42)
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                        .zIndex(10)
                }

                if model.showSettings {
                    Color.black.opacity(0.2)
                        .contentShape(Rectangle())
                        .onTapGesture { model.closeSettings() }
                        .transition(.opacity)
                        .zIndex(10)
                    SettingsView(model: model, settings: settings, actions: model.settingsActions,
                                 height: min(700, geo.size.height - 60))
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                        .zIndex(10)
                }

                DragOverlay(model: model, metrics: metrics)
                    .zIndex(11)

                if model.showGuide {
                    Color.black.opacity(0.3)
                        .contentShape(Rectangle())
                        .transition(.opacity)
                        .zIndex(12)
                    GuideView(model: model)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                        .zIndex(12)
                } else if model.showWhatsNew {
                    Color.black.opacity(0.3)
                        .contentShape(Rectangle())
                        .onTapGesture { model.finishWhatsNew() }
                        .transition(.opacity)
                        .zIndex(12)
                    WhatsNewView(model: model)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                        .zIndex(12)
                }
            }
            .animation(.easeOut(duration: 0.18), value: model.sheet)
            .clipShape(RoundedRectangle(cornerRadius: windowed ? LauncherView.windowCornerRadius : 0, style: .continuous))
            .overlay {
                if windowed {
                    RoundedRectangle(cornerRadius: LauncherView.windowCornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                        .opacity(model.shownAmount)
                        .allowsHitTesting(false)
                }
            }
            .environment(\.windowedStyle, windowed)
            .coordinateSpace(.named(LauncherView.space))
            .onAppear { model.screenSize = geo.size }
            .onChange(of: geo.size) { _, size in model.screenSize = size }
        }
        .ignoresSafeArea()
        .onChange(of: model.focusRequest) { _, _ in searchFocused = true }
        .task(id: model.isPresented && model.settings.searchFiles && model.spaceList == nil && model.chat == nil ? model.query : "") {
            let text = model.isPresented && model.settings.searchFiles && model.spaceList == nil && model.chat == nil ? model.query : ""
            if text.isEmpty { FileSearch.shared.stop(); return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            FileSearch.shared.search(text)
        }
        .transaction { model.settings.animationSpeed.adjust(&$0) }
    }

    static let space = "launcher"

    /// Spotlight's files, offered only when no app matched — under the web/Finder choices.
    private func fileResults(_ metrics: GridMetrics) -> (list: [FoundFile], y: CGFloat)? {
        let search = FileSearch.shared
        guard model.fallbackQuery != nil, model.settings.searchFiles, model.openFolderID == nil,
              !search.results.isEmpty, search.text == model.query.trimmingCharacters(in: .whitespaces) else { return nil }
        let height = CGFloat(search.results.count) * 39 + 44
        let top = metrics.gridTop + metrics.cellSize.height * 0.6 + 64
        guard top + height < metrics.dotsY - 20 else { return nil }
        return (search.results, top + height / 2)
    }

    /// Whether a drag on empty space should pick apps rather than turn pages.
    private var wantsMarquee: Bool {
        guard model.settings.browseStyle == .paged, model.openFolderID == nil, !model.isSearching else { return false }
        if model.isEditing { return true }
        guard let flag = model.settings.multiSelectKey.flag else { return false }
        return NSEvent.modifierFlags.contains(flag)
    }
    static let windowCornerRadius: CGFloat = 30

    /// Click-and-drag on empty space flips pages, like Launchpad. With the multi-select key
    /// held, or while the icons jiggle, it draws a rectangle that picks apps instead.
    private func pagingDrag(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(LauncherView.space))
            .onChanged { value in
                // Decided when the drag starts, and kept until it ends.
                if model.marquee != nil || (!dragIsPaging && wantsMarquee) {
                    model.marqueeChanged(from: value.startLocation, to: value.location)
                } else if model.settings.browseStyle == .paged {
                    dragIsPaging = true
                    model.dragChanged(value.translation.width)
                }
            }
            .onEnded { value in
                dragIsPaging = false
                if model.marquee != nil { model.marqueeEnded(); return }
                guard model.settings.browseStyle == .paged else { return }
                // A quick flick counts as a full swipe.
                let projected = value.translation.width + (value.predictedEndTranslation.width - value.translation.width) * 0.5
                model.dragEnded(projected, pageWidth: pageWidth)
            }
    }
}

struct PagesView: View {
    let model: LauncherModel
    let metrics: GridMetrics

    var body: some View {
        let pages = model.pages
        let width = metrics.size.width
        HStack(spacing: 0) {
            ForEach(pages.indices, id: \.self) { page in
                // Only the current page and its neighbours are ever on screen while paging.
                if abs(page - model.currentPage) <= 1 {
                    PageGrid(entries: pages[page], page: page, model: model, metrics: metrics,
                             phantomSlot: model.phantomSlotPage == page)
                        .equatable()
                } else {
                    Color.clear.frame(width: width, height: metrics.gridHeight)
                }
            }
        }
        .frame(width: width * CGFloat(pages.count), height: metrics.gridHeight, alignment: .leading)
        .offset(x: -CGFloat(model.currentPage) * width + model.dragOffset)
        .frame(width: width, height: metrics.gridHeight, alignment: .leading)
    }
}

struct PageGrid: View, Equatable {
    let entries: [GridEntry]
    let page: Int
    let model: LauncherModel
    let metrics: GridMetrics
    /// Show the secret empty slot after the last entry.
    var phantomSlot = false

    /// Lets SwiftUI skip re-rendering the grid while only the paging offset changes.
    nonisolated static func == (a: PageGrid, b: PageGrid) -> Bool {
        a.page == b.page && a.metrics == b.metrics && a.model === b.model && a.entries == b.entries
            && a.phantomSlot == b.phantomSlot
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { slot, entry in
                let center = metrics.iconCenter(slot: slot)
                EntryView(
                    entry: entry, model: model, metrics: metrics, center: center, folderID: nil,
                    selected: model.openFolderID == nil && model.selection == GridPos(page: page, slot: slot)
                )
                .frame(maxWidth: metrics.cellSize.width - 8)
                .fixedSize(horizontal: false, vertical: true)
                .position(x: center.x, y: center.y - metrics.gridTop + metrics.stackOffset)
            }
            if phantomSlot {
                let center = metrics.iconCenter(slot: entries.count)
                PhantomSlot(model: model, metrics: metrics)
                    .position(x: center.x, y: center.y - metrics.gridTop)
            }
        }
        .frame(width: metrics.size.width, height: metrics.gridHeight, alignment: .topLeading)
        .nativeContextMenu(at: { point in
            // Empty space falls through to the background's menu.
            let slot = entries.indices.first { slot in
                let center = metrics.iconCenter(slot: slot)
                return metrics.cellContains(point, stack: CGPoint(x: center.x, y: center.y - metrics.gridTop + metrics.stackOffset))
            }
            return slot.map { EntryView.menu(entries[$0], folderID: nil, model: model) }
        })
    }
}

/// Recently opened apps, under the search field: click to open, right-click for the usual menu.
struct FrequentRow: View {
    let model: LauncherModel
    let metrics: GridMetrics

    var body: some View {
        let apps = model.frequentApps
        HStack(spacing: max(8, metrics.frequentIconSize * 0.3)) {
            ForEach(apps) { app in
                EntryIcon(entry: .app(app), icons: model.catalog.icons, size: metrics.frequentIconSize)
                    .overlay(alignment: .topTrailing) {
                        if let badge = model.badge(.app(app)) {
                            Circle().fill(Color(red: 1, green: 0.23, blue: 0.19))
                                .frame(width: 10, height: 10)
                                .help(badge)
                                .offset(x: -metrics.frequentIconSize * 0.08, y: metrics.frequentIconSize * 0.08)
                        } else if model.frequentPinned.contains(app.id) {
                            PinMark(size: max(13, metrics.frequentIconSize * 0.3))
                                .offset(x: -metrics.frequentIconSize * 0.04, y: metrics.frequentIconSize * 0.04)
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
                    .contentShape(RoundedRectangle(cornerRadius: metrics.frequentIconSize * 0.18, style: .continuous)
                        .inset(by: metrics.frequentIconSize * 0.1))
                    .scaleEffect(model.dropTargetID == "frequent:" + app.id ? 1.15 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: model.dropTargetID == "frequent:" + app.id)
                    .help(app.name)
                    .onTapGesture { model.launch(app) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(app.name)
                    .accessibilityValue(model.frequentPinned.contains(app.id) ? String(localized: "已固定") : "")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.launch(app) }
                    .nativeContextMenu { LauncherMenus.frequent(app, model: model) }
                    .modifier(FileDrop(entry: .app(app), model: model, targetID: "frequent:" + app.id))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: metrics.frequentHeight * 0.96)
        .background {
            if !apps.isEmpty {
                Capsule().fill(metrics.windowed ? Color.primary.opacity(0.05) : .white.opacity(0.1))
                    .overlay(Capsule().strokeBorder(metrics.windowed ? Color.primary.opacity(0.06) : .white.opacity(0.14), lineWidth: 0.75))
                    .nativeContextMenu { LauncherMenus.frequent(nil, model: model) }
            }
        }
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
                RoundedRectangle(cornerRadius: metrics.iconSize * 0.2, style: .continuous)
                    .fill(metrics.windowed ? Color.primary.opacity(picked || dropTarget ? 0.14 : 0.09) : .white.opacity(picked || dropTarget ? 0.24 : 0.18))
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
        return picked && model.multiSelection.count > 1
            ? LauncherMenus.selection(model)
            : LauncherMenus.entry(entry, model: model, folderID: folderID)
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
                        .scaleEffect(mergeTarget ? 0.82 : 1)
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
                                    Image(decorative: icon, scale: 2).resizable().interpolation(.medium)
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
                if windowed {
                    // A light frosted card floating over the window, as in the system Apps window.
                    glass
                        .fill(.thickMaterial)
                        .overlay(glass.strokeBorder(.white.opacity(0.5), lineWidth: 1))
                        .shadow(color: .black.opacity(expanded ? 0.18 : 0), radius: 24, y: 10)
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
                    .frame(width: rect.width * 0.4)
                    .position(x: rect.midX, y: metrics.folderTitleCenterY)

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
            let clip = expanded ? grid.intersection(rect) : origin
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
                    return metrics.cellContains(point, stack: CGPoint(x: slot.x + pageShift, y: slot.y - scrollShift + metrics.stackOffset))
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
struct DragOverlay: View {
    let model: LauncherModel
    let metrics: GridMetrics

    var body: some View {
        if let drag = model.drag, let entry = entry(for: drag.item) {
            let others = drag.companions.prefix(3).compactMap { self.entry(for: LayoutItem.app($0)) }
            ZStack {
                // The rest of the selection, fanned out behind the grabbed icon.
                ForEach(Array(others.enumerated().reversed()), id: \.offset) { i, other in
                    EntryIcon(entry: other, icons: model.catalog.icons, size: metrics.iconSize)
                        .rotationEffect(.degrees(Double(i + 1) * (i.isMultiple(of: 2) ? 6 : -6)))
                        .offset(x: CGFloat(i + 1) * 5, y: CGFloat(i + 1) * -4)
                        .opacity(0.9)
                }
                EntryIcon(entry: entry, icons: model.catalog.icons, size: metrics.iconSize)
            }
            .overlay(alignment: .topTrailing) {
                if !drag.companions.isEmpty {
                    Text("\(drag.companions.count + 1)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(Capsule().fill(Color.red))
                        .offset(x: -metrics.iconSize * 0.02, y: metrics.iconSize * 0.04)
                }
            }
            .scaleEffect(1.08)
            .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
            .position(x: model.dragLocation.x - drag.grabOffset.width,
                      y: model.dragLocation.y - drag.grabOffset.height)
            .allowsHitTesting(false)
        }
    }

    private func entry(for item: LayoutItem) -> GridEntry? {
        switch item {
        case .app(let id):
            return model.catalog.apps.first { $0.id == id }.map(GridEntry.app)
        case .folder(let folder):
            let apps = folder.apps.compactMap { id in model.catalog.apps.first { $0.id == id } }
            return .folder(folder, apps)
        }
    }
}

/// Jiggle mode: a small continuous rock, slightly out of phase per icon.
struct Wiggle: ViewModifier {
    let active: Bool
    let seed: Int

    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([false, true]) { view, phase in
                view.rotationEffect(.degrees(phase ? 1.6 : -1.6))
            } animation: { _ in
                .easeInOut(duration: 0.12 + Double(seed % 5) * 0.01)
            }
        } else {
            content
        }
    }
}

/// The "滚动" browse style: every page's items in one continuous, vertically scrolling grid.
struct ScrollGrid: View {
    let model: LauncherModel
    let metrics: GridMetrics

    var body: some View {
        let flat: [(pos: GridPos, entry: GridEntry)] = model.pages.enumerated().flatMap { page, entries in
            entries.enumerated().map { (GridPos(page: page, slot: $0.offset), $0.element) }
        }
        let rowCount = max(1, (flat.count + metrics.columns - 1) / metrics.columns)
        let height = metrics.size.height - metrics.gridTop - metrics.size.height * 0.03
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: 1, height: 1).id("top")
                    ForEach(Array(flat.enumerated()), id: \.element.entry.id) { index, item in
                        let x = metrics.gridOriginX + (CGFloat(index % metrics.columns) + 0.5) * metrics.cellSize.width
                        let y = (CGFloat(index / metrics.columns) + 0.5) * metrics.cellSize.height
                        EntryView(
                            entry: item.entry, model: model, metrics: metrics,
                            center: CGPoint(x: x, y: y + metrics.gridTop), folderID: nil,
                            selected: model.openFolderID == nil && model.selection == item.pos
                        )
                        .frame(maxWidth: metrics.cellSize.width - 8)
                        .fixedSize(horizontal: false, vertical: true)
                        .position(x: x, y: y + metrics.stackOffset)
                        .id(item.entry.id)
                    }
                }
                .frame(width: metrics.size.width, height: CGFloat(rowCount) * metrics.cellSize.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { model.backgroundTapped() }
                // This grid covers the background, so empty space shows the background's menu.
                .nativeContextMenu(at: { point in
                    let index = flat.indices.first { index in
                        let x = metrics.gridOriginX + (CGFloat(index % metrics.columns) + 0.5) * metrics.cellSize.width
                        let y = (CGFloat(index / metrics.columns) + 0.5) * metrics.cellSize.height
                        return metrics.cellContains(point, stack: CGPoint(x: x, y: y + metrics.stackOffset))
                    }
                    return index.map { EntryView.menu(flat[$0].entry, folderID: nil, model: model) } ?? LauncherMenus.main(model)
                })
            }
            .frame(width: metrics.size.width, height: height)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                         .init(color: .black, location: 0.95), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: model.scrollToTopRequest) { _, _ in proxy.scrollTo("top", anchor: .top) }
            .onChange(of: model.selection) { _, pos in
                guard let pos, let item = flat.first(where: { $0.pos == pos }) else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(item.entry.id) }
            }
        }
    }
}

/// A short bar of light with a soft glow, like an LED strip.
private struct LightStrip: View {
    let color: Color
    let pulsing: Bool
    let windowed: Bool
    @State private var bright = true

    var body: some View {
        let core = windowed && color == .white ? Color.primary.opacity(0.6) : color
        Capsule()
            .fill(LinearGradient(colors: [core.opacity(0), core, core, core.opacity(0)],
                                 startPoint: .leading, endPoint: .trailing))
            .overlay(Capsule().fill(.white.opacity(0.85)).frame(height: 1.5).padding(.horizontal, 8))
            .shadow(color: core.opacity(bright ? 1 : 0.55), radius: bright ? 5 : 3)
            .shadow(color: core.opacity(bright ? 0.75 : 0.3), radius: bright ? 12 : 6)
            .opacity(bright ? 1 : 0.7)
            .onAppear {
                guard pulsing else { return }
                bright = false
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { bright = true }
            }
            .allowsHitTesting(false)
    }
}

/// A capsule message that fades in above the page dots.
/// The answer to a sum or unit conversion typed into search. Click or Return copies it.
private struct CalculationCard: View {
    let result: Calculator.Result
    let windowed: Bool
    let copy: () -> Void

    var body: some View {
        Button(action: copy) {
            VStack(spacing: 6) {
                Text(verbatim: result.expression)
                    .font(.system(size: 15))
                    .foregroundStyle(windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.7)))
                Text(verbatim: result.display)
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                    .lineLimit(1).minimumScaleFactor(0.4)
                Text("按 ↩ 或点按复制结果")
                    .font(.system(size: 12))
                    .foregroundStyle(windowed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.white.opacity(0.55)))
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
            .frame(width: SearchCard.width)
            .background(windowed ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.black.opacity(0.35)),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(windowed ? 0 : 0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(result.expression) \(result.display)"))
    }
}

/// The cards under the search field (sum, nothing found, files, AI chat) share one width so they line up.
enum SearchCard {
    static let width: CGFloat = 580
}

/// Search found nothing: ask AI (↩) when it is set up, search the web (↩, or ⇥ with AI) or Finder (⌘↩).
private struct FallbackCard: View {
    let text: String
    let engine: String
    let windowed: Bool
    let web: () -> Void
    let finder: () -> Void
    /// Set when AI is configured.
    let ai: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Text("没有找到「\(text)」")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.75)))
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 10) {
                if let ai {
                    choice(String(localized: "问 AI"), symbol: "sparkles", key: "↩", action: ai)
                }
                choice(String(localized: "用 \(engine) 搜索"), symbol: "globe", key: ai == nil ? "↩" : "⇥", action: web)
                choice(String(localized: "在访达中搜索"), symbol: "magnifyingglass", key: "⌘↩", action: finder)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .frame(width: SearchCard.width)
        .background(windowed ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.black.opacity(0.35)),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(windowed ? 0 : 0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    private func choice(_ title: String, symbol: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                Text(title).lineLimit(1)
                Text(verbatim: key).foregroundStyle(windowed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.white.opacity(0.5)))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(windowed ? AnyShapeStyle(Color.primary.opacity(0.07)) : AnyShapeStyle(.white.opacity(0.14)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct NoticeToast: View {
    let text: String
    let windowed: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(windowed ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.black.opacity(0.45)), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(windowed ? 0 : 0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
