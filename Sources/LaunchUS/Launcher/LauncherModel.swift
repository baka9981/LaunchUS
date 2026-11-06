import AppKit
import SwiftUI
import Observation

/// One cell as shown on screen: an app, or a folder with its resolved apps.
enum GridEntry: Identifiable, Equatable {
    case app(AppItem)
    case folder(Folder, [AppItem])

    var id: String {
        switch self {
        case .app(let app): "app:" + app.id
        case .folder(let folder, _): "folder:" + folder.id
        }
    }

    static func == (a: GridEntry, b: GridEntry) -> Bool {
        switch (a, b) {
        case (.app(let x), .app(let y)): x.id == y.id && x.name == y.name
        case (.folder(let x, let xa), .folder(let y, let ya)): x == y && xa == ya
        default: false
        }
    }
}

/// A card shown over the launcher: editors and confirmations.
enum LauncherSheet: Hashable {
    case editApp(String)
    /// `nil` folder ID creates a new smart folder.
    case editSmartFolder(String?, query: String)
    case confirmTrash(String)
    /// The info card of an app.
    case appInfo(String)
    /// `nil` creates a new launch item.
    case editCustom(String?)
    case confirmDeleteCustom(String)
    case chooseIcon(String)
    case newProfile
    /// The global shortcut that opens every app in a folder.
    case folderShortcut(String)
    /// The App manager: sizes, chips, updates and usage statistics.
    case manager
    case message(title: String, text: String, revealPath: String?)
}

struct GridPos: Equatable {
    var page: Int
    var slot: Int
}

/// An icon being dragged. The pointer is tracked by the controller (not the SwiftUI gesture),
/// because the view that started the drag can disappear mid-drag (e.g. leaving a folder).
struct DragSession {
    var item: LayoutItem
    /// Set while the app is still being rearranged inside this open folder.
    var folderID: String?
    /// Pointer position minus the icon centre at the moment the drag started.
    var grabOffset: CGSize
    /// Other ⌘-selected apps carried along; they are lifted out of the layout while dragging.
    var companions: [String] = []
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
    var folderRows: Int { rows }
    var perPage: Int { columns * rows }
    /// Scrolling folders keep all their apps on one tall page.
    var folderScrolls: Bool { settings.folderBrowseStyle == .scroll }
    var folderPerPage: Int { folderScrolls ? 100_000 : folderColumns * folderRows }

    // MARK: Persistent state
    var layout: [[LayoutItem]] = []
    var meta: [String: AppMeta] = [:] {
        didSet {
            catalog.iconOverrides = Self.iconOverrides(meta)
            AppHotKeys.update(meta.compactMapValues(\.shortcut))
        }
    }
    @ObservationIgnored private var layoutLoaded = false

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
    private(set) var hiddenUnlocked = false
    var showHiddenApps = false
    /// The secret slot is showing its dashed outline and can be clicked.
    var phantomSlotArmed = false
    @ObservationIgnored private var phantomDisarm: DispatchWorkItem?
    /// The first-run walkthrough.
    var showGuide = false
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
    var currentPage = 0
    var selection: GridPos?
    /// Live horizontal offset while a swipe or mouse drag is in progress.
    var dragOffset: CGFloat = 0
    var isPresented = false
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
    /// The rectangle being dragged out on empty space to pick apps, in launcher coordinates.
    var marquee: CGRect?
    /// What was picked before the rectangle started; the rectangle adds to it.
    @ObservationIgnored var marqueeBase: Set<String>?
    /// Icons can be dragged around only in the custom, paged arrangement.
    var canRearrange: Bool { settings.sortOrder == .custom && settings.browseStyle == .paged && categoryFilter == nil }

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

    static func categoryKey(_ app: AppItem) -> String {
        AppCategoryName.tagName(for: app.category) == nil ? "other" : app.category!
    }

    /// Categories present among the visible apps, biggest first, "其他" last.
    var categoryTabs: [(key: String, title: String)] {
        var counts: [String: Int] = [:]
        for app in visibleApps { counts[Self.categoryKey(app), default: 0] += 1 }
        let named = counts.keys.filter { $0 != "other" }
            .sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0 < $1 }
            .map { (key: $0, title: AppCategoryName.tagName(for: $0) ?? $0) }
        return named + (counts["other"] != nil ? [(key: "other", title: String(localized: "其他"))] : [])
    }
    @ObservationIgnored private var lastHidden = Date.distantPast

    // MARK: Folder panel
    private(set) var openFolderID: String?
    /// Animated separately from `openFolderID`: the panel is inserted collapsed onto the
    /// folder's tile, then expands; on close it collapses back before it is removed.
    private(set) var folderExpanded = false
    /// The open folder's tile on the home grid, in launcher coordinates.
    private(set) var folderOrigin: CGRect?
    @ObservationIgnored private var folderToken = 0
    var folderPage = 0
    var folderDragOffset: CGFloat = 0
    /// How far a scrolling folder is scrolled down, in points.
    var folderScrollOffset: CGFloat = 0
    var isRenaming = false
    var renameEndRequest = 0

    // MARK: Dragging
    var drag: DragSession?
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
    var settingsTab: SettingsTab = .general
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
        customItems = CustomItemStore.load()
        catalog.customApps = customItems.map(\.appItem)
        catalog.iconOverrides = Self.iconOverrides(meta)
    }

    private static func iconOverrides(_ meta: [String: AppMeta]) -> [String: String] {
        meta.compactMapValues { $0.icon.map(CustomIcons.path(for:)) }
    }

    var pageCount: Int { max(1, pages.count) }
    var metrics: GridMetrics {
        GridMetrics(size: screenSize, columns: columns, rows: rows, windowed: settings.displayMode == .window,
                    paged: settings.browseStyle == .paged, frequentRow: settings.showFrequent, folderItemCount: openFolder?.1.count ?? 0, hideNames: settings.hideNames && settings.hideFolderNames,
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
    @ObservationIgnored var profiles = LayoutProfiles.load()
    /// Bumped when profiles change, so menus and settings re-read them.
    var profilesVersion = 0
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
        guard layoutLoaded, drag == nil else { return }
        folderDragOffset = 0
        reconcile()
    }

    func reconcile(forceSave: Bool = false) {
        let reconciled = LayoutOps.reconcile(layout, installed: catalog.apps, hidden: hiddenIDs, perPage: perPage)
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

    func commitLayout() {
        layout = LayoutOps.repack(layout, perPage: perPage)
        LayoutStore.save(layout: layout)
        refresh()
    }

    func refresh() {
        visibleApps = catalog.apps.compactMap { app in
            guard let m = meta[app.id] else { return app }
            if m.hidden { return nil }
            if let name = m.displayName, !name.isEmpty { return app.renamed(name) }
            return app
        }
        var counts: [String: Int] = [:]
        for m in meta.values { for tag in m.tags { counts[tag, default: 0] += 1 } }
        allTags = counts.keys.sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0.localizedStandardCompare($1) == .orderedAscending }
        updateFrequentApps()

        let byID = Dictionary(visibleApps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if isSearching {
            // System Settings panes come after the apps.
            let results = spaceList.map { $0.apps(from: visibleApps, recent: recentIDs, hours: LaunchHours.load()) }
                ?? search(query, includeHidden: hiddenUnlocked) + SettingsPanes.search(query)
            if results.isEmpty, spaceList == nil, query.count >= (query.allSatisfy(\.isASCII) ? 3 : 2) { offerTip(.launchItem) }
            pages = stride(from: 0, to: max(results.count, 1), by: perPage).map { start in
                results[start..<min(start + perPage, results.count)].map(GridEntry.app)
            }
        } else if let filter = categoryFilter {
            let apps = visibleApps.filter { Self.categoryKey($0) == filter }
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
                }
            }
            if settings.sortOrder == .custom {
                pages = layout.map { $0.compactMap(entry) }
            } else {
                let sorted = Self.sorted(layout.joined().compactMap(entry), by: settings.sortOrder)
                pages = stride(from: 0, to: sorted.count, by: perPage).map {
                    Array(sorted[$0..<min($0 + perPage, sorted.count)])
                }
            }
            if pages.isEmpty { pages = [[]] }
        }
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
                         tags: meta.compactMapValues { $0.tags.isEmpty ? nil : $0.tags })
    }

    // MARK: - Tags in the search field

    /// The "#…" token being typed at the end of the query, if any.
    private var pendingTagToken: String? {
        guard let last = query.split(separator: " ", omittingEmptySubsequences: false).last,
              let first = last.first, first == "#" || first == "＃" else { return nil }
        return String(last.dropFirst())
    }

    /// Tags offered under the search field while a "#…" token is being typed.
    var tagCandidates: [String] {
        guard let token = pendingTagToken else { return [] }
        let used = Set(AppSearch.parse(query).tags.dropLast())
        let matches = token.isEmpty ? allTags : AppSearch.tagsMatching(token, in: allTags)
        return Array(matches.filter { !used.contains($0.lowercased()) }.prefix(12))
    }

    func completeTag(_ tag: String) {
        guard pendingTagToken != nil else { return }
        var parts = query.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        parts[parts.count - 1] = "#" + tag
        query = parts.joined(separator: " ") + " "
        focusRequest += 1
    }

    /// Tags named exactly in the query, when every "#…" token is a complete tag.
    var completeQueryTags: [String] {
        let tokens = AppSearch.parse(query).tags
        let resolved = tokens.compactMap { t in allTags.first { $0.lowercased() == t } }
        return !tokens.isEmpty && resolved.count == tokens.count ? resolved : []
    }

    private func queryChanged() {
        guard chat == nil else { return }  // writing a message, not searching
        let phrase = settings.hiddenPhrase.trimmingCharacters(in: .whitespaces)
        if !phrase.isEmpty, query.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(phrase) == .orderedSame {
            // Cleared on the next turn: set from inside the text field's own edit, the field
            // keeps showing the phrase (with the placeholder drawn over it).
            DispatchQueue.main.async {
                self.query = ""
                self.revealHidden()
            }
            return
        }
        // The field never starts with a space (space there opens the lists); this catches pastes.
        if let first = query.first, first.isWhitespace {
            DispatchQueue.main.async { self.query = String(self.query.drop(while: \.isWhitespace)) }
            return
        }
        if !query.isEmpty, spaceList != nil {
            spaceList = nil  // typing goes back to searching
            return
        }
        if openFolderID != nil { closeFolder() }
        isEditing = false
        multiSelection = []
        refresh()
        currentPage = 0
        dragOffset = 0
        selection = isSearching && !(pages.first ?? []).isEmpty ? GridPos(page: 0, slot: 0) : nil
    }

    private func spaceListChanged() {
        if openFolderID != nil { closeFolder() }
        isEditing = false
        multiSelection = []
        refresh()
        currentPage = 0
        dragOffset = 0
        selection = isSearching && !(pages.first ?? []).isEmpty ? GridPos(page: 0, slot: 0) : nil
    }

    /// Space with nothing typed: opens the lists, then moves to the next one.
    func pressSpace() {
        spaceList = spaceList?.step(1) ?? .guess
    }

    func prepareForShow() {
        // Back from granting Full Disk Access: pick the uninstall up again, rescanned.
        sheet = resumeUninstall.map(LauncherSheet.confirmTrash)
        resumeUninstall = nil
        showSettings = false
        exitChat()
        query = ""
        spaceList = nil
        selection = nil
        dragOffset = 0
        isEditing = false
        multiSelection = []
        dropFolder()
        isPresented = false
        showHiddenApps = false
        showGuide = false
        showWhatsNew = false
        tip = nil
        phantomSlotArmed = false
        showShortcutNumbers = false
        refresh()
        let wait = settings.returnHome
        if wait != .never, Date().timeIntervalSince(lastHidden) >= Double(wait.rawValue) {
            currentPage = 0
            scrollToTopRequest += 1
        }
    }

    func didHide() {
        lastHidden = Date()
        categoryFilter = nil
        showHiddenApps = false
        if settings.hiddenRelock, hiddenUnlocked {
            hiddenUnlocked = false
            refresh()
        }
    }

    /// Bumped to scroll back to the top in the scrolling browse style.
    var scrollToTopRequest = 0

    // MARK: - Paging

    func goToPage(_ page: Int) {
        let target = max(0, min(pageCount - 1, page))
        withAnimation(.spring(response: 0.5, dampingFraction: 1)) {
            currentPage = target
            dragOffset = 0
        }
    }

    var folderPageCount: Int {
        openFolder.map { max(1, ($0.1.count + folderPerPage - 1) / folderPerPage) } ?? 1
    }

    func goToFolderPage(_ page: Int) {
        let count = folderPageCount
        withAnimation(.spring(response: 0.5, dampingFraction: 1)) {
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
            goToPage(currentPage + step)
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
        if openFolderID != nil { goToFolderPage(folderPage + step) } else { goToPage(currentPage + step) }
    }

    // MARK: - Folders

    var openFolder: (Folder, [AppItem])? {
        guard let id = openFolderID else { return nil }
        for page in pages {
            for case .folder(let folder, let apps) in page where folder.id == id { return (folder, apps) }
        }
        return nil
    }

    func openFolder(_ id: String) {
        selection = nil
        folderPage = 0
        folderDragOffset = 0
        folderScrollOffset = 0
        folderToken += 1
        let token = folderToken
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            folderOrigin = tileRect(ofFolder: id)
            folderExpanded = false
            openFolderID = id
        }
        // Let the collapsed panel render once on top of the tile, then grow it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.folderToken == token, self.openFolderID == id else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { self.folderExpanded = true }
        }
    }

    /// For `launchus://folder?name=…`: the first folder with that name (ignoring case), on its page.
    func openFolder(named name: String) {
        for (index, page) in pages.enumerated() {
            for entry in page {
                guard case .folder(let folder, _) = entry,
                      folder.name.caseInsensitiveCompare(name) == .orderedSame else { continue }
                goToPage(index)
                openFolder(folder.id)
                return
            }
        }
    }

    func closeFolder() {
        guard openFolderID != nil else { return }
        if isRenaming { renameEndRequest += 1 }
        selection = nil
        folderToken += 1
        let token = folderToken
        folderOrigin = openFolderID.flatMap(tileRect(ofFolder:)) ?? folderOrigin
        withAnimation(.spring(response: 0.32, dampingFraction: 1), completionCriteria: .logicallyComplete) {
            folderExpanded = false
        } completion: { [weak self] in
            guard let self, self.folderToken == token else { return }
            self.openFolderID = nil
        }
        focusRequest += 1
    }

    /// Removes the folder panel at once (no closing animation).
    func dropFolder() {
        folderToken += 1
        openFolderID = nil
        folderExpanded = false
    }

    /// Where a folder's tile is drawn on the current home page, if it is visible there.
    private func tileRect(ofFolder id: String) -> CGRect? {
        guard !isSearching, settings.browseStyle == .paged, pages.indices.contains(currentPage),
              let slot = pages[currentPage].firstIndex(where: { $0.id == "folder:" + id }) else { return nil }
        let m = metrics
        let c = m.iconCenter(slot: slot)
        let size = m.iconSize * 0.8
        return CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)
    }

    func renameFolder(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let loc = location(ofFolder: id), case .folder(var folder) = layout[loc.page][loc.slot] else { return }
        let newName = trimmed.isEmpty ? String(localized: "未命名文件夹") : trimmed
        guard folder.name != newName else { return }
        folder.name = newName
        layout[loc.page][loc.slot] = .folder(folder)
        commitLayout()
    }

    func setFolderColor(_ id: String, _ color: FolderColor?) {
        guard let loc = location(ofFolder: id), case .folder(var folder) = layout[loc.page][loc.slot] else { return }
        folder.color = color?.rawValue
        layout[loc.page][loc.slot] = .folder(folder)
        commitLayout()
    }

    func location(ofFolder id: String) -> GridPos? {
        for (p, page) in layout.enumerated() {
            for (s, item) in page.enumerated() {
                if case .folder(let f) = item, f.id == id { return GridPos(page: p, slot: s) }
            }
        }
        return nil
    }

    func location(of itemID: String) -> GridPos? {
        for (p, page) in layout.enumerated() {
            if let s = page.firstIndex(where: { $0.id == itemID }) { return GridPos(page: p, slot: s) }
        }
        return nil
    }

    // MARK: - Organising (right-click menu, editors)

    func app(_ id: String) -> AppItem? { visibleApps.first { $0.id == id } ?? catalog.apps.first { $0.id == id } }
    func meta(for id: String) -> AppMeta { meta[id] ?? AppMeta() }

    func setShortcut(_ spec: HotKeySpec?, for id: String) {
        setMeta(id) { $0.shortcut = spec }
    }

    func setMeta(_ id: String, _ change: (inout AppMeta) -> Void) {
        var m = meta[id] ?? AppMeta()
        change(&m)
        meta[id] = m
        LayoutStore.save(meta: meta)
    }

    func updateApp(_ id: String, displayName: String, aliases: [String], tags: [String]) {
        let original = catalog.apps.first { $0.id == id }?.name
        setMeta(id) { m in
            let name = displayName.trimmingCharacters(in: .whitespaces)
            m.displayName = name.isEmpty || name == original ? nil : name
            m.aliases = Self.cleaned(aliases)
            m.tags = Self.cleaned(tags)
        }
        refresh()
    }

    func setHidden(_ hidden: Bool, for id: String) {
        setMeta(id) { $0.hidden = hidden }
        if hidden, let folderID = folderContaining(id) {
            // Hiding the second-to-last app of a folder leaves one: dissolve like Launchpad.
            removeApp(id, fromFolder: folderID)
        }
        reconcile(forceSave: true)
    }

    // MARK: - Hidden apps

    /// Opens the hidden apps panel, after Touch ID or the password when that's required.
    func revealHidden() {
        guard !isAuthenticating else { return }
        phantomSlotArmed = false
        Task { @MainActor in
            if !hiddenUnlocked, settings.hiddenRequireAuth {
                isAuthenticating = true
                let ok = await OwnerAuth.verify(reason: String(localized: "显示隐藏的 App"))
                isAuthenticating = false
                guard ok else { return }
            }
            hiddenUnlocked = true
            if openFolderID != nil { dropFolder() }
            isEditing = false
            multiSelection = []
            refresh()
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) { showHiddenApps = true }
        }
    }

    func openGuide() {
        isEditing = false
        sheet = nil
        showSettings = false
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { showGuide = true }
    }

    func finishGuide() {
        UserDefaults.app.set(true, forKey: "didShowGuide")
        WhatsNew.markSeen()
        withAnimation(.easeOut(duration: 0.2)) { showGuide = false }
        focusRequest += 1
    }

    func closeHiddenApps() {
        withAnimation(.easeOut(duration: 0.18)) { showHiddenApps = false }
        focusRequest += 1
    }

    /// Hides them again until the next verification.
    func lockHidden() {
        hiddenUnlocked = false
        if showHiddenApps { closeHiddenApps() }
        refresh()
    }

    /// True while hidden apps exist behind verification that hasn't been passed yet. Then
    /// their settings, and anything that could unhide them, need the same verification,
    /// or turning verification off or changing the passphrase would get round it.
    var hiddenGuarded: Bool {
        settings.hiddenRequireAuth && !hiddenUnlocked && !hiddenApps.isEmpty
    }

    /// Runs `action` straight away, or after Touch ID or the password while `hiddenGuarded`.
    /// Passing also unlocks the hidden apps, as opening them would.
    func whenHiddenUnlocked(reason: String = String(localized: "修改隐藏的 App 设置"), _ action: @escaping () -> Void = {}) {
        guard hiddenGuarded else { return action() }
        guard !isAuthenticating else { return }
        Task { @MainActor in
            isAuthenticating = true
            let ok = await OwnerAuth.verify(reason: reason)
            isAuthenticating = false
            guard ok else { return }
            hiddenUnlocked = true
            refresh()
            action()
        }
    }

    /// Page holding the secret empty slot, if that entrance is on and the page has room.
    var phantomSlotPage: Int? {
        guard settings.hiddenSlotEntrance, !isSearching, categoryFilter == nil, !isEditing else { return nil }
        let page = settings.hiddenSlotPage == 0 ? pageCount - 1 : min(settings.hiddenSlotPage - 1, pageCount - 1)
        return pages.indices.contains(page) && pages[page].count < perPage ? page : nil
    }

    func armPhantomSlot() {
        withAnimation(.easeOut(duration: 0.15)) { phantomSlotArmed = true }
        phantomDisarm?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.3)) { self?.phantomSlotArmed = false }
        }
        phantomDisarm = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func folderContaining(_ appID: String) -> String? {
        for page in layout {
            for case .folder(let f) in page where f.apps.contains(appID) { return f.id }
        }
        return nil
    }

    /// Takes an app out of its folder and puts it right after the folder.
    func takeOutOfFolder(_ appID: String, folderID: String) {
        guard let loc = location(ofFolder: folderID) else { return }
        removeApp(appID, fromFolder: folderID)
        layout[loc.page].insert(.app(appID), at: min(loc.slot + 1, layout[loc.page].count))
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) {
            if openFolderID == folderID, case .app = layout[loc.page][loc.slot] { dropFolder() }
            commitLayout()
        }
    }

    func removeApp(_ appID: String, fromFolder folderID: String) {
        guard let loc = location(ofFolder: folderID), case .folder(var folder) = layout[loc.page][loc.slot] else { return }
        folder.apps.removeAll { $0 == appID }
        layout[loc.page][loc.slot] = folder.apps.count == 1 ? .app(folder.apps[0]) : .folder(folder)
        if folder.apps.isEmpty { layout[loc.page].remove(at: loc.slot) }
    }

    /// Replaces a folder with its apps; a smart folder is simply removed.
    func dissolveFolder(_ id: String) {
        guard let loc = location(ofFolder: id), case .folder(let folder) = layout[loc.page][loc.slot] else { return }
        layout[loc.page].remove(at: loc.slot)
        if !folder.isSmart {
            layout[loc.page].insert(contentsOf: folder.apps.map(LayoutItem.app), at: loc.slot)
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) {
            if openFolderID == id { dropFolder() }
            commitLayout()
        }
    }

    func startRenaming(folder id: String) {
        renameOnOpen = true
        openFolder(id)
    }

    /// Creates (folderID nil) or edits a smart folder. New ones go to the end of the last page.
    func saveSmartFolder(_ folderID: String?, name: String, query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        if let folderID, let loc = location(ofFolder: folderID), case .folder(var f) = layout[loc.page][loc.slot] {
            f.name = n.isEmpty ? f.name : n
            f.query = q
            layout[loc.page][loc.slot] = .folder(f)
            commitLayout()
        } else {
            let folder = Folder(name: n.isEmpty ? Self.smartFolderName(for: q) : n, apps: [], query: q)
            if layout.isEmpty { layout = [[]] }
            layout[layout.count - 1].append(.folder(folder))
            self.query = ""
            commitLayout()
            goToPage(pageCount - 1)
        }
    }

    static func smartFolderName(for query: String) -> String {
        let (tags, text) = AppSearch.parse(query)
        let parts = tags + (text.isEmpty ? [] : [text])
        return parts.isEmpty ? String(localized: "智能文件夹") : parts.joined(separator: "、")
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
