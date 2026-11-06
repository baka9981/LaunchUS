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
        return p.indices.contains(pos.page) && p[pos.page].indices.contains(pos.slot)
    }

    func moveSelection(dx: Int, dy: Int) {
        let p = selectablePages
        let cols = openFolderID != nil ? folderColumns : columns
        let visiblePage = openFolderID != nil ? (folderScrolls ? 0 : folderPage) : currentPage
        guard var pos = selection, isValid(pos) else {
            if p.indices.contains(visiblePage), !p[visiblePage].isEmpty { selection = GridPos(page: visiblePage, slot: 0) }
            return
        }
        if dx != 0 {
            pos.slot += dx
            if pos.slot < 0 {
                if pos.page > 0 { pos.page -= 1; pos.slot = p[pos.page].count - 1 } else { pos.slot = 0 }
            } else if pos.slot >= p[pos.page].count {
                if pos.page + 1 < p.count { pos.page += 1; pos.slot = 0 } else { pos.slot = p[pos.page].count - 1 }
            }
        }
        if dy != 0 {
            let target = pos.slot + dy * cols
            if target >= 0 && target < p[pos.page].count { pos.slot = target }
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
        let session = ChatSession()
        session.local = { [weak self] call in self?.runLocalTool(call) }
        withAnimation(.easeOut(duration: 0.2)) { chat = session }
        query = ""
        session.send(text)
    }

    /// Tools from the chat that act on the launcher itself.
    private func runLocalTool(_ call: ToolCall) -> String? {
        let name = (call.input["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        switch call.name {
        case "switch_layout":
            return switchProfile(named: name) ? "Switched to the layout \(name)." : "No layout named \(name)."
        case "open_group":
            guard let folder = folder(named: name) else { return "No folder named \(name)." }
            openAll(folder.id)
            return "Opened the apps in \(folder.name)."
        default:
            return nil
        }
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
        switch entry {
        case .app(let app):
            if !isEditing { launch(app) }
        case .folder(let folder, _):
            openFolder(folder.id)
        }
    }



    func updateFrequentApps() {
        guard settings.showFrequent else {
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
        let state = NewApps.update(newApps ?? NewApps.load(), apps: catalog.apps)
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
        }
    }

    /// 1…9 for the first nine items of the page on screen, while ⌘ is held.
    /// With the recent apps row showing, ⌘1…⌘9 open its apps instead of the page's first nine.
    var shortcutsUseRecentRow: Bool {
        settings.showFrequent && !frequentApps.isEmpty && !isSearching && openFolderID == nil
    }

    func frequentShortcutNumber(of app: AppItem) -> Int? {
        guard showShortcutNumbers, shortcutsUseRecentRow,
              let index = frequentApps.firstIndex(where: { $0.id == app.id }), index < 9 else { return nil }
        return index + 1
    }

    func shortcutNumber(of entry: GridEntry) -> Int? {
        guard showShortcutNumbers, !shortcutsUseRecentRow, openFolderID == nil, pages.indices.contains(currentPage),
              let index = pages[currentPage].firstIndex(where: { $0.id == entry.id }), index < 9 else { return nil }
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
        guard openFolderID == nil, pages.indices.contains(currentPage), number >= 1,
              number <= pages[currentPage].count else { return }
        showShortcutNumbers = false
        activate(pages[currentPage][number - 1])
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
        if showGuide {
            finishGuide()
        } else if showWhatsNew {
            finishWhatsNew()
        } else if showSettings {
            closeSettings()
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
        if showGuide {
            finishGuide()
        } else if showWhatsNew {
            finishWhatsNew()
        } else if showSettings {
            closeSettings()
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
        } else {
            close()
        }
    }
}
