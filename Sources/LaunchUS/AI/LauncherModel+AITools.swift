import SwiftUI

/// The chat's tools that act on the running launcher: switching layouts, opening groups and
/// arranging the home screen. Each returns what to tell the AI, and whether it worked.
extension LauncherModel {
    typealias ToolOutcome = (text: String, ok: Bool)

    func runLocalTool(_ call: ToolCall) -> ToolOutcome? {
        let input = call.input
        func text(_ key: String) -> String { (input[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch call.name {
        case "switch_layout":
            let name = text("name")
            return switchProfile(named: name) ? ("Switched to the layout \(name).", true) : ("No layout named \(name).", false)
        case "open_group":
            guard let folder = folder(named: text("name")) else { return ("No folder named \(text("name")).", false) }
            openAll(folder.id)
            return ("Opened the apps in \(folder.name).", true)
        case "get_layout":
            return (describeLayout(), true)
        case "move_app":
            return moveItem(text("app"), to: text("to"))
        case "create_folder":
            return createFolder(text("name"), apps: input["apps"] as? [String] ?? [])
        case "rename_folder":
            guard let folder = folder(named: text("name")) else { return ("No folder named \(text("name")).", false) }
            let newName = text("new_name")
            guard !newName.isEmpty else { return ("Missing \"new_name\".", false) }
            renameFolder(folder.id, to: newName)
            return ("Renamed \(folder.name) to \(newName).", true)
        case "dissolve_folder":
            guard let folder = folder(named: text("name")) else { return ("No folder named \(text("name")).", false) }
            dissolveFolder(folder.id)
            return ("Removed the folder \(folder.name); its apps are back on the page.", true)
        case "hide_app":
            guard let app = resolveApp(text("app")) else { return ("No app matches \"\(text("app"))\".", false) }
            let hidden = input["hidden"] as? Bool ?? true
            setHidden(hidden, for: app.id)
            return (hidden ? "Hid \(app.name)." : "\(app.name) shows in the launcher again.", true)
        default:
            return nil
        }
    }

    // MARK: Reading

    /// Every page in order, folders with their apps in brackets.
    func describeLayout() -> String {
        var lines: [String] = []
        if settings.sortOrder != .custom {
            lines.append("Note: the launcher is sorted by \(settings.sortOrder.rawValue), so it shows apps in that order, not this one.")
        }
        for (index, page) in layout.enumerated() {
            let items = page.map { item -> String in
                switch item {
                case .app(let id): return app(id)?.name ?? id
                case .folder(let folder):
                    if folder.isSmart { return "\(folder.name) (smart folder)" }
                    return "\(folder.name) [" + folder.apps.compactMap { app($0)?.name }.joined(separator: ", ") + "]"
                case .widget(let widget): return "(\(widget.kind) widget)"
                case .gap, .cover: return "(empty)"
                }
            }
            lines.append("Page \(index + 1): " + items.joined(separator: ", "))
        }
        return lines.isEmpty ? "The home screen is empty." : lines.joined(separator: "\n")
    }

    /// An app by bundle ID, name or search, hidden ones included.
    func resolveApp(_ text: String) -> AppItem? {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        let all = visibleApps + catalog.apps.filter { meta[$0.id]?.hidden == true }
        return all.first { $0.bundleID?.caseInsensitiveCompare(wanted) == .orderedSame || $0.id == wanted }
            ?? all.first { $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame }
            ?? search(wanted, includeHidden: true).first
    }

    /// A folder (checked first) or an app, as the item the layout holds.
    private func resolveItem(_ text: String) -> (item: LayoutItem, name: String)? {
        if let folder = folder(named: text) { return (.folder(folder), folder.name) }
        guard let app = resolveApp(text) else { return nil }
        return (.app(app.id), app.name)
    }

    /// Where an item sits on the home screen; an app inside a folder answers with the folder's place.
    private func topLevelLocation(_ item: LayoutItem) -> GridPos? {
        if let loc = location(of: item.id) { return loc }
        if case .app(let id) = item, let folderID = folderContaining(id) { return location(ofFolder: folderID) }
        return nil
    }

    // MARK: Arranging

    func moveItem(_ what: String, to where: String) -> ToolOutcome {
        guard settings.sortOrder == .custom else {
            return ("The launcher is sorted by \(settings.sortOrder.rawValue), so its order can't be changed. The user can switch 排序 to 自定义 (right-click the background) first.", false)
        }
        guard let target = LauncherTarget(`where`) else {
            return ("Unknown \"to\": \(`where`). Use first, last, page:N, before:<name>, after:<name>, folder:<name> or out.", false)
        }
        guard let (item, name) = resolveItem(what) else { return ("No app or folder matches \"\(what)\".", false) }
        if case .app(let id) = item, meta[id]?.hidden == true { return ("\(name) is hidden; show it again with hide_app first.", false) }

        switch target {
        case .folder(let folderName):
            guard case .app(let id) = item else { return ("A folder can't go inside another folder.", false) }
            guard let folder = folder(named: folderName), !folder.isSmart else { return ("No folder named \(folderName).", false) }
            guard folderContaining(id) != folder.id else { return ("\(name) is already in \(folder.name).", true) }
            moveApp(id, toFolder: folder.id)
            return ("Moved \(name) into \(folder.name).", true)
        case .out:
            guard case .app(let id) = item, let folderID = folderContaining(id) else { return ("\(name) isn't in a folder.", false) }
            takeOutOfFolder(id, folderID: folderID)
            return ("Took \(name) out of its folder. " + placeDescription(item), true)
        case .before(let other), .after(let other):
            guard let (anchor, anchorName) = resolveItem(other) else { return ("No app or folder matches \"\(other)\".", false) }
            guard anchor.id != item.id else { return ("Pick a different app or folder to move next to.", false) }
            guard topLevelLocation(anchor) != nil else { return ("\(anchorName) isn't on the home screen.", false) }
            detachItem(item)
            guard let loc = topLevelLocation(anchor) else { return ("\(anchorName) isn't on the home screen.", false) }
            let after = if case .after = target { true } else { false }
            layout[loc.page].insert(item, at: loc.slot + (after ? 1 : 0))
        case .first:
            detachItem(item)
            if layout.isEmpty { layout = [[]] }
            layout[0].insert(item, at: 0)
        case .last:
            detachItem(item)
            layout = layout.filter { !$0.isEmpty }
            if layout.isEmpty { layout = [[]] }
            layout[layout.count - 1].append(item)
        case .page(let number):
            detachItem(item)
            layout = layout.filter { !$0.isEmpty }
            let index = min(number - 1, layout.count)
            if index == layout.count { layout.append([]) }
            layout[index].append(item)
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) {
            if openFolderID != nil, openFolder == nil { dropFolder() }
            commitLayout()
        }
        return ("Moved \(name). " + placeDescription(item), true)
    }

    private func placeDescription(_ item: LayoutItem) -> String {
        guard let loc = location(of: item.id) else { return "" }
        return "It's now item \(loc.slot + 1) of \(layout[loc.page].count) on page \(loc.page + 1) of \(layout.count)."
    }

    /// Takes an app out of wherever it is, or a folder off its page.
    private func detachItem(_ item: LayoutItem) {
        switch item {
        case .app(let id): detach(id)
        case .folder(let folder):
            if let loc = location(ofFolder: folder.id) { vacate(page: loc.page, slot: loc.slot) }
        case .widget, .gap, .cover: break
        }
    }

    func createFolder(_ rawName: String, apps names: [String]) -> ToolOutcome {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return ("Missing \"name\".", false) }
        var ids: [String] = []
        for text in names {
            guard let app = resolveApp(text) else { return ("No app matches \"\(text)\".", false) }
            if meta[app.id]?.hidden == true { return ("\(app.name) is hidden.", false) }
            if !ids.contains(app.id) { ids.append(app.id) }
        }
        guard ids.count > 1, let first = ids.first else { return ("A folder needs two or more different apps.", false) }
        let anchor = location(of: "app:" + first) ?? folderContaining(first).flatMap { location(ofFolder: $0) }
        for id in ids { detach(id) }
        let folder = Folder(name: name, apps: ids)
        if layout.isEmpty { layout = [[]] }
        let page = min(anchor?.page ?? currentPage, layout.count - 1)
        layout[page].insert(.folder(folder), at: min(anchor?.slot ?? layout[page].count, layout[page].count))
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) {
            if openFolderID != nil, openFolder == nil { dropFolder() }
            commitLayout()
        }
        return ("Made the folder \(name) with \(ids.compactMap { app($0)?.name }.joined(separator: ", ")). " + placeDescription(.folder(folder)), true)
    }
}
