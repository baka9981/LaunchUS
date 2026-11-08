import SwiftUI
import AppKit

struct LauncherView: View {
    @Bindable var model: LauncherModel
    let wallpaper: WallpaperProvider
    @FocusState private var searchFocused: Bool
    /// The drag on empty space in progress is turning pages (not drawing a selection rectangle).
    @State private var dragIsPaging = false

    var body: some View {
        if model.settings.displayMode == .ring {
            RingLauncher(model: model)
                .coordinateSpace(.named(LauncherView.space))
        } else {
            grid
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let folder = model.openFolder
            let settings = model.settings
            let windowed = settings.displayMode == .window
            let metrics = GridMetrics(size: geo.size, columns: model.columns, rows: model.rows,
                                      windowed: windowed, paged: settings.browseStyle == .paged,
                                      frequentRow: model.showsFrequentRow, categoryBar: model.showsCategoryBar,
                                      folderItemCount: folder?.1.count ?? 0, folderHasQuery: folder?.0.query != nil, hideNames: settings.hideNames && settings.hideFolderNames,
                                      iconScale: settings.iconScale)
            ZStack(alignment: .top) {
                Group {
                    if windowed {
                        WindowGlass()
                    } else {
                        BackgroundView(wallpaper: wallpaper, glass: settings.background == .glass,
                                       style: settings.backgroundStyle,
                                       dynamic: settings.background == .dynamic ? settings.dynamicWallpaper : nil,
                                       animating: model.isPresented)
                    }
                }
                    .opacity(model.shownAmount)
                    .gesture(pagingDrag(pageWidth: geo.size.width).exclusively(before: TapGesture().onEnded { model.backgroundTapped() }))
                    .nativeContextMenu { LauncherMenus.main(model) }

                ZStack(alignment: .top) {
                    if model.chat != nil {
                        // The chat card has its own field at the bottom.
                    } else if windowed {
                        WindowHeader(text: $model.query, focused: $searchFocused, chatting: false,
                                     category: model.categoryFilterTitle,
                                     clearCategory: { withAnimation(.easeInOut(duration: 0.22)) { model.categoryFilter = nil } }) { LauncherMenus.main(model, includeSearchItems: true) }
                            .frame(width: metrics.searchSize.width, height: metrics.searchSize.height)
                            .offset(y: metrics.searchCenterY - metrics.searchSize.height / 2)
                        Rectangle().fill(.primary.opacity(0.1))
                            .frame(width: metrics.searchSize.width, height: 1)
                            .offset(y: metrics.headerLineY)
                    } else {
                        SearchField(text: $model.query, focused: $searchFocused, chatting: false,
                                    category: model.categoryFilterTitle,
                                    clearCategory: { withAnimation(.easeInOut(duration: 0.22)) { model.categoryFilter = nil } }) { LauncherMenus.main(model, includeSearchItems: true) }
                            .frame(width: metrics.searchSize.width, height: metrics.searchSize.height)
                            .offset(y: metrics.searchCenterY - metrics.searchSize.height / 2)
                    }
                    if model.showsCategoryBar, model.chat == nil {
                        CategoryBar(model: model, fullScreen: !windowed)
                            .frame(width: windowed ? metrics.searchSize.width : metrics.gridWidth, height: 26)
                            .offset(y: metrics.categoryBarY - 13)
                            .opacity(model.isSearching ? 0 : 1)
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
                            // Another category tab crossfades to a new grid instead of moving the icons.
                            .id(model.categoryFilter ?? "")
                            .transition(.opacity)
                    } else {
                        PagesView(model: model, metrics: metrics)
                            .offset(y: metrics.gridTop)
                            .id(model.categoryFilter ?? "")
                            .transition(.opacity)

                        PageDots(count: model.pageCount, current: model.currentPage,
                                 phantom: settings.hiddenDotEntrance && !model.isSearching ? { model.revealHidden() } : nil,
                                 pointAtPhantom: model.tip == .hiddenDot) {
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

                if let id = model.folderPick, let rect = model.tileRect(ofFolder: id) {
                    let below = rect.minY < 72
                    FolderPickBubble(model: model, windowed: windowed, below: below)
                        .position(x: min(max(rect.midX, 170), geo.size.width - 170),
                                  y: below ? rect.maxY + (metrics.hideNames ? 0 : metrics.labelSize * 1.6) + 28 : rect.minY - 26)
                        .transition(.scale(scale: 0.85, anchor: below ? .top : .bottom).combined(with: .opacity))
                        .zIndex(6)
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

                if model.sheet != nil {
                    // The card itself is a window of its own (`CardWindows`), over this.
                    Color.black.opacity(0.3)
                        .contentShape(Rectangle())
                        .onTapGesture { model.dismissSheet() }
                        .transition(.opacity)
                        .zIndex(10)
                }

                if model.showSettings, model.tuner != nil {
                    // The tuning panel is a window of its own beside this (`CardWindows`). Clear,
                    // so the background and pages show exactly as they'll look; a click ends tuning.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.closeSettings() }
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
            // Empty cells (free placement) draw nothing and take no clicks.
            ForEach(Array(entries.enumerated()).filter { !$0.element.isGap }, id: \.element.id) { slot, entry in
                let center = metrics.iconCenter(slot: slot)
                if let widget = entry.widget {
                    let rect = metrics.widgetRect(slot: slot, span: widget.size.span(columns: metrics.columns, rows: metrics.rows))
                    WidgetCell(widget: widget, model: model, metrics: metrics, rect: rect,
                               selected: model.openFolderID == nil && model.selection == GridPos(page: page, slot: slot))
                        .fixedSize()
                        .position(x: rect.midX, y: rect.minY - metrics.gridTop + WidgetCell.height(rect, metrics) / 2)
                } else {
                EntryView(
                    entry: entry, model: model, metrics: metrics, center: center, folderID: nil,
                    selected: model.openFolderID == nil && model.selection == GridPos(page: page, slot: slot)
                )
                .frame(maxWidth: metrics.cellSize.width - 8)
                .fixedSize(horizontal: false, vertical: true)
                .position(x: center.x, y: center.y - metrics.gridTop + metrics.stackOffset)
                }
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
                guard !entries[slot].isGap else { return false }
                if let widget = entries[slot].widget {
                    let rect = metrics.widgetRect(slot: slot, span: widget.size.span(columns: metrics.columns, rows: metrics.rows))
                    return rect.offsetBy(dx: 0, dy: -metrics.gridTop).contains(point)
                }
                let center = metrics.iconCenter(slot: slot)
                return metrics.cellContains(point, stack: CGPoint(x: center.x, y: center.y - metrics.gridTop + metrics.stackOffset),
                                            title: entries[slot].title)
            }
            return slot.map { EntryView.menu(entries[$0], folderID: nil, model: model) }
        })
    }
}

/// Window mode's soft shadow all round, as the system Apps window gives its icons. Left off
/// entirely in full screen: an invisible shadow on every icon still costs a render pass each.
struct WindowIconShadow: ViewModifier {
    let on: Bool
    let size: CGFloat

    func body(content: Content) -> some View {
        if on {
            content.shadow(color: .black.opacity(0.16), radius: size * 0.05, y: size * 0.025)
        } else {
            content
        }
    }
}

/// Lifts an icon while its right-click menu is open. Only that one icon reads the menu state
/// and gets a shadow: a shadow kept at zero on every icon still costs a render pass each.
struct MenuLift: ViewModifier {
    let id: String
    let size: CGFloat
    var scale: CGFloat = 1.1
    /// Hovering lifts it a little too (when turned on, and not while dragging or jiggling).
    var hoverable = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        let open = MenuTarget.shared.id == id
        let hover = hovering && hoverable && !open
        content
            .background {
                if open || hover {
                    RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                        .fill(.black.opacity(open ? 0.35 : 0.22))
                        .frame(width: size * 0.78, height: size * 0.78)
                        .blur(radius: size * 0.12)
                        .offset(y: size * (open ? 0.07 : 0.05))
                        .transition(.opacity)
                }
            }
            .scaleEffect(open ? scale : hover ? 1 + (scale - 1) * 0.6 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: open)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
            .onHover { hovering = $0 }
            .onDisappear { hovering = false }
    }
}

/// Recently opened apps, under the search field: click to open, right-click for the usual menu.
struct DragOverlay: View {
    let model: LauncherModel
    let metrics: GridMetrics

    var body: some View {
        if model.drag == nil, let landing = model.landing, case .widget(let widget) = landing.item {
            card(widget)
                .scaleEffect(landing.scale)
                .opacity(landing.opacity)
                .position(landing.position)
                .allowsHitTesting(false)
        } else if let drag = model.drag, case .widget(let widget) = drag.item {
            card(widget)
                .scaleEffect(1.04)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
                .position(x: model.dragLocation.x - drag.grabOffset.width,
                          y: model.dragLocation.y - drag.grabOffset.height)
                .allowsHitTesting(false)
        } else if model.drag == nil, let landing = model.landing, let entry = entry(for: landing.item) {
            EntryIcon(entry: entry, icons: model.catalog.icons, size: metrics.iconSize)
                .scaleEffect(landing.scale)
                .opacity(landing.opacity)
                .shadow(color: .black.opacity(max(0, 0.25 * (landing.scale - 1) / 0.08)), radius: 10, y: 6)
                .position(landing.position)
                .allowsHitTesting(false)
        } else if let drag = model.drag, let entry = entry(for: drag.item) {
            let others = drag.companions.prefix(3).compactMap { self.entry(for: $0) }
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

    private func card(_ widget: WidgetItem) -> some View {
        let rect = metrics.widgetRect(first: .zero, span: widget.size.span(columns: metrics.columns, rows: metrics.rows))
        return WidgetCard(widget: widget, size: rect.size, live: false)
    }

    private func entry(for item: LayoutItem) -> GridEntry? {
        switch item {
        case .app(let id):
            return model.catalog.apps.first { $0.id == id }.map(GridEntry.app)
        case .folder(let folder):
            let apps = folder.apps.compactMap { id in model.catalog.apps.first { $0.id == id } }
            return .folder(folder, apps)
        case .widget(let widget): return .widget(widget)
        case .gap, .cover: return nil
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
