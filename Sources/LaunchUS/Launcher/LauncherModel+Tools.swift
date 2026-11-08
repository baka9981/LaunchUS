import AppKit
import SwiftUI

// Multi-select and the layout tools in settings (backups, imports, sorting).

extension LauncherModel {
    // MARK: - Multi-select

    /// A picked folder is kept in `multiSelection` under this key, next to the apps' IDs.
    static func folderKey(_ id: String) -> String { "folder:" + id }

    func toggleMultiSelect(_ id: String) {
        withAnimation(.easeOut(duration: 0.12)) {
            if multiSelection.contains(id) { multiSelection.remove(id) } else { multiSelection.insert(id) }
        }
    }

    func isPicked(_ entry: GridEntry) -> Bool {
        switch entry {
        case .app(let app): multiSelection.contains(app.id)
        case .folder(let folder, _): multiSelection.contains(Self.folderKey(folder.id))
        case .widget, .gap: false
        }
    }

    /// A click with the multi-select key held. An app is picked or let go at once. A folder is
    /// picked at once too, with a bubble over it (`folderPick`) offering to pick apps inside
    /// instead; clicking a picked folder lets it go.
    func multiSelectClick(_ entry: GridEntry) {
        switch entry {
        case .app(let app):
            dismissFolderPick()
            toggleMultiSelect(app.id)
        case .folder(let folder, _):
            dismissFolderPick()
            toggleMultiSelect(Self.folderKey(folder.id))
            if multiSelection.contains(Self.folderKey(folder.id)) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { folderPick = folder.id }
            }
        case .widget, .gap:
            break
        }
    }

    /// The answer to `folderPick`: keep the folder picked, or let it go and open it to pick
    /// apps inside.
    func resolveFolderPick(open: Bool) {
        guard let id = folderPick else { return }
        dismissFolderPick()
        guard open else { return }
        if multiSelection.contains(Self.folderKey(id)) { toggleMultiSelect(Self.folderKey(id)) }
        openFolder(id)
    }

    func dismissFolderPick() {
        guard folderPick != nil else { return }
        withAnimation(.easeOut(duration: 0.15)) { folderPick = nil }
    }

    // MARK: - Marquee

    /// Picks the apps and folders on the current page whose icons the dragged rectangle touches.
    func marqueeChanged(from start: CGPoint, to end: CGPoint) {
        let base = marqueeBase ?? multiSelection
        marqueeBase = base
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        marquee = rect
        guard pages.indices.contains(currentPage) else { return }
        let m = metrics
        let half = m.iconSize * 0.4
        var hits = Set<String>()
        for (slot, entry) in pages[currentPage].enumerated() {
            let key: String
            switch entry {
            case .app(let app): key = app.id
            case .folder(let folder, _): key = Self.folderKey(folder.id)
            case .widget, .gap: continue
            }
            let c = m.iconCenter(slot: slot)
            if rect.intersects(CGRect(x: c.x - half, y: c.y - half, width: half * 2, height: half * 2)) { hits.insert(key) }
        }
        let picked = base.union(hits)
        if picked != multiSelection { multiSelection = picked }
    }

    func marqueeEnded() {
        withAnimation(.easeOut(duration: 0.12)) { marquee = nil }
        marqueeBase = nil
    }

    /// The picked apps, in grid order (picked folders aren't in it).
    var multiSelectedIDs: [String] {
        layout.joined().flatMap(\.appIDs).filter(multiSelection.contains)
    }

    /// Everything picked, in grid order: picked folders whole, and the picked apps, those in
    /// folders too (but not those in a folder that is picked itself).
    var multiSelectedItems: [LayoutItem] {
        layout.joined().flatMap { item -> [LayoutItem] in
            switch item {
            case .app(let id): multiSelection.contains(id) ? [item] : []
            case .folder(let folder) where multiSelection.contains(Self.folderKey(folder.id)): [item]
            case .folder(let folder): folder.apps.filter(multiSelection.contains).map(LayoutItem.app)
            case .gap, .widget, .cover: []
            }
        }
    }

    /// The apps the selection holds, for putting into a folder: the picked apps and those of
    /// the picked folders (not smart ones, whose apps come from their condition), in grid order.
    private func selectionAppsForFolder(excluding target: String? = nil) -> (apps: [String], folders: [String]) {
        var apps: [String] = [], folders: [String] = []
        for item in multiSelectedItems {
            switch item {
            case .app(let id): apps.append(id)
            case .folder(let folder) where !folder.isSmart && folder.id != target:
                apps.append(contentsOf: folder.apps)
                folders.append(folder.id)
            default: break
            }
        }
        var seen = Set<String>()
        return (apps.filter { seen.insert($0).inserted }, folders)
    }

    /// Takes an app or a folder out of the layout.
    func lift(_ item: LayoutItem) {
        switch item {
        case .app(let id): detach(id)
        case .folder(let folder):
            if let loc = location(ofFolder: folder.id) { vacate(page: loc.page, slot: loc.slot) }
        case .gap, .widget, .cover: break
        }
    }

    /// Removes an app from wherever it sits in the layout (home grid or a folder).
    func detach(_ id: String) {
        if let folderID = folderContaining(id) {
            removeApp(id, fromFolder: folderID)
        } else if let loc = location(of: "app:" + id) {
            vacate(page: loc.page, slot: loc.slot)
        }
    }

    /// Whether icons stay in the cell they're dropped in, empty cells and all. Other sort
    /// orders don't show the empty cells but keep them, for when custom order comes back.
    var freePlacement: Bool { settings.freePlacement }

    /// Takes whatever is in a cell out: lined up, the icons after it close the gap; placed
    /// freely, the cell is left empty.
    func vacate(page: Int, slot: Int) {
        guard layout.indices.contains(page), layout[page].indices.contains(slot) else { return }
        if freePlacement { layout[page][slot] = .gap } else { layout[page].remove(at: slot) }
    }

    /// Puts items in at a cell, pushing the ones after it along. Placed freely, the push stops
    /// at the first empty cells after them, which the items take up instead.
    func insertItems(_ items: [LayoutItem], page: Int, slot: Int) {
        guard !items.isEmpty, layout.indices.contains(page) else { return }
        if freePlacement, layout[page].count < slot {
            layout[page].append(contentsOf: Array(repeating: LayoutItem.gap, count: slot - layout[page].count))
        }
        let at = min(slot, layout[page].count)
        layout[page].insert(contentsOf: items, at: at)
        guard freePlacement else { return }
        var absorb = items.count
        var i = at + items.count
        while absorb > 0, i < layout[page].count {
            if layout[page][i].isGap { layout[page].remove(at: i); absorb -= 1 } else { i += 1 }
        }
    }

    /// Regular folders an app can be moved into from the right-click menu.
    var folderTargets: [(id: String, name: String)] {
        layout.joined().compactMap { item in
            if case .folder(let f) = item, !f.isSmart { (f.id, f.name) } else { nil }
        }
    }

    func moveApp(_ id: String, toFolder folderID: String) {
        guard folderContaining(id) != folderID else { return }
        detach(id)
        guard let loc = location(ofFolder: folderID), case .folder(var folder) = layout[loc.page][loc.slot] else { return }
        folder.apps.append(id)
        layout[loc.page][loc.slot] = .folder(folder)
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) {
            if openFolderID != nil, openFolder == nil { dropFolder() }
            commitLayout()
        }
    }

    /// Moves an app to the end of a home page; `layout.count` makes a new page.
    func moveApp(_ id: String, toPage page: Int) {
        detach(id)
        layout = layout.filter { !$0.isEmpty }
        let target = min(page, layout.count)
        if target == layout.count { layout.append([]) }
        layout[target].append(.app(id))
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) {
            if openFolderID != nil, openFolder == nil { dropFolder() }
            commitLayout()
        }
    }

    /// Scroll mode has no pages to pick: moves apps to the very start or end of the grid.
    func moveApps(_ ids: [String], toStart: Bool) {
        moveItems(ids.map(LayoutItem.app), toStart: toStart)
    }

    /// Moves apps and folders to the very start or end of the grid.
    func moveItems(_ items: [LayoutItem], toStart: Bool) {
        for item in items { lift(item) }
        layout = layout.filter { !$0.isEmpty }
        if layout.isEmpty { layout = [[]] }
        if toStart { layout[0].insert(contentsOf: items, at: 0) } else { layout[layout.count - 1].append(contentsOf: items) }
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) {
            if openFolderID != nil, openFolder == nil { dropFolder() }
            commitLayout()
        }
    }

    /// Puts the selected apps, and those of the selected folders, into a new folder where the
    /// first of them was. The selected folders are merged into it.
    func folderFromSelection() {
        let (ids, folders) = selectionAppsForFolder()
        guard ids.count > 1, let first = multiSelectedItems.first else { return }
        let anchor: GridPos? = switch first {
        case .folder(let folder): location(ofFolder: folder.id)
        case .app(let id): location(of: "app:" + id) ?? folderContaining(id).flatMap { location(ofFolder: $0) }
        default: nil
        }
        for folder in folders { if let loc = location(ofFolder: folder) { vacate(page: loc.page, slot: loc.slot) } }
        for id in ids { detach(id) }
        let byID = Dictionary(catalog.apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let folder = Folder(name: AppCategoryName.folderName(for: ids.map { byID[$0]?.category }), apps: ids)
        let page = min(anchor?.page ?? currentPage, max(0, layout.count - 1))
        if layout.isEmpty { layout = [[]] }
        layout[page].insert(.folder(folder), at: min(anchor?.slot ?? layout[page].count, layout[page].count))
        multiSelection = []
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) { commitLayout() }
        startRenaming(folder: folder.id)
    }

    func launchSelection() {
        let apps = multiSelectedIDs.compactMap(app)
        multiSelection = []
        apps.forEach { onLaunch?($0) }
    }

    /// The selected apps, and those of the selected folders (which are merged in), go into a folder.
    func moveSelection(toFolder folderID: String) {
        let (all, folders) = selectionAppsForFolder(excluding: folderID)
        let ids = all.filter { folderContaining($0) != folderID }
        multiSelection = []
        for folder in folders { if let loc = location(ofFolder: folder) { vacate(page: loc.page, slot: loc.slot) } }
        for id in ids { detach(id) }
        guard let loc = location(ofFolder: folderID), case .folder(var folder) = layout[loc.page][loc.slot] else { return }
        folder.apps.append(contentsOf: ids)
        layout[loc.page][loc.slot] = .folder(folder)
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) {
            if openFolderID != nil, openFolder == nil { dropFolder() }
            commitLayout()
        }
    }

    /// Moves the selected apps and folders to the end of a home page; `layout.count` makes a new page.
    func moveSelection(toPage page: Int) {
        let items = multiSelectedItems
        multiSelection = []
        for item in items { lift(item) }
        layout = layout.filter { !$0.isEmpty }
        let target = min(page, layout.count)
        if target == layout.count { layout.append([]) }
        layout[target].append(contentsOf: items)
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) {
            if openFolderID != nil, openFolder == nil { dropFolder() }
            commitLayout()
        }
    }

    func addTag(_ tag: String, toSelection ids: [String]) {
        let allHave = ids.allSatisfy { meta(for: $0).tags.contains(tag) }
        for id in ids {
            setMeta(id) { m in
                if allHave { m.tags.removeAll { $0 == tag } } else if !m.tags.contains(tag) { m.tags.append(tag) }
            }
        }
        refresh()
    }

    func hideSelection() {
        let ids = multiSelectedIDs
        multiSelection = []
        for id in ids {
            setMeta(id) { $0.hidden = true }
            if let folderID = folderContaining(id) { removeApp(id, fromFolder: folderID) }
        }
        reconcile(forceSave: true)
        if !ids.isEmpty { offerHiddenDotTip() }
    }

    /// Moves the selected apps out of their folders, onto the end of the current page.
    func takeSelectionOutOfFolders() {
        let ids = multiSelectedIDs.filter { folderContaining($0) != nil }
        for id in ids { detach(id) }
        if layout.isEmpty { layout = [[]] }
        let page = min(currentPage, layout.count - 1)
        layout[page].append(contentsOf: ids.map(LayoutItem.app))
        multiSelection = []
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) {
            if openFolderID != nil, openFolder == nil { dropFolder() }
            commitLayout()
        }
    }

    // MARK: - Layout tools (settings)

    /// Moves everything forward so only the last page has gaps.
    func compactLayout() {
        layout = LayoutOps.repack([Array(layout.joined())], perPage: perPage)
        LayoutStore.save(layout: layout)
        currentPage = 0
        refresh()
    }

    /// Back to a fresh, alphabetical layout without folders.
    func resetLayout() {
        layout = LayoutOps.alphabetical(catalog.apps.filter { meta[$0.id]?.hidden != true }, perPage: perPage)
        LayoutStore.save(layout: layout)
        dropFolder()
        currentPage = 0
        refresh()
    }

    /// Rebuilds the layout from rules chosen in settings.
    func applyRules(_ rules: LayoutRules) {
        var colors: [String: IconColor] = [:]
        if rules.order == .color {
            for (id, image) in catalog.icons { colors[id] = IconColor.of(image) }
        }
        replaceLayout(LayoutOps.arranged(catalog.apps, current: layout, hidden: hiddenIDs, rules: rules,
                                         perPage: perPage, colors: colors))
    }

    /// Takes every app out of its folder, leaving it where the folder was.
    func ungroupAllFolders() {
        replaceLayout(LayoutOps.ungrouped(layout, perPage: perPage))
    }

    /// Gathers all folders at the start or the end of the pages.
    func moveAllFolders(toStart: Bool) {
        replaceLayout(LayoutOps.foldersMoved(layout, toStart: toStart, perPage: perPage))
    }

    private func replaceLayout(_ pages: [[LayoutItem]]) {
        layout = pages
        LayoutStore.save(layout: layout)
        dropFolder()
        currentPage = 0
        refresh()
    }

    /// The chosen profiles' pages, settings and hidden apps, with the apps' names, tags, icons,
    /// launch items and bar folders they share.
    func backup(of names: [String]) -> LayoutBackup {
        let chosen = profileNames.filter { names.contains($0) }
        let first = chosen.contains(profiles.current) ? profiles.current : chosen.first ?? profiles.current
        let pages = { [self] (name: String) in name == profiles.current ? layout : profiles.saved[name] ?? [] }
        var values: [String: [String: String]] = [:]
        for name in chosen {
            values[name] = name == profiles.current ? currentProfileSettings() : profiles.settings[name]
        }
        // The apps' extras carry the first profile's hidden apps, as in older backups.
        let hidden = ProfileSettings.hiddenApps(in: values[first]) ?? []
        var shared = meta
        for id in Set(shared.keys).union(hidden) {
            var m = shared[id] ?? AppMeta()
            m.hidden = hidden.contains(id)
            shared[id] = m
        }
        var backup = LayoutBackup(pages: pages(first), meta: shared, custom: customItems, barFolders: barFolders)
        backup.profile = first
        backup.profiles = Dictionary(uniqueKeysWithValues: chosen.filter { $0 != first }.map { ($0, pages($0)) })
        backup.settings = values
        return backup
    }

    func exportBackup(of names: [String], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(backup(of: names)).write(to: url, options: .atomic)
    }

    /// A free name for an imported profile that shouldn't replace the one called `name`, also
    /// not one of `taken` (the names the other imported profiles get).
    func unusedProfileName(like name: String, avoiding taken: Set<String> = []) -> String {
        let base = LayoutProfiles.title(name)
        var n = 2
        while LayoutProfiles.resolve("\(base) \(n)", in: profiles) != nil || taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Brings in profiles from a backup, each under the name it's given: an existing profile of
    /// that name is replaced, any other name is added. The apps' names, tags and icons, launch
    /// items and bar folders in the file join the ones here.
    func importProfiles(_ chosen: [(profile: LayoutBackup.Profile, as: String)], from backup: LayoutBackup) {
        guard !chosen.isEmpty, drag == nil else { return }
        AutoBackup.snapshot()
        let missing = (backup.custom ?? []).filter { item in !customItems.contains { $0.id == item.id } }
        withCustomItems(missing.isEmpty ? nil : customItems + missing) { [self] in
            var merged = meta
            for (id, theirs) in backup.meta {
                var m = theirs
                m.hidden = meta[id]?.hidden ?? false
                merged[id] = m
            }
            meta = merged
            LayoutStore.save(meta: meta)
            let newBar = (backup.barFolders ?? []).filter { f in !barFolders.contains { $0.id == f.id } }
            if !newBar.isEmpty {
                barFolders += newBar
                LayoutStore.save(barFolders: barFolders)
            }
            var current: LayoutBackup.Profile?
            for (profile, rawName) in chosen {
                let name = LayoutProfiles.resolve(rawName, in: profiles) ?? rawName.trimmingCharacters(in: .whitespaces)
                if name == profiles.current {
                    current = profile
                    continue
                }
                profiles.saved[name] = profile.pages
                var values = profile.settings ?? profiles.settings[name] ?? {
                    // An older backup has no settings: a new profile starts from these, without ways to open it.
                    var v = currentProfileSettings()
                    ProfileSettings.clearOpening(in: &v)
                    return v
                }()
                if profile.settings == nil, ProfileSettings.hiddenApps(in: values) == nil {
                    ProfileSettings.setHiddenApps([], in: &values)
                }
                profiles.settings[name] = values
            }
            LayoutProfiles.save(profiles)
            profilesVersion += 1
            if let current {
                takeOn(current.pages, settings: current.settings, reopen: false)
            } else {
                NotificationCenter.default.post(name: Self.triggersChanged, object: nil)
                refresh()
            }
        }
    }

    /// Takes over the system Launchpad's pages and folders; names, tags and hidden apps stay.
    func importLaunchpad(from url: URL) throws {
        let pages = try LaunchpadImport.read(url)
        AutoBackup.snapshot()
        layout = LayoutOps.reconcile(pages, installed: catalog.apps, hidden: hiddenIDs, perPage: perPage, free: freePlacement)
        LayoutStore.save(layout: layout)
        dropFolder()
        currentPage = 0
        refresh()
    }

    /// A newer layout from another Mac (iCloud sync). Waits for a drag to finish.
    func applySynced(_ backup: LayoutBackup) {
        guard drag == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.applySynced(backup) }
            return
        }
        AutoBackup.snapshot()
        ICloudSync.applying = true
        defer { ICloudSync.applying = false }
        withCustomItems(backup.custom) { [weak self] in
            guard let self else { return }
            ICloudSync.applying = true
            defer { ICloudSync.applying = false }
            let ownHidden = hiddenIDs
            meta = backup.meta
            if let profile = backup.profile, profile != profiles.current {
                // Those are the other profile's hidden apps; this one keeps its own.
                let theirs = Set(backup.meta.filter { $0.value.hidden }.map(\.key))
                ProfileSettings.setHiddenApps(theirs, in: &profiles.settings[profile, default: [:]])
                applyHiddenApps(ownHidden)
            }
            LayoutStore.save(meta: meta)
            if let folders = backup.barFolders {
                barFolders = folders
                LayoutStore.save(barFolders: folders)
            }
            if let profile = backup.profile, profile != profiles.current {
                // The other Mac is on another layout profile: update that one, not the one on screen.
                profiles.saved[profile] = backup.pages
                LayoutProfiles.save(profiles)
                profilesVersion += 1
                refresh()
                return
            }
            layout = LayoutOps.reconcile(backup.pages, installed: catalog.apps, hidden: hiddenIDs, perPage: perPage, free: freePlacement)
            LayoutStore.save(layout: layout)
            if let id = openFolderID, location(ofFolder: id) == nil { dropFolder() }
            currentPage = min(currentPage, max(0, layout.count - 1))
            refresh()
        }
    }

    func openSettings(_ tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        isEditing = false
        sheet = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { showSettings = true }
    }

    func closeSettings() {
        if tuner != nil {
            // A tuning panel goes back to the settings it came from.
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { tuner = nil }
            return
        }
        withAnimation(.easeOut(duration: 0.18)) { showSettings = false }
        focusRequest += 1
    }

    func openTuner(_ which: Tuner) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { tuner = which }
    }

    static func cleaned(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Splits user input on commas, 、 and semicolons.
    static func splitList(_ text: String) -> [String] {
        cleaned(text.split(whereSeparator: { ",，、;；\n".contains($0) }).map(String.init))
    }
}
