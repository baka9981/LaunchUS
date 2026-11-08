import AppKit
import SwiftUI

extension LauncherModel {
    // MARK: - Hidden apps

    /// Opens the hidden apps panel, after Touch ID or the password when that's required.
    func revealHidden() {
        guard !isAuthenticating else { return }
        phantomSlotArmed = false
        if tip == .hiddenDot { dismissTip() }
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

    /// Scroll mode: the secret slot sits right after the last app (there are no pages to pick).
    var phantomScrollSlot: Bool {
        settings.pageStyle == .scroll && settings.hiddenSlotEntrance && !isSearching && categoryFilter == nil && !isEditing
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
        insertItems([.app(appID)], page: loc.page, slot: loc.slot + 1)
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) {
            if openFolderID == folderID, case .app = layout[loc.page][loc.slot] { dropFolder() }
            commitLayout()
        }
    }

    func removeApp(_ appID: String, fromFolder folderID: String) {
        guard let loc = location(ofFolder: folderID), case .folder(var folder) = layout[loc.page][loc.slot] else { return }
        folder.apps.removeAll { $0 == appID }
        layout[loc.page][loc.slot] = folder.apps.count == 1 ? .app(folder.apps[0]) : .folder(folder)
        if folder.apps.isEmpty { vacate(page: loc.page, slot: loc.slot) }
    }

    /// Replaces a folder with its apps; a smart folder is simply removed.
    func dissolveFolder(_ id: String) {
        if let index = barFolders.firstIndex(where: { $0.id == id }) {
            barFolders.remove(at: index)
            LayoutStore.save(barFolders: barFolders)
            refresh()
            return
        }
        guard let loc = location(ofFolder: id), case .folder(let folder) = layout[loc.page][loc.slot] else { return }
        if folder.isSmart || folder.apps.isEmpty {
            vacate(page: loc.page, slot: loc.slot)
        } else {
            layout[loc.page][loc.slot] = .app(folder.apps[0])
            insertItems(folder.apps.dropFirst().map(LayoutItem.app), page: loc.page, slot: loc.slot + 1)
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

    /// Creates (folderID nil) or edits a smart folder. New ones go to the end of the last page,
    /// or only into the smart bar when `onPages` is off.
    /// Returns the folder's ID.
    @discardableResult
    func saveSmartFolder(_ folderID: String?, name: String, query: String, onPages: Bool = true) -> String? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let n = name.trimmingCharacters(in: .whitespaces)
        if let folderID, let index = barFolders.firstIndex(where: { $0.id == folderID }) {
            if !n.isEmpty { barFolders[index].name = n }
            barFolders[index].query = q
            LayoutStore.save(barFolders: barFolders)
            refresh()
            if onPages { setSmartFolder(folderID, onPages: true) }
            return folderID
        } else if let folderID, let loc = location(ofFolder: folderID), case .folder(var f) = layout[loc.page][loc.slot] {
            f.name = n.isEmpty ? f.name : n
            f.query = q
            layout[loc.page][loc.slot] = .folder(f)
            commitLayout()
            if !onPages { setSmartFolder(folderID, onPages: false) }
            return folderID
        } else if !onPages {
            let folder = Folder(name: n.isEmpty ? Self.smartFolderName(for: q) : n, apps: [], query: q)
            barFolders.append(folder)
            LayoutStore.save(barFolders: barFolders)
            if !settings.showCategoryBar { settings.showCategoryBar = true }
            self.query = ""
            refresh()
            return folder.id
        } else {
            let folder = Folder(name: n.isEmpty ? Self.smartFolderName(for: q) : n, apps: [], query: q)
            if layout.isEmpty { layout = [[]] }
            layout[layout.count - 1].append(.folder(folder))
            self.query = ""
            commitLayout()
            return folder.id
        }
    }

    static func smartFolderName(for query: String) -> String {
        let toks = AppSearch.tokens(query)
        guard toks.allSatisfy(\.isTerm) else {
            // A formula names itself: "#工具 ∪ #效率".
            let text = AppSearch.formulaText(toks).replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "@", with: "")
            return text.isEmpty ? String(localized: "智能文件夹") : text
        }
        let (groups, rest) = AppSearch.categories(in: query)
        let (tags, text) = AppSearch.parse(rest)
        let parts = groups.compactMap { $0?.title } + tags + (text.isEmpty ? [] : [text])
        return parts.isEmpty ? String(localized: "智能文件夹") : parts.joined(separator: "、")
    }
}
