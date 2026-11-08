import AppKit
import SwiftUI

extension LauncherModel {
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
            withAnimation(self.settings.motion(.spring(response: 0.38, dampingFraction: 0.86), duration: 0.38)) { self.folderExpanded = true }
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
        withAnimation(settings.motion(.spring(response: 0.32, dampingFraction: 1), duration: 0.3), completionCriteria: .logicallyComplete) {
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

    func updateScrollCells() {
        guard settings.pageStyle == .scroll else {
            if !scrollCells.isEmpty { scrollCells = [] }
            return
        }
        var items: [LayoutItem] = []
        var found: [String: ScrollCell] = [:]
        for (p, page) in pages.enumerated() {
            for (s, entry) in page.enumerated() where !entry.isGap {
                found[entry.id] = ScrollCell(pos: GridPos(page: p, slot: s), entry: entry)
                // Only the shape matters to packing; the entry is found again by its ID.
                items.append(entry.widget.map(LayoutItem.widget) ?? .app(entry.id))
            }
        }
        let packed = LayoutOps.pack(items, columns: columns, rows: nil, free: false).page
        let cells = packed.enumerated().map { i, item -> ScrollCell in
            let key: String? = switch item {
            case .widget(let w): "widget:" + w.id
            case .app(let id): id
            default: nil
            }
            return key.flatMap { found[$0] } ?? ScrollCell(pos: nil, entry: .gap("scroll-\(i)"))
        }
        if cells != scrollCells { scrollCells = cells }
    }

    /// Icon centre of an entry in the scrolling grid, in launcher coordinates, if it's in view.
    /// Pages run together there without their empty cells, under the recent row.
    func scrollIconCenter(of entryID: String) -> CGPoint? {
        let m = metrics
        guard let index = scrollCells.firstIndex(where: { $0.entry.id == entryID }) else { return nil }
        let c = CGPoint(x: m.gridOriginX + (CGFloat(index % m.columns) + 0.5) * m.cellSize.width,
                        y: m.gridTop + scrollLead + (CGFloat(index / m.columns) + 0.5) * m.cellSize.height
                            - gridScrollOffset)
        return c.y > m.gridTop - m.cellSize.height / 2 && c.y < m.size.height ? c : nil
    }

    /// Where a folder's tile is drawn on the current home page, if it is visible there.
    func tileRect(ofFolder id: String) -> CGRect? {
        guard !isSearching else { return nil }
        let m = metrics
        let size = m.iconSize * 0.8
        if settings.pageStyle == .scroll {
            // Scrolled out of sight: the panel opens from the middle instead.
            guard let c = scrollIconCenter(of: "folder:" + id) else { return nil }
            return CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)
        }
        guard pages.indices.contains(currentPage),
              let slot = pages[currentPage].firstIndex(where: { $0.id == "folder:" + id }) else { return nil }
        let c = m.iconCenter(slot: slot)
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

    /// Why a shortcut won't work well, or nil. `owner`: nil for the launcher's own shortcut.
    func shortcutConflict(_ spec: HotKeySpec?, owner: String?) -> String? {
        guard let spec else { return nil }
        let prefix = Self.folderShortcutPrefix
        var others = meta.compactMapValues(\.shortcut)
        // The current profile's is the launcher's own shortcut; the others' open their profile.
        for name in profileNames where name != currentProfile {
            if let key = opening(for: name).hotKey { others[Self.profileShortcutPrefix + name] = key }
        }
        return ShortcutConflicts.message(spec, owner: owner, others: others) { id in
            if id.hasPrefix(Self.profileShortcutPrefix) {
                return LayoutProfiles.title(String(id.dropFirst(Self.profileShortcutPrefix.count)))
            }
            return id.hasPrefix(prefix) ? folder(String(id.dropFirst(prefix.count)))?.name : app(id)?.name
        }
    }

    /// Profile shortcuts among the others in conflict checks: "profile:" + the profile's name.
    static let profileShortcutPrefix = "profile:"

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
        if hidden { offerHiddenDotTip() }
    }

    /// The first time something is hidden: point at the dot that brings it back (it's
    /// invisible until hovered).
    func offerHiddenDotTip() {
        if settings.hiddenDotEntrance, settings.pageStyle != .scroll, !isSearching { offerTip(.hiddenDot) }
    }
}
