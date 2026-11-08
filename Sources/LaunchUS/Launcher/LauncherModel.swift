import AppKit
import SwiftUI
import Observation

/// One cell as shown on screen: an app, or a folder with its resolved apps.
/// One cell of the scrolling grid.
struct ScrollCell: Equatable {
    var pos: GridPos?
    var entry: GridEntry
}

enum GridEntry: Identifiable, Equatable {
    case app(AppItem)
    case folder(Folder, [AppItem])
    /// An empty cell left by free placement; the string tells cells apart.
    case gap(String)
    case widget(WidgetItem)

    var id: String {
        switch self {
        case .app(let app): "app:" + app.id
        case .folder(let folder, _): "folder:" + folder.id
        case .gap(let key): "gap:" + key
        case .widget(let widget): "widget:" + widget.id
        }
    }

    var widget: WidgetItem? {
        if case .widget(let w) = self { return w }
        return nil
    }

    var isGap: Bool {
        if case .gap = self { return true }
        return false
    }

    static func == (a: GridEntry, b: GridEntry) -> Bool {
        switch (a, b) {
        case (.app(let x), .app(let y)): x.id == y.id && x.name == y.name
        case (.folder(let x, let xa), .folder(let y, let ya)): x == y && xa == ya
        case (.gap(let x), .gap(let y)): x == y
        case (.widget(let x), .widget(let y)): x == y
        default: false
        }
    }
}

/// A card shown over the launcher: editors and confirmations.
enum LauncherSheet: Hashable {
    case editApp(String)
    /// 编辑智能栏, on that smart folder; a `nil` folder ID starts a new one from the query.
    case editSmartFolder(String?, query: String)
    case confirmTrash(String)
    /// The info card of an app.
    case appInfo(String)
    /// `nil` creates a new launch item.
    case editCustom(String?)
    case confirmDeleteCustom(String)
    case chooseIcon(String)
    case newProfile
    case renameProfile(String)
    /// The global shortcut that opens every app in a folder.
    case folderShortcut(String)
    /// The App manager: sizes, chips, updates and usage statistics.
    case manager
    case message(title: String, text: String, revealPath: String?)
    /// Choosing a widget to add: the built-in ones and installed plugins.
    case widgetGallery
    /// A photo widget's picture and its blur, colour and texture.
    case photoWidget(String)
    /// The apps a frequent-apps or app group widget shows, picked by hand.
    case widgetApps(String)

    /// The manager and the smart bar editor: big cards that take most of the launcher.
    var isLarge: Bool {
        switch self {
        case .manager, .editSmartFolder, .widgetGallery: true
        default: false
        }
    }
}

struct GridPos: Equatable {
    var page: Int
    var slot: Int
}

/// An icon being dragged. The pointer is tracked by the controller (not the SwiftUI gesture),
/// because the view that started the drag can disappear mid-drag (e.g. leaving a folder).
/// A dropped icon on its way into place; see `LauncherModel.land`.
struct DragLanding {
    let item: LayoutItem
    var position: CGPoint
    var scale: CGFloat
    var opacity: Double
}

struct DragSession {
    var item: LayoutItem
    /// Set while the app is still being rearranged inside this open folder.
    var folderID: String?
    /// Pointer position minus the icon centre at the moment the drag started.
    var grabOffset: CGSize
    /// Other ⌘-selected apps and folders carried along; they are lifted out of the layout while dragging.
    var companions: [LayoutItem] = []
}

@MainActor @Observable
final class LauncherModel {
    let catalog: AppCatalog
    let settings: Settings
    /// On a portrait screen the grid turns on its side (7 × 5 becomes 5 × 7), so a page
    /// holds the same apps without squeezing seven narrow columns across.
    var columns: Int { portrait ? min(settings.columns, settings.rows) : settings.columns }
    var rows: Int { portrait ? max(settings.columns, settings.rows) : settings.rows }
    /// The launcher is taller than it is wide.
    private(set) var portrait = false
    var folderColumns: Int { columns }
    var folderRows: Int { metrics.folderRows }
    var perPage: Int { columns * rows }
    /// Scrolling folders keep all their apps on one tall page.
    var folderScrolls: Bool { settings.folderBrowseStyle == .scroll }
    var folderPerPage: Int { folderScrolls ? 100_000 : folderColumns * folderRows }

    // MARK: Persistent state
    var layout: [[LayoutItem]] = []
    var meta: [String: AppMeta] = [:] {
        didSet {
            catalog.iconOverrides = Self.iconOverrides(meta)
            HotKeyGroup.apps.update(meta.compactMapValues(\.shortcut))
        }
    }
    @ObservationIgnored private var layoutLoaded = false
    /// The grid the layout was last arranged for, to tell when it changed shape.
    @ObservationIgnored var laidOutColumns = 0
    @ObservationIgnored var laidOutRows = 0
    private var laidOutPerPage: Int { laidOutColumns * laidOutRows }

    /// Installed apps minus hidden ones, with display names applied. Rebuilt by `refresh()`.
    private(set) var visibleApps: [AppItem] = []
    /// Every tag in use, most used first.
    private(set) var allTags: [String] = []
    var sheet: LauncherSheet? {
        didSet { if sheet == nil { sheetParent = nil } }
    }
    /// Where closing the current card goes back to (the App manager, for an app opened from it).
    var sheetParent: LauncherSheet?
    /// Open the next folder with its name already being edited.
    var renameOnOpen = false

    // MARK: Display state
    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    /// Space in the empty search field: one of the "猜你想找 / 最近使用 / 最常使用" lists.
    var spaceList: SpaceShortcut? {
        didSet { if spaceList != oldValue { spaceListChanged() } }
    }
    var isSearching: Bool { !query.isEmpty || spaceList != nil }
    /// A conversation with AI in place of the apps; the search field writes its messages.
    var chat: ChatSession?
    /// Hidden apps were verified for this session: they show in their panel and in search.
    var hiddenUnlocked = false
    var showHiddenApps = false
    /// The secret slot is showing its dashed outline and can be clicked.
    var phantomSlotArmed = false
    @ObservationIgnored var phantomDisarm: DispatchWorkItem?
    /// The first-run walkthrough.
    var showGuide = false
    /// The walkthrough's card. Kept here, not in the view: picking 圆环 there swaps the
    /// launcher's whole view, and the walkthrough with it.
    // Debug aid: LAUNCHUS_SHEET=guide:<step> opens the walkthrough at that step.
    var guideStep = ProcessInfo.processInfo.environment["LAUNCHUS_SHEET"]
        .flatMap { $0.hasPrefix("guide:") ? Int($0.dropFirst(6)) : nil } ?? 0
    /// The "新功能" card after an upgrade (see `WhatsNew`).
    var showWhatsNew = false
    /// A one-time hint over the page dots (see `Tip`).
    var tip: Tip?
    /// Newly installed apps not opened yet (blue dot before the name).
    var newAppIDs: Set<String> = []
    @ObservationIgnored var newApps: NewApps.State?
    /// Running apps (dot under the icon), kept up to date by the controller.
    var runningIDs: Set<String> = []
    /// Dock badge text by app ID, kept up to date by the controller while visible.
    var badges: [String: String] = [:]
    /// ⌘ held: number the first nine items so ⌘1…⌘9 open them.
    var showShortcutNumbers = false
    /// Touch ID / password prompt is up; the launcher must not close meanwhile.
    @ObservationIgnored var isAuthenticating = false
    /// What the grid shows: the layout, or search results while searching.
    private(set) var pages: [[GridEntry]] = [[]]
    /// The scrolling grid: every page's items run together and packed again as one long page,
    /// with the page and cell each came from (nil for empty cells).
    var scrollCells: [ScrollCell] = []
    var currentPage = 0 {
        didSet { if currentPage != oldValue { folderPick = nil } }
    }
    var selection: GridPos?
    /// Live horizontal offset while a swipe or mouse drag is in progress.
    var dragOffset: CGFloat = 0
    var isPresented = false
    /// 圆环: where the pointer was when the launcher opened, from the panel's top left.
    var ringCenter: CGPoint?
    /// Set while a trackpad pinch is opening or closing the launcher: how shown it is, 0…1.
    var gestureProgress: Double?
    /// How shown the launcher is, following a pinch in progress.
    var shownAmount: Double { gestureProgress ?? (isPresented ? 1 : 0) }
    /// Bumped each time the search field should take focus.
    var focusRequest = 0
    /// Jiggle mode: entered by long press or by holding ⌥.
    var isEditing = false {
        didSet { if isEditing, !oldValue { offerTip(.dragOut) } }
    }
    @ObservationIgnored var editingFromOption = false
    /// Apps picked with ⌘-click (or the chosen modifier), acted on together.
    var multiSelection: Set<String> = []
    /// A folder clicked with the multi-select key, asking whether to pick it or open it (`multiSelectClick`).
    var folderPick: String?
    /// The rectangle being dragged out on empty space to pick apps, in launcher coordinates.
    var marquee: CGRect?
    /// What was picked before the rectangle started; the rectangle adds to it.
    @ObservationIgnored var marqueeBase: Set<String>?
    /// Icons can be dragged around only in the custom, paged arrangement.
    var canRearrange: Bool { settings.sortOrder == .custom && categoryFilter == nil }

    /// Window mode's category tabs: nil shows everything.
    var categoryFilter: String? {
        didSet {
            guard categoryFilter != oldValue else { return }
            currentPage = 0
            selection = nil
            scrollToTopRequest += 1
            refresh()
        }
    }

    /// An app's App Store category group, for "@…" conditions: the one the user moved it to,
    /// else its developer's.
    func appGroup(_ app: AppItem) -> AppCategoryName.Group {
        meta[app.id]?.group.flatMap(AppCategoryName.Group.init(rawValue:)) ?? AppCategoryName.group(for: app.category)
    }

    /// Every smart folder as a tab, shown or not, in the order the user arranged them. The bar
    /// holds nothing else: the system's categories come in as smart folders ("导入系统分类").
    var allCategoryTabs: [(key: String, title: String)] {
        let all = smartFolders.map { (key: Self.smartTabPrefix + $0.id, title: $0.name) }
        let order = settings.categoryTabOrder
        return all.enumerated().sorted { a, b in
            (order.firstIndex(of: a.element.key) ?? order.count + a.offset) < (order.firstIndex(of: b.element.key) ?? order.count + b.offset)
        }.map(\.element)
    }

    /// Window mode, like the system Apps window: a picked category replaces the tab row with its
    /// name in the header, so the bar only shows while nothing is picked.
    var showsCategoryBar: Bool {
        // With no tab to show there's no empty row either.
        !categoryTabs.isEmpty && !(settings.displayMode == .window && categoryFilter != nil)
    }

    /// The picked smart folder's name.
    var categoryFilterTitle: String? {
        categoryFilter.flatMap { key in allCategoryTabs.first { $0.key == key }?.title }
    }

    /// The apps a tab shows: what its smart folder finds.
    func categoryApps(_ key: String) -> [AppItem] {
        smartFolder(forTab: key).map { apps(in: $0) } ?? []
    }

    func smartFolder(forTab key: String) -> Folder? {
        guard key.hasPrefix(Self.smartTabPrefix) else { return nil }
        let id = String(key.dropFirst(Self.smartTabPrefix.count))
        return smartFolders.first { $0.id == id }
    }

    /// The tabs the bar shows.
    var categoryTabs: [(key: String, title: String)] {
        guard settings.showCategoryBar else { return [] }
        let hidden = Set(settings.hiddenCategoryTabs)
        return allCategoryTabs.filter { !hidden.contains($0.key) }
    }

    func setCategoryTab(_ key: String, hidden: Bool) {
        var keys = settings.hiddenCategoryTabs.filter { $0 != key }
        if hidden { keys.append(key) }
        settings.hiddenCategoryTabs = keys
        if hidden, categoryFilter == key { categoryFilter = nil }
    }

    /// Puts the tabs in this order (keys of `allCategoryTabs`).
    func setCategoryTabOrder(_ keys: [String]) {
        settings.categoryTabOrder = keys
    }

    /// Moves apps to another App Store category for "@…" conditions; nil puts them back under
    /// their developer's.
    func setCategory(_ group: AppCategoryName.Group?, for ids: [String]) {
        for id in ids { setMeta(id) { $0.group = group?.rawValue } }
        refresh()
    }

    /// Whether any smart folder picks apps by App Store category, so moving an app between
    /// categories means something.
    var usesCategoryConditions: Bool {
        smartFolders.contains { !AppSearch.categories(in: $0.query ?? "").groups.isEmpty }
    }

    /// The App Store categories that have apps and no smart folder of their own yet.
    var importableCategories: [AppCategoryName.Group] {
        let present = Set(visibleApps.map(appGroup))
        let taken = Set(smartFolders.compactMap { folder -> AppCategoryName.Group? in
            let (groups, rest) = AppSearch.categories(in: folder.query ?? "")
            return groups.count == 1 && rest.isEmpty ? groups[0] : nil
        })
        return AppCategoryName.Group.allCases.filter { present.contains($0) && !taken.contains($0) }
    }

    /// One smart folder per App Store category ("@开发者工具"), shown only in the smart bar.
    /// Their contents follow the condition, so apps installed later join on their own.
    func importSystemCategories() {
        let groups = importableCategories
        guard !groups.isEmpty else { return }
        barFolders += groups.map { Folder(name: $0.title, apps: [], query: AppSearch.categoryToken($0)) }
        LayoutStore.save(barFolders: barFolders)
        if !settings.showCategoryBar { settings.showCategoryBar = true }
        refresh()
    }

    /// Smart folders get a tab of their own in the smart bar.
    static let smartTabPrefix = "smart:"
    /// Smart folders that show only in the smart bar, not on the pages.
    var barFolders: [Folder] = []
    /// Every smart folder: those on the pages, then the bar-only ones.
    var smartFolders: [Folder] {
        layout.joined().compactMap { if case .folder(let folder) = $0, folder.isSmart { folder } else { nil } } + barFolders
    }

    func isOnPages(_ folderID: String) -> Bool { !barFolders.contains { $0.id == folderID } }

    /// Moves a smart folder between the pages and the smart bar alone.
    func setSmartFolder(_ id: String, onPages: Bool) {
        if onPages, let index = barFolders.firstIndex(where: { $0.id == id }) {
            let folder = barFolders.remove(at: index)
            LayoutStore.save(barFolders: barFolders)
            if layout.isEmpty { layout = [[]] }
            layout[layout.count - 1].append(.folder(folder))
            commitLayout()
        } else if !onPages, let loc = location(ofFolder: id), case .folder(let folder) = layout[loc.page][loc.slot], folder.isSmart {
            barFolders.append(folder)
            LayoutStore.save(barFolders: barFolders)
            if openFolderID == id { dropFolder() }
            vacate(page: loc.page, slot: loc.slot)
            commitLayout()
        }
    }
    @ObservationIgnored var lastHidden = Date.distantPast

    // MARK: Folder panel
    var openFolderID: String?
    /// Animated separately from `openFolderID`: the panel is inserted collapsed onto the
    /// folder's tile, then expands; on close it collapses back before it is removed.
    var folderExpanded = false
    /// The open folder's tile on the home grid, in launcher coordinates.
    var folderOrigin: CGRect?
    /// How far the scrolling grid is scrolled, for finding a folder's tile in it.
    @ObservationIgnored var gridScrollOffset: CGFloat = 0
    /// Height of the recent row at the top of the scrolling grid, when it shows.
    var scrollLead: CGFloat {
        showsFrequentRow && !frequentApps.isEmpty && !isSearching && categoryFilter == nil ? metrics.frequentHeight : 0
    }
    @ObservationIgnored var folderToken = 0
    var folderPage = 0
    var folderDragOffset: CGFloat = 0
    /// How far a scrolling folder is scrolled down, in points.
    var folderScrollOffset: CGFloat = 0
    var isRenaming = false
    var renameEndRequest = 0
    /// The note widget being typed on.
    var editingNoteID: String?
    /// Bumped on each launch, so the frequent apps widget redraws.
    var widgetLaunches = 0

    // MARK: Dragging
    var drag: DragSession?
    /// The icon just let go of, gliding from the pointer to where it landed.
    var landing: DragLanding?
    /// Pointer location during a drag, in launcher coordinates. Only the floating icon reads it.
    var dragLocation: CGPoint = .zero
    /// The dragged icon is near the bottom edge, where it can be dragged out of the launcher.
    var dragOutHint = false
    var mergeTargetID: String?
    @ObservationIgnored var screenSize: CGSize = .zero {
        didSet {
            let tall = screenSize.height > screenSize.width
            if tall != portrait { portrait = tall }
            clampFolderScroll()
            revealFolderSelection()
        }
    }
    @ObservationIgnored var pendingMove: (key: String, work: DispatchWorkItem)?
    @ObservationIgnored var edgeWork: DispatchWorkItem?
    /// Scrolls the scrolling grid while a held icon rests at its top or bottom edge.
    @ObservationIgnored var edgeScroll: Timer?
    /// Where the scrolling grid should scroll to (content offset), for the edge scroll.
    var gridScrollRequest: CGFloat?

    /// Items of the search field's "⋯" menu, supplied by the controller.
    @ObservationIgnored var menuItems: [(title: String, action: () -> Void)] = []
    @ObservationIgnored var onLaunch: ((AppItem) -> Void)?
    /// Opens files dropped on an app icon with that app.
    @ObservationIgnored var onOpenFiles: (([URL], AppItem) -> Void)?
    /// Opens several apps at once (a folder's "全部打开").
    @ObservationIgnored var onOpenGroup: (([AppItem]) -> Void)?
    /// The app icon a file drag is hovering over, highlighted until the drop.
    var dropTargetID: String?
    @ObservationIgnored var onClose: (() -> Void)?
    /// The settings card over the launcher.
    var showSettings = false
    /// A tuning panel shown in the settings card's place, so its changes can be watched on the launcher itself.
    var tuner: Tuner?
    var settingsTab: SettingsTab = .profiles
    @ObservationIgnored var settingsActions = SettingsActions(rescan: { _ in })
    /// A short message shown above the page dots, e.g. after a rescan.
    var notice: String?
    @ObservationIgnored private var noticeID = 0

    func showNotice(_ text: String, for seconds: Double = 2.5) {
        noticeID += 1
        let id = noticeID
        withAnimation(.easeOut(duration: 0.2)) { self.notice = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, noticeID == id else { return }
            withAnimation(.easeIn(duration: 0.3)) { self.notice = nil }
        }
    }

    init(catalog: AppCatalog, settings: Settings? = nil) {
        self.catalog = catalog
        self.settings = settings ?? .shared
        meta = LayoutStore.loadMeta()
        WidgetHost.model = self
        barFolders = LayoutStore.loadBarFolders()
        customItems = CustomItemStore.load()
        catalog.customApps = customItems.map(\.appItem)
        catalog.iconOverrides = Self.iconOverrides(meta)
        followProfile()
        if ProfileSettings.addPresenceKeys(&profiles, names: LayoutProfiles.names(profiles)) { LayoutProfiles.save(profiles) }
    }

    /// Points the profile's own files and AI key at the active profile.
    func followProfile() {
        ProfileFolders.current = profiles.current
        AIKey.profile = profiles.current
    }

    private static func iconOverrides(_ meta: [String: AppMeta]) -> [String: String] {
        meta.compactMapValues { $0.icon.map(CustomIcons.path(for:)) }
    }

    var pageCount: Int { max(1, pages.count) }
    var metrics: GridMetrics {
        GridMetrics(size: screenSize, columns: columns, rows: rows, windowed: settings.displayMode == .window,
                    paged: settings.pageStyle == .paged, frequentRow: showsFrequentRow, categoryBar: showsCategoryBar, folderItemCount: openFolder?.1.count ?? 0, folderHasQuery: openFolder?.0.query != nil, hideNames: settings.hideNames && settings.hideFolderNames,
                    iconScale: settings.iconScale)
    }

    // MARK: State used by the extensions in LauncherModel+*.swift (stored properties must live here)

    /// Opened through LaunchUS, newest first.
    @ObservationIgnored var recentIDs = RecentLaunches.load()
    /// The recently-opened row: opened through LaunchUS first, then by the system's last-used
    /// date. Kept here rather than worked out in the view, which redraws as icons load.
    var frequentApps: [AppItem] = []
    /// Apps pinned to the row, so their icons can show a pin.
    var frequentPinned: Set<String> = []
    @ObservationIgnored var lastDragEnd = Date.distantPast
    @ObservationIgnored var landingToken = 0
    @ObservationIgnored var profiles = LayoutProfiles.load() {
        didSet { if profiles.current != oldValue.current { followProfile() } }
    }
    /// Bumped when profiles change, so menus and settings re-read them.
    var profilesVersion = 0
    /// Set while a profile's settings are applied, so they don't reflow the pages being left.
    @ObservationIgnored var switchingProfile = false
    /// Set when a switch to a profile in another language is about to relaunch LaunchUS.
    @ObservationIgnored var relaunchingForLanguage = false
    var customItems: [CustomItem] = [] {
        didSet { catalog.customApps = customItems.map(\.appItem) }
    }

    // MARK: - Layout

    /// Called whenever the scanned app list changes.
    func catalogChanged() {
        guard !catalog.apps.isEmpty else { return }
        var needsSave = false
        if !layoutLoaded {
            layoutLoaded = true
            (laidOutColumns, laidOutRows) = (columns, rows)
            if let saved = LayoutStore.loadLayout() {
                layout = saved
            } else {
                needsSave = true
                layout = LayoutOps.alphabetical(catalog.apps, perPage: perPage)
            }
        }
        seedCategoryTagsIfNeeded()
        updateNewApps()
        guard drag == nil else { return }
        reconcile(forceSave: needsSave)
    }

    /// Grid size, sorting or sources changed.
    func settingsChanged() {
        guard layoutLoaded, drag == nil, !switchingProfile else { return }
        folderDragOffset = 0
        if freePlacement {
            // Free placement: every icon keeps its row and column in the new grid.
            if (columns, rows) != (laidOutColumns, laidOutRows) {
                layout = LayoutOps.regrid(layout, fromColumns: laidOutColumns, toColumns: columns, rows: rows)
                LayoutStore.save(layout: layout)
            }
        } else if perPage > laidOutPerPage {
            // A bigger grid: pages that were full fill up again from the ones after them.
            layout = LayoutOps.fill(layout, wasPerPage: laidOutPerPage, perPage: perPage)
            LayoutStore.save(layout: layout)
        }
        (laidOutColumns, laidOutRows) = (columns, rows)
        reconcile()
    }

    func reconcile(forceSave: Bool = false) {
        let reconciled = LayoutOps.reconcile(layout, installed: catalog.apps, hidden: hiddenIDs, perPage: perPage, columns: columns,
                                              free: freePlacement)
        if reconciled != layout || forceSave {
            layout = reconciled
            LayoutStore.save(layout: layout)
        }
        refresh()
    }

    /// First run only: tag apps by their App Store category, so tags aren't empty to begin with.
    private func seedCategoryTagsIfNeeded() {
        let key = "didSeedCategoryTags"
        guard !UserDefaults.app.bool(forKey: key) else { return }
        UserDefaults.app.set(true, forKey: key)
        for app in catalog.apps {
            guard let tag = AppCategoryName.tagName(for: app.category) else { continue }
            var m = meta[app.id] ?? AppMeta()
            if m.tags.isEmpty { m.tags = [tag] }
            meta[app.id] = m
        }
        LayoutStore.save(meta: meta)
    }

    var hiddenIDs: Set<String> { Set(meta.filter { $0.value.hidden }.map(\.key)) }

    /// Packs every page for the grid's shape, so an item's index is its cell even with
    /// widgets around. Pages left empty mid-drag stay until the drop.
    func normalizeLayout() {
        guard layoutLoaded else { return }
        let packed = LayoutOps.repack(layout, perPage: perPage, columns: columns, free: freePlacement,
                                      keepEmptyPages: drag != nil)
        guard packed != layout else { return }
        layout = packed
        if drag == nil { LayoutStore.save(layout: layout) }
    }

    func commitLayout() {
        layout = LayoutOps.repack(layout, perPage: perPage, columns: columns, free: freePlacement)
        LayoutStore.save(layout: layout)
        refresh()
    }

    func refresh() {
        normalizeLayout()
        if layout.joined().contains(where: { if case .widget(let w) = $0 { w.kind == BuiltInWidget.clipboard.rawValue } else { false } }) {
            ClipboardHistory.shared.start()
        }
        visibleApps = catalog.apps.compactMap { app in
            guard let m = meta[app.id] else { return app }
            if m.hidden { return nil }
            if let name = m.displayName, !name.isEmpty { return app.renamed(name) }
            return app
        }
        var counts: [String: Int] = [:]
        for m in meta.values { for tag in m.tags { counts[tag, default: 0] += 1 } }
        // Tags a smart folder asks for count as known even before any app carries them.
        for folder in smartFolders {
            for tag in AppSearch.parse(folder.query ?? "").tags where !counts.keys.contains(where: { $0.lowercased() == tag }) {
                counts[tag] = 0
            }
        }
        allTags = counts.keys.sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0.localizedStandardCompare($1) == .orderedAscending }
        updateFrequentApps()

        // The picked tab's smart folder was deleted, or the tab or the whole bar is gone: back
        // to everything (the didSet refreshes again).
        if let filter = categoryFilter,
           smartFolder(forTab: filter) == nil || !settings.showCategoryBar || settings.hiddenCategoryTabs.contains(filter) {
            categoryFilter = nil; return
        }
        let byID = Dictionary(visibleApps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if isSearching {
            // System Settings panes come after the apps.
            let results = spaceList.map { $0.apps(from: visibleApps, recent: recentIDs, hours: LaunchHours.load()) }
                ?? categoryFilter.map { filter in
                    // Typing with a category picked searches inside it (its chip stays in the search field).
                    let inside = Set(categoryApps(filter).map(\.id))
                    return search(query, includeHidden: hiddenUnlocked).filter { inside.contains($0.id) }
                }
                ?? search(query, includeHidden: hiddenUnlocked) + SettingsPanes.search(query)
            if results.isEmpty, spaceList == nil, query.count >= (query.allSatisfy(\.isASCII) ? 3 : 2) { offerTip(.launchItem) }
            pages = stride(from: 0, to: max(results.count, 1), by: perPage).map { start in
                results[start..<min(start + perPage, results.count)].map(GridEntry.app)
            }
        } else if let filter = categoryFilter {
            let apps = categoryApps(filter)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            pages = stride(from: 0, to: max(apps.count, 1), by: perPage).map { start in
                apps[start..<min(start + perPage, apps.count)].map(GridEntry.app)
            }
        } else {
            func entry(_ item: LayoutItem) -> GridEntry? {
                switch item {
                case .app(let id): byID[id].map(GridEntry.app)
                case .folder(let folder):
                    .folder(folder, folder.query.map(search) ?? folder.apps.compactMap { byID[$0] })
                case .widget(let widget): .widget(widget)
                case .gap, .cover: nil
                }
            }
            if settings.sortOrder == .custom {
                // Every cell keeps its place (empty ones and those under widgets draw nothing),
                // and so the icons after them.
                pages = layout.enumerated().map { p, page in
                    page.enumerated().map { s, item in entry(item) ?? .gap("\(p)-\(s)") }
                }
            } else {
                // Widgets stay at the top of the first page, the rest sorted after them.
                let widgets = layout.joined().filter { if case .widget = $0 { true } else { false } }
                let sorted = Self.sorted(layout.joined().compactMap { $0.isWidget ? nil : entry($0) }, by: settings.sortOrder)
                let byEntry = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let items = widgets + sorted.map { e -> LayoutItem in
                    switch e {
                    case .app(let app): .app(app.id)
                    case .folder(let folder, _): .folder(folder)
                    case .widget(let w): .widget(w)
                    case .gap: .gap
                    }
                }
                let packed = LayoutOps.repack([items], perPage: perPage, columns: columns)
                pages = packed.enumerated().map { p, page in
                    page.enumerated().map { s, item in
                        if case .widget(let w) = item { return .widget(w) }
                        return byEntry[item.id] ?? .gap("\(p)-\(s)")
                    }
                }
            }
            if pages.isEmpty { pages = [[]] }
        }
        updateScrollCells()
        currentPage = min(currentPage, pageCount - 1)
        if let s = selection, !isValid(s) { selection = nil }
        if openFolderID != nil, openFolder == nil { dropFolder() }
        folderPage = max(0, min(folderPageCount - 1, folderPage))
        clampFolderScroll()
    }

    /// Home grid order for the non-custom sort settings. Folders count by their newest app.
    private static func sorted(_ entries: [GridEntry], by order: SortOrder) -> [GridEntry] {
        func date(_ e: GridEntry) -> Date {
            let apps: [AppItem] = switch e {
            case .app(let a): [a]
            case .folder(_, let apps): apps
            case .gap, .widget: []
            }
            let dates = apps.compactMap { order == .recentlyUsed ? $0.lastUsedDate : $0.addedDate }
            return dates.max() ?? .distantPast
        }
        switch order {
        case .custom: return entries
        case .name: return entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .mostUsed:
            func uses(_ e: GridEntry) -> Int {
                switch e {
                case .app(let a): a.useCount
                case .folder(_, let apps): apps.map(\.useCount).reduce(0, +)
                case .gap, .widget: 0
                }
            }
            let keyed = entries.map { ($0, uses($0)) }
            return keyed.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending }.map(\.0)
        case .recentlyAdded, .recentlyUsed:
            let keyed = entries.map { ($0, date($0)) }
            return keyed.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending }.map(\.0)
        }
    }

    func search(_ query: String) -> [AppItem] { search(query, includeHidden: false) }

    func search(_ query: String, includeHidden: Bool) -> [AppItem] {
        // Hidden apps can optionally still be found by search (but never in smart folders).
        var pool = visibleApps
        if includeHidden {
            pool += catalog.apps.filter { meta[$0.id]?.hidden == true }
        }
        return AppSearch.search(query, in: pool,
                         aliases: meta.compactMapValues { $0.aliases.isEmpty ? nil : $0.aliases },
                         tags: meta.compactMapValues { $0.tags.isEmpty ? nil : $0.tags },
                         group: appGroup)
    }


    /// Bumped to scroll back to the top in the scrolling browse style.
    var scrollToTopRequest = 0

    // MARK: - Paging

    func goToPage(_ page: Int) {
        let target = max(0, min(pageCount - 1, page))
        withAnimation(settings.motion(.spring(response: 0.5, dampingFraction: 1), duration: 0.45)) {
            currentPage = target
            dragOffset = 0
        }
    }

    var folderPageCount: Int {
        openFolder.map { max(1, ($0.1.count + folderPerPage - 1) / folderPerPage) } ?? 1
    }

    func goToFolderPage(_ page: Int) {
        let count = folderPageCount
        withAnimation(settings.motion(.spring(response: 0.5, dampingFraction: 1), duration: 0.45)) {
            folderPage = max(0, min(count - 1, page))
            folderDragOffset = 0
        }
    }

    /// Live paging drag (trackpad swipe or mouse drag); `translation` is the total distance so far.
    func dragChanged(_ translation: CGFloat) {
        if openFolderID != nil {
            let edge = (folderPage == 0 && translation > 0) || (folderPage >= folderPageCount - 1 && translation < 0)
            folderDragOffset = edge ? translation * 0.3 : translation
            return
        }
        let atStart = currentPage == 0 && translation > 0
        let atEnd = currentPage == pageCount - 1 && translation < 0
        dragOffset = (atStart || atEnd) ? translation * 0.3 : translation
    }

    /// Snaps to the neighbouring page if the drag went far enough, otherwise back.
    func dragEnded(_ translation: CGFloat, pageWidth: CGFloat) {
        let threshold = min(110, pageWidth * 0.1)
        let step = translation < -threshold ? 1 : translation > threshold ? -1 : 0
        if openFolderID != nil {
            goToFolderPage(folderPage + step)
        } else {
            let before = currentPage
            goToPage(currentPage + step)
            // The first swipe shows they've found their way around; now point out the right-click menu.
            if currentPage != before { offerTip(.rightClick) }
        }
    }

    /// The most a scrolling folder can scroll: all its rows minus the ones that fit.
    private var maxFolderScroll: CGFloat {
        guard let folder = openFolder else { return 0 }
        let m = metrics
        let rows = (folder.1.count + folderColumns - 1) / folderColumns
        return max(0, CGFloat(rows) * m.cellSize.height - m.folderGridRect.height)
    }

    func scrollFolder(by delta: CGFloat) {
        folderScrollOffset = max(0, min(maxFolderScroll, folderScrollOffset + delta))
    }

    /// Contents, display size and browse mode can change without another scroll event.
    private func clampFolderScroll() {
        folderScrollOffset = folderScrolls ? max(0, min(maxFolderScroll, folderScrollOffset)) : 0
    }

    /// Scrolls just enough to show the keyboard-selected app in a scrolling folder.
    func revealFolderSelection() {
        guard folderScrolls, openFolderID != nil, let pos = selection else { return }
        let m = metrics
        let top = CGFloat(pos.slot / folderColumns) * m.cellSize.height
        let bottom = top + m.cellSize.height
        let visible = m.folderGridRect.height
        var offset = folderScrollOffset
        if top < offset { offset = top } else if bottom > offset + visible { offset = bottom - visible }
        guard offset != folderScrollOffset else { return }
        withAnimation(.easeOut(duration: 0.2)) { folderScrollOffset = max(0, min(maxFolderScroll, offset)) }
    }

    /// One page per mouse-wheel flick or ⌘←/→.
    func flipPage(_ step: Int) {
        if openFolderID != nil { goToFolderPage(folderPage + step); return }
        let before = currentPage
        goToPage(currentPage + step)
        if currentPage != before { offerTip(.rightClick) }
    }

    /// Set while the user is off in System Settings granting Full Disk Access.
    @ObservationIgnored var resumeUninstall: String?

    /// System Settings opens under the launcher, so get out of its way.
    func openFullDiskAccessSettings(resuming appID: String) {
        resumeUninstall = appID
        PermissionHelper.shared.request(.fullDiskAccess)
    }

    /// Called once the uninstall card has moved its files to the Trash.
    func finishUninstall(_ app: AppItem, failed: [URL]) {
        catalog.reload(force: true)
        if failed.isEmpty {
            dismissSheet()
        } else {
            let names = failed.prefix(4).map(\.lastPathComponent).joined(separator: "、")
            sheet = .message(title: String(localized: "有 \(failed.count) 个项目没能移到废纸篓"),
                             text: String(localized: "\(names)\(failed.count > 4 ? String(localized: " 等") : "")。可能需要管理员权限或「App 管理」权限，可以在访达中手动删除。"),
                             revealPath: failed[0].path)
        }
    }

    /// Shows a file in Finder. The launcher closes first: it would cover the Finder window,
    /// and closing hands focus back to the previous app, which must happen before Finder comes up.
    func reveal(_ path: String) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

}

/// Apps opened from LaunchUS, newest first, for the frequently used row,
/// plus the apps pinned to the row and the ones taken off it.
enum RecentLaunches {
    private static let key = "recentLaunches"
    private static let pinnedKey = "frequentPinned"
    private static let removedKey = "frequentRemoved"
    private static let limit = 30

    static func load() -> [String] { UserDefaults.app.stringArray(forKey: key) ?? [] }
    static var pinned: [String] { UserDefaults.app.stringArray(forKey: pinnedKey) ?? [] }
    static var removed: Set<String> { Set(UserDefaults.app.stringArray(forKey: removedKey) ?? []) }

    static func record(_ id: String) {
        var ids = load().filter { $0 != id }
        ids.insert(id, at: 0)
        UserDefaults.app.set(Array(ids.prefix(limit)), forKey: key)
        LaunchHours.record(id)
        LaunchLog.record(id)
    }

    static func setPinned(_ pin: Bool, _ id: String) {
        var ids = pinned.filter { $0 != id }
        if pin { ids.append(id) }
        UserDefaults.app.set(ids, forKey: pinnedKey)
        if pin { setRemoved(false, id) }
    }

    /// A removed app stays off the row, even when opened again, until the row is reset.
    static func setRemoved(_ remove: Bool, _ id: String) {
        var ids = removed
        if remove { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.app.set(ids.sorted(), forKey: removedKey)
        if remove { setPinned(false, id) }
    }

    static func reset() {
        for key in [key, pinnedKey, removedKey] { UserDefaults.app.removeObject(forKey: key) }
    }

    /// The row: pinned apps first, then the ones opened here most recently, then the
    /// system's last-used dates, skipping removed apps.
    static func row(apps: [AppItem], recent: [String], pinned: [String], removed: Set<String>,
                    limit: Int, ownID: String?) -> [AppItem] {
        var byID: [String: AppItem] = [:]
        for app in apps { byID[app.id] = app }
        var taken = Set<String>()
        var result: [AppItem] = []
        for id in pinned + recent where !removed.contains(id) && !taken.contains(id) {
            guard let app = byID[id] else { continue }
            taken.insert(id)
            result.append(app)
        }
        if result.count < limit {
            let rest = apps.filter { !taken.contains($0.id) && !removed.contains($0.id) && $0.lastUsedDate != nil
                && $0.custom == nil && $0.id != ownID }
                .sorted { $0.lastUsedDate! > $1.lastUsedDate! }
            result += rest.prefix(limit - result.count)
        }
        return Array(result.prefix(limit))
    }
}
