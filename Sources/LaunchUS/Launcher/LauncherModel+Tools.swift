import AppKit
import SwiftUI

// Multi-select and the layout tools in settings (backups, imports, sorting).

extension LauncherModel {
    // MARK: - Multi-select

    func toggleMultiSelect(_ id: String) {
        withAnimation(.easeOut(duration: 0.12)) {
            if multiSelection.contains(id) { multiSelection.remove(id) } else { multiSelection.insert(id) }
        }
    }

    // MARK: - Marquee

    /// Picks the apps on the current page whose icons the dragged rectangle touches.
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
            guard case .app(let app) = entry else { continue }
            let c = m.iconCenter(slot: slot)
            if rect.intersects(CGRect(x: c.x - half, y: c.y - half, width: half * 2, height: half * 2)) { hits.insert(app.id) }
        }
        let picked = base.union(hits)
        if picked != multiSelection { multiSelection = picked }
    }

    func marqueeEnded() {
        withAnimation(.easeOut(duration: 0.12)) { marquee = nil }
        marqueeBase = nil
    }

    /// The selection, in grid order.
    var multiSelectedIDs: [String] {
        layout.joined().flatMap(\.appIDs).filter(multiSelection.contains)
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
        for id in ids { detach(id) }
        layout = layout.filter { !$0.isEmpty }
        if layout.isEmpty { layout = [[]] }
        let items = ids.map(LayoutItem.app)
        if toStart { layout[0].insert(contentsOf: items, at: 0) } else { layout[layout.count - 1].append(contentsOf: items) }
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) {
            if openFolderID != nil, openFolder == nil { dropFolder() }
            commitLayout()
        }
    }

    /// Puts the selected apps into a new folder where the first one was.
    func folderFromSelection() {
        let ids = multiSelectedIDs
        guard ids.count > 1, let first = ids.first else { return }
        let anchor = location(of: "app:" + first) ?? folderContaining(first).flatMap { location(ofFolder: $0) }
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

    func moveSelection(toFolder folderID: String) {
        let ids = multiSelectedIDs.filter { folderContaining($0) != folderID }
        multiSelection = []
        for id in ids { detach(id) }
        guard let loc = location(ofFolder: folderID), case .folder(var folder) = layout[loc.page][loc.slot] else { return }
        folder.apps.append(contentsOf: ids)
        layout[loc.page][loc.slot] = .folder(folder)
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) {
            if openFolderID != nil, openFolder == nil { dropFolder() }
            commitLayout()
        }
    }

    /// Moves the selected apps to the end of a home page; `layout.count` makes a new page.
    func moveSelection(toPage page: Int) {
        let ids = multiSelectedIDs
        multiSelection = []
        for id in ids { detach(id) }
        layout = layout.filter { !$0.isEmpty }
        let target = min(page, layout.count)
        if target == layout.count { layout.append([]) }
        layout[target].append(contentsOf: ids.map(LayoutItem.app))
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

    func exportBackup(to url: URL) throws {
        let backup = LayoutBackup(pages: layout, meta: meta, custom: customItems, barFolders: barFolders, profiles: profiles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(backup).write(to: url, options: .atomic)
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
            meta = backup.meta
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

    func importBackup(from url: URL) throws {
        let backup = try JSONDecoder().decode(LayoutBackup.self, from: Data(contentsOf: url))
        withCustomItems(backup.custom) { [weak self] in
            guard let self else { return }
            meta = backup.meta
            LayoutStore.save(meta: meta)
            if let folders = backup.barFolders {
                barFolders = folders
                LayoutStore.save(barFolders: folders)
            }
            if let saved = backup.profiles {
                // Older backups have no profiles; those keep the ones here.
                profiles = LayoutProfiles.File(current: backup.profile ?? "", saved: saved)
                LayoutProfiles.save(profiles)
                profilesVersion += 1
            }
            layout = LayoutOps.reconcile(backup.pages, installed: catalog.apps, hidden: hiddenIDs, perPage: perPage, free: freePlacement)
            LayoutStore.save(layout: layout)
            dropFolder()
            currentPage = 0
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
