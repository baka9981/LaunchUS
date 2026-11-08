import AppKit
import SwiftUI

// Keyboard selection, opening apps and the per-icon status (new, running, badges).

extension LauncherModel {
    // MARK: - Keyboard selection

    /// Entries the arrow keys move through: the open folder's apps, or the grid pages.
    private var selectablePages: [[GridEntry]] {
        guard let folder = openFolder else { return pages }
        let apps = folder.1.map(GridEntry.app)
        return stride(from: 0, to: max(apps.count, 1), by: folderPerPage).map {
            Array(apps[$0..<min($0 + folderPerPage, apps.count)])
        }
    }

    func isValid(_ pos: GridPos) -> Bool {
        let p = selectablePages
        return p.indices.contains(pos.page) && p[pos.page].indices.contains(pos.slot) && !p[pos.page][pos.slot].isGap
    }

    func moveSelection(dx: Int, dy: Int) {
        let p = selectablePages
        let cols = openFolderID != nil ? folderColumns : columns
        let visiblePage = openFolderID != nil ? (folderScrolls ? 0 : folderPage) : currentPage
        guard var pos = selection, isValid(pos) else {
            if p.indices.contains(visiblePage), let first = p[visiblePage].firstIndex(where: { !$0.isGap }) {
                selection = GridPos(page: visiblePage, slot: first)
            }
            return
        }
        // Empty cells are stepped over.
        if dx != 0 {
            let start = pos
            repeat {
                pos.slot += dx
                if pos.slot < 0 {
                    guard pos.page > 0 else { pos = start; break }
                    pos.page -= 1; pos.slot = p[pos.page].count - 1
                } else if pos.slot >= p[pos.page].count {
                    guard pos.page + 1 < p.count else { pos = start; break }
                    pos.page += 1; pos.slot = 0
                }
            } while !isValid(pos)
        }
        if dy != 0 {
            var target = pos.slot + dy * cols
            while target >= 0 && target < p[pos.page].count {
                if !p[pos.page][target].isGap { pos.slot = target; break }
                target += dy * cols
            }
        }
        selection = pos
        if openFolderID != nil {
            if pos.page != folderPage { goToFolderPage(pos.page) }
        } else if pos.page != currentPage {
            goToPage(pos.page)
        }
    }

    /// The search field read as a sum, if it is one.
    var calculation: Calculator.Result? {
        isSearching && chat == nil ? Calculator.evaluate(query) : nil
    }

    func copyCalculation() {
        guard let result = calculation else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.copyText, forType: .string)
        showNotice(String(localized: "已复制 \(result.copyText)"))
    }

    /// AI is set up and the search found nothing: the typed text can start a chat.
    var canAskAI: Bool { fallbackQuery != nil && AIClient.isConfigured }

    /// Starts a chat with what's typed as its first message.
    func startChat() {
        guard let text = fallbackQuery, AIClient.isConfigured else { return }
        let session = makeChat()
        withAnimation(.easeOut(duration: 0.2)) { chat = session }
        query = ""
        session.send(text)
        // The field moves into the chat card: keep typing there.
        DispatchQueue.main.async { self.focusRequest += 1 }
    }

    private func makeChat() -> ChatSession {
        let session = ChatSession()
        session.local = { [weak self] call in self?.runLocalTool(call) }
        return session
    }

    /// An empty chat, from the menu: the next ↩ in the field sends.
    func openChat() {
        guard chat == nil, AIClient.isConfigured else { return }
        let session = makeChat()
        if openFolderID != nil { closeFolder() }
        spaceList = nil
        withAnimation(.easeOut(duration: 0.2)) { chat = session }
        query = ""
        DispatchQueue.main.async { self.focusRequest += 1 }
    }

    /// ↩ in the field while chatting.
    func sendChat() {
        guard let chat else { return }
        if chat.isAsking, query.trimmingCharacters(in: .whitespaces).isEmpty { return chat.approve() }
        guard !chat.isStreaming else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        query = ""
        chat.send(text)
    }

    func newChat() {
        chat?.reset()
        query = ""
    }

    func exitChat() {
        guard let chat else { return }
        chat.stop()
        withAnimation(.easeOut(duration: 0.2)) { self.chat = nil }
        query = ""
        refresh()
        DispatchQueue.main.async { self.focusRequest += 1 }
    }

    /// What's typed, when search found nothing: offered to the web or Finder instead.
    var fallbackQuery: String? {
        guard chat == nil, isSearching, spaceList == nil, calculation == nil, pages.allSatisfy(\.isEmpty) else { return nil }
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, AppSearch.parse(text).tags.isEmpty else { return nil }
        return text
    }

    func searchWeb() {
        guard let text = fallbackQuery, let url = settings.searchEngine.url(for: text) else { return }
        close()
        NSWorkspace.shared.open(url)
    }

    func openFile(_ file: FoundFile) {
        close()
        NSWorkspace.shared.open(file.url)
    }

    func revealFile(_ file: FoundFile) {
        close()
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func searchFilesInFinder() {
        let text = query.trimmingCharacters(in: .whitespaces)
        close()
        NSWorkspace.shared.showSearchResults(forQueryString: text)
    }

    func searchFinder() {
        guard let text = fallbackQuery else { return }
        close()
        NSWorkspace.shared.showSearchResults(forQueryString: text)
    }

    func activateSelection() {
        if let pos = selection, isValid(pos) {
            activate(selectablePages[pos.page][pos.slot])
        } else if calculation != nil {
            copyCalculation()
        } else if fallbackQuery != nil {
            // With AI set up, ↩ asks it and ⇥ searches the web.
            if canAskAI { startChat() } else { searchWeb() }
        } else if isSearching, case .app(let app)? = pages.first?.first {
            launch(app)
        }
    }

    /// The info card of an app (not of launch items or settings panes).
    func showInfo(_ id: String) {
        guard let app = app(id), app.custom == nil else { return }
        sheet = .appInfo(id)
    }

    /// ⌘I: the selected app, or the first search result.
    func showInfoForSelection() {
        let entry: GridEntry? = if let pos = selection, isValid(pos) { selectablePages[pos.page][pos.slot] }
            else if isSearching { pages.first?.first } else { nil }
        if case .app(let app)? = entry { showInfo(app.id) }
    }

    func activate(_ entry: GridEntry) {
        dismissFolderPick()
        if case .widget(let widget) = entry, editingNoteID == widget.id { return }
        endNoteEditing()
        switch entry {
        case .app(let app):
            if !isEditing { launch(app) }
        case .folder(let folder, _):
            openFolder(folder.id)
        case .widget(let widget):
            if !isEditing { activateWidget(widget, at: nil, card: .zero) }
        case .gap: break
        }
    }



    /// The recent apps row: only while scrolling, where an extra row can't upset the pages.
    var showsFrequentRow: Bool { settings.showFrequent && settings.pageStyle == .scroll }

    func updateFrequentApps() {
        guard showsFrequentRow else {
            if !frequentApps.isEmpty { frequentApps = [] }
            return
        }
        let apps = RecentLaunches.row(apps: visibleApps, recent: recentIDs, pinned: RecentLaunches.pinned,
                                      removed: RecentLaunches.removed, limit: columns, ownID: Bundle.main.bundleIdentifier)
        if apps != frequentApps { frequentApps = apps }
        let pinned = Set(RecentLaunches.pinned)
        if pinned != frequentPinned { frequentPinned = pinned }
    }

    func isPinnedToFrequent(_ id: String) -> Bool { frequentPinned.contains(id) }

    func setPinnedToFrequent(_ pin: Bool, _ id: String) {
        RecentLaunches.setPinned(pin, id)
        updateFrequentApps()
    }

    func removeFromFrequent(_ id: String) {
        RecentLaunches.setRemoved(true, id)
        updateFrequentApps()
    }

    func resetFrequent() {
        RecentLaunches.reset()
        recentIDs = []
        updateFrequentApps()
    }

    func launch(_ app: AppItem) {
        // A settings pane is a shortcut into System Settings, not something to remember.
        guard !SettingsPanes.isPane(app.id) else {
            onLaunch?(app)
            return
        }
        RecentLaunches.record(app.id)
        recentIDs = RecentLaunches.load()
        widgetLaunches += 1
        updateFrequentApps()
        if newAppIDs.contains(app.id) {
            newApps?.new[app.id] = nil
            newApps.map(NewApps.save)
            newAppIDs.remove(app.id)
        }
        onLaunch?(app)
    }

    /// Files dropped on an app icon open in that app, which counts as launching it.
    @discardableResult
    func open(_ urls: [URL], with app: AppItem) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty, !app.isCustom, !isEditing else { return false }
        RecentLaunches.record(app.id)
        recentIDs = RecentLaunches.load()
        updateFrequentApps()
        onOpenFiles?(files, app)
        return true
    }

    func updateNewApps() {
        let elsewhere = profiles.saved.filter { $0.key != profiles.current }.values.reduce(into: Set<String>()) { ids, pages in
            for item in pages.joined() {
                switch item {
                case .app(let id): ids.insert(id)
                case .folder(let folder): ids.formUnion(folder.apps)
                default: break
                }
            }
        }
        let state = NewApps.update(newApps ?? NewApps.load(), apps: catalog.apps, elsewhere: elsewhere)
        if state != newApps { NewApps.save(state) }
        newApps = state
        let ids = Set(state.new.keys)
        if ids != newAppIDs { newAppIDs = ids }
    }

    func isNew(_ entry: GridEntry) -> Bool {
        guard settings.showNewDot, !newAppIDs.isEmpty else { return false }
        switch entry {
        case .app(let app): return newAppIDs.contains(app.id)
        case .folder(_, let apps): return apps.contains { newAppIDs.contains($0.id) }
        case .gap, .widget: return false
        }
    }

    /// Apps not opened for this long are faded and can be picked out in one go.
    static let staleAge: TimeInterval = 90 * 24 * 3600

    /// Opened before, but not in the last three months. Never-opened apps aren't flagged:
    /// Spotlight has no date for many built-in apps either, so that would mark them wrongly.
    static func isStale(_ app: AppItem, recent: [String], now: Date = Date()) -> Bool {
        guard !app.isCustom, let used = app.lastUsedDate else { return false }
        return now.timeIntervalSince(used) > staleAge && !recent.contains(app.id)
    }

    func isStale(_ entry: GridEntry) -> Bool {
        guard settings.fadeStale, case .app(let app) = entry else { return false }
        return Self.isStale(app, recent: recentIDs)
    }

    var staleApps: [AppItem] { visibleApps.filter { Self.isStale($0, recent: recentIDs) } }

    /// Picks every long-unused app on the home grid, ready to move into a folder or hide.
    func selectStaleApps() {
        let ids = Set(staleApps.map(\.id))
        guard !ids.isEmpty else {
            showNotice(String(localized: "没有超过 3 个月没打开的 App"))
            return
        }
        closeSettings()
        multiSelection = ids
        showNotice(String(localized: "已选中 \(ids.count) 个超过 3 个月没打开的 App，右键可以移动或隐藏"), for: 4)
    }

    func isRunning(_ entry: GridEntry) -> Bool {
        guard settings.showRunningDot, case .app(let app) = entry else { return false }
        return runningIDs.contains(app.id)
    }

    func badge(_ entry: GridEntry) -> String? {
        guard settings.showBadges, !badges.isEmpty else { return nil }
        switch entry {
        case .app(let app): return badges[app.id]
        case .folder(_, let apps): return DockBadges.sum(apps.compactMap { badges[$0.id] })
        case .gap, .widget: return nil
        }
    }

    /// 1…9 for the first nine items of the page on screen, while ⌘ is held.
    /// With the recent apps row showing, ⌘1…⌘9 open its apps instead of the page's first nine.
    var shortcutsUseRecentRow: Bool {
        showsFrequentRow && !frequentApps.isEmpty && !isSearching && openFolderID == nil
    }

    func frequentShortcutNumber(of app: AppItem) -> Int? {
        guard showShortcutNumbers, shortcutsUseRecentRow,
              let index = frequentApps.firstIndex(where: { $0.id == app.id }), index < 9 else { return nil }
        return index + 1
    }

    func shortcutNumber(of entry: GridEntry) -> Int? {
        guard showShortcutNumbers, !shortcutsUseRecentRow, openFolderID == nil, pages.indices.contains(currentPage),
              let index = shortcutEntries.firstIndex(where: { $0.id == entry.id }), index < 9 else { return nil }
        return index + 1
    }

    /// ⌘1…⌘9.
    func openShortcut(_ number: Int) {
        if shortcutsUseRecentRow {
            guard number >= 1, number <= frequentApps.count else { return }
            showShortcutNumbers = false
            launch(frequentApps[number - 1])
            return
        }
        let entries = shortcutEntries
        guard openFolderID == nil, number >= 1, number <= entries.count else { return }
        showShortcutNumbers = false
        activate(entries[number - 1])
    }

    /// The page on screen without its empty cells.
    private var shortcutEntries: [GridEntry] {
        pages.indices.contains(currentPage) ? pages[currentPage].filter { !$0.isGap && $0.widget == nil } : []
    }
    func close() { onClose?() }

    /// Closes the card, back to the one it was opened from if any.
    func dismissSheet() {
        let parent = sheetParent
        sheetParent = nil
        sheet = parent
    }

    /// Opens a card about one app from the App manager, which comes back when it closes.
    func openFromManager(_ child: LauncherSheet) {
        sheet = child
        sheetParent = .manager
    }

    /// Click on empty space: leave the folder / jiggle mode first, then close the launcher.
    func backgroundTapped() {
        if folderPick != nil {
            dismissFolderPick()
        } else if editingNoteID != nil {
            endNoteEditing()
        } else if showGuide {
            finishGuide()
        } else if showWhatsNew {
            finishWhatsNew()
        } else if showSettings {
            // Settings is a window of its own and keeps the launcher open; only a tuning panel
            // is ended from here (back to settings).
            if tuner != nil { closeSettings() }
        } else if sheet != nil {
            dismissSheet()
        } else if showHiddenApps {
            closeHiddenApps()
        } else if openFolderID != nil {
            closeFolder()
        } else if !multiSelection.isEmpty {
            withAnimation(.easeOut(duration: 0.15)) { multiSelection = [] }
        } else if isEditing {
            isEditing = false
        } else if settings.clickBackgroundToClose {
            close()
        }
    }

    /// Esc: finish renaming, close the folder, leave jiggle mode, clear the search, then close.
    func escape() {
        if folderPick != nil {
            dismissFolderPick()
        } else if editingNoteID != nil {
            endNoteEditing()
        } else if showGuide {
            finishGuide()
        } else if showWhatsNew {
            finishWhatsNew()
        } else if showSettings {
            // Settings is a window of its own and keeps the launcher open; only a tuning panel
            // is ended from here (back to settings).
            if tuner != nil { closeSettings() }
        } else if sheet != nil {
            dismissSheet()
        } else if showHiddenApps {
            closeHiddenApps()
        } else if isRenaming {
            renameEndRequest += 1
        } else if openFolderID != nil {
            closeFolder()
        } else if !multiSelection.isEmpty {
            withAnimation(.easeOut(duration: 0.15)) { multiSelection = [] }
        } else if isEditing {
            isEditing = false
        } else if let chat {
            if chat.isAsking {
                chat.deny()
            } else if chat.isStreaming {
                chat.stop()
            } else if !query.isEmpty {
                query = ""
            } else {
                exitChat()
            }
        } else if spaceList != nil {
            spaceList = nil
        } else if isSearching {
            query = ""
        } else if categoryFilter != nil {
            withAnimation(.easeInOut(duration: 0.22)) { categoryFilter = nil }
        } else {
            close()
        }
    }
}
