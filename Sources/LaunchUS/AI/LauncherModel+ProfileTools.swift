import Foundation

/// The AI tools for layout profiles, their settings and the home screen's widgets
/// (`MCPServer.appTools`), run by the built-in chat and, through `MCPBridge`, by `LaunchUS --mcp`.
/// They use the same model code as the menus and the settings window.
extension LauncherModel {
    func runProfileTool(_ call: ToolCall) -> ToolOutcome? {
        let input = call.input
        func text(_ key: String) -> String { (input[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch call.name {
        case "create_layout":
            return createLayoutTool(text("name"), mode: text("mode"), pages: text("pages"), settingsFrom: text("settings_from"))
        case "duplicate_layout":
            return duplicateLayoutTool(text("name"), as: text("new_name"))
        case "rename_layout":
            return renameLayoutTool(text("name"), to: text("new_name"))
        case "delete_layout":
            return deleteLayoutTool(text("name"))
        case "get_layout_settings":
            return layoutSettingsTool(text("layout"), group: text("group"))
        case "set_layout_settings":
            return setLayoutSettingsTool(text("layout"), group: text("group"), values: input["values"])
        case "copy_layout_settings":
            return copyLayoutSettingsTool(from: text("from"), group: text("group"))
        case "list_widget_kinds":
            return (describeWidgetKinds(), true)
        case "list_widgets":
            return (describeWidgets(), true)
        case "add_widget":
            return addWidgetTool(text("kind"), size: text("size"), page: input["page"], row: input["row"], column: input["column"])
        case "remove_widget":
            return removeWidgetTool(text("widget"))
        default:
            return nil
        }
    }

    // MARK: Layouts

    /// How the tools name a profile: "default" for the built-in one.
    private func layoutLabel(_ name: String) -> String { name.isEmpty ? "default" : name }

    /// A profile named in a tool's arguments; empty means the one in use when `optional`.
    private func layoutNamed(_ text: String, optional: Bool = false) -> Result<String, ToolFailure> {
        if text.isEmpty {
            return optional ? .success(profiles.current) : .failure(ToolFailure("Missing the layout's name."))
        }
        guard let name = LayoutProfiles.resolve(text, in: profiles) else {
            let known = profileNames.map(layoutLabel).joined(separator: ", ")
            return .failure(ToolFailure("No layout named \(text). The layouts are: \(known)."))
        }
        return .success(name)
    }

    struct ToolFailure: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    /// A free name for a new or renamed profile.
    private func newLayoutName(_ text: String, renaming: String? = nil) -> Result<String, ToolFailure> {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .failure(ToolFailure("Missing the new name.")) }
        if let other = LayoutProfiles.resolve(name, in: profiles), other != renaming {
            return .failure(ToolFailure("There's already a layout named \(layoutLabel(other))."))
        }
        return .success(name)
    }

    private func switchedNote(_ name: String) -> String {
        if relaunchingForLanguage { return " LaunchUS is restarting in that layout's language." }
        return profiles.current == name ? " It's the layout in use now." : ""
    }

    func createLayoutTool(_ rawName: String, mode rawMode: String, pages: String, settingsFrom: String) -> ToolOutcome {
        let name: String, source: String
        switch newLayoutName(rawName) {
        case .success(let n): name = n
        case .failure(let f): return (f.text, false)
        }
        switch layoutNamed(settingsFrom, optional: true) {
        case .success(let n): source = n
        case .failure(let f): return (f.text, false)
        }
        let mode: DisplayMode
        switch rawMode.lowercased().replacingOccurrences(of: "_", with: "") {
        case "": mode = settings.displayMode
        case "fullscreen", "full": mode = .fullScreen
        case "window", "windowed": mode = .window
        case "ring", "circle", "radial": mode = .ring
        default: return ("Unknown mode \(rawMode). Use fullScreen, window or ring.", false)
        }
        let byName: Bool
        switch pages.lowercased() {
        case "", "copy": byName = false
        case "by_name", "byname", "name", "alphabetical": byName = true
        default: return ("Unknown pages \(pages). Use copy or by_name.", false)
        }
        let pagesNote = byName ? "every app in name order" : "the pages of \(layoutLabel(profiles.current))"
        createProfile(name, mode: mode, copyPages: !byName, settingsFrom: source)
        guard profiles.saved[name] != nil || profiles.current == name else { return ("Couldn't create the layout \(name).", false) }
        return ("Created the layout \(name) (\(mode.rawValue)), with \(pagesNote) and the settings of \(layoutLabel(source))." + switchedNote(name), true)
    }

    func duplicateLayoutTool(_ rawSource: String, as rawName: String) -> ToolOutcome {
        let source: String, name: String
        switch layoutNamed(rawSource) {
        case .success(let n): source = n
        case .failure(let f): return (f.text, false)
        }
        switch newLayoutName(rawName) {
        case .success(let n): name = n
        case .failure(let f): return (f.text, false)
        }
        let pages = source == profiles.current ? layout : profiles.saved[source] ?? layout
        createProfile(name, mode: profileMode(source), pages: pages, settingsFrom: source)
        guard profiles.saved[name] != nil || profiles.current == name else { return ("Couldn't copy the layout \(layoutLabel(source)).", false) }
        return ("Copied \(layoutLabel(source)) to the new layout \(name)." + switchedNote(name), true)
    }

    func renameLayoutTool(_ rawOld: String, to rawName: String) -> ToolOutcome {
        let old: String, name: String
        switch layoutNamed(rawOld) {
        case .success(let n): old = n
        case .failure(let f): return (f.text, false)
        }
        guard !old.isEmpty else { return ("The default layout can't be renamed.", false) }
        switch newLayoutName(rawName, renaming: old) {
        case .success(let n): name = n
        case .failure(let f): return (f.text, false)
        }
        guard name != old else { return ("\(old) already has that name.", true) }
        renameProfile(old, to: name)
        guard profileNames.contains(name) else { return ("Couldn't rename \(old).", false) }
        return ("Renamed the layout \(old) to \(name).", true)
    }

    func deleteLayoutTool(_ rawName: String) -> ToolOutcome {
        let name: String
        switch layoutNamed(rawName) {
        case .success(let n): name = n
        case .failure(let f): return (f.text, false)
        }
        guard !name.isEmpty else { return ("The default layout can't be deleted.", false) }
        let wasCurrent = profiles.current == name
        deleteProfile(name)
        guard !profileNames.contains(name) else { return ("Couldn't delete \(name).", false) }
        return ("Deleted the layout \(name)." + (wasCurrent ? " Switched to the default layout." : ""), true)
    }

    // MARK: Settings

    /// Hidden apps stay behind the launcher's own verification, and the AI gateway decides where
    /// the AI key goes: neither is for a tool to change.
    private static let lockedKeys: Set<String> = ["aiBaseURL"]

    private func settingsGroup(_ text: String) -> Result<ProfileSettings.Group, ToolFailure> {
        let wanted = text.lowercased()
        guard let group = ProfileSettings.Group.allCases.first(where: { $0.rawValue == wanted || $0.title.lowercased() == wanted }) else {
            return .failure(ToolFailure("Unknown group \(text). Use \(MCPServer.settingsGroups)."))
        }
        guard group != .hidden else { return .failure(ToolFailure("The hidden apps' settings can only be changed in LaunchUS itself.")) }
        return .success(group)
    }

    /// One saved value ("[8]") as plain JSON (8).
    private static func plain(_ json: String?) -> Any {
        guard let json, let list = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed) as? [Any],
              let value = list.first else { return NSNull() }
        return value
    }

    private static func same(_ a: Any, _ b: Any) -> Bool { (a as AnyObject).isEqual(b) }

    private static func jsonText(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    func layoutSettingsTool(_ rawLayout: String, group rawGroup: String) -> ToolOutcome {
        let name: String
        switch layoutNamed(rawLayout, optional: true) {
        case .success(let n): name = n
        case .failure(let f): return (f.text, false)
        }
        var groups = ProfileSettings.Group.allCases.filter { $0 != .hidden }
        if !rawGroup.isEmpty {
            switch settingsGroup(rawGroup) {
            case .success(let g): groups = [g]
            case .failure(let f): return (f.text, false)
            }
        }
        let isCurrent = name == profiles.current
        let saved = profiles.settings[name]
        // Profiles from before 1.5 take the current settings the first time they're switched to.
        let values = isCurrent || saved == nil ? currentProfileSettings() : saved!
        var result: [String: Any] = [:]
        for group in groups {
            var entries: [String: Any] = [:]
            for field in ProfileSettings.fields where field.group == group {
                entries[field.key] = Self.plain(values[field.key] ?? (isCurrent ? nil : field.capture(settings)))
            }
            result[group.rawValue] = entries
        }
        var answer: [String: Any] = ["layout": layoutLabel(name), "in_use": isCurrent, "settings": result]
        if !isCurrent && saved == nil {
            answer["note"] = "This layout has no settings of its own yet; it takes the ones in use the first time it's switched to."
        }
        return (Self.jsonText(answer), true)
    }

    func setLayoutSettingsTool(_ rawLayout: String, group rawGroup: String, values raw: Any?) -> ToolOutcome {
        let name: String, group: ProfileSettings.Group
        switch layoutNamed(rawLayout, optional: true) {
        case .success(let n): name = n
        case .failure(let f): return (f.text, false)
        }
        switch settingsGroup(rawGroup) {
        case .success(let g): group = g
        case .failure(let f): return (f.text, false)
        }
        guard let changes = raw as? [String: Any], !changes.isEmpty else {
            return ("Missing \"values\": an object of setting names and new values.", false)
        }
        // A waiting profile's values are checked on a scratch copy of the settings, which reads
        // them the way switching to it will.
        let isCurrent = name == profiles.current
        let target: Settings
        if isCurrent {
            target = settings
        } else {
            target = Settings(defaults: ScratchDefaults())
            ProfileSettings.restore(profiles.settings[name] ?? currentProfileSettings(), to: target)
        }
        var lines: [String] = [], changed = false, failed = false
        for key in changes.keys.sorted() {
            let wanted = changes[key]!
            guard let field = ProfileSettings.fields.first(where: { $0.key == key }) else {
                lines.append("\(key): no such setting in \(group.rawValue).")
                failed = true
                continue
            }
            guard field.group == group else {
                lines.append("\(key): it's in the \(field.group.rawValue) group, not \(group.rawValue).")
                failed = true
                continue
            }
            guard !Self.lockedKeys.contains(key) else {
                lines.append("\(key): can only be changed in LaunchUS itself.")
                failed = true
                continue
            }
            guard let data = try? JSONSerialization.data(withJSONObject: [wanted], options: .fragmentsAllowed) else {
                lines.append("\(key): not a JSON value.")
                failed = true
                continue
            }
            let before = Self.plain(field.capture(target))
            field.restore(target, String(decoding: data, as: UTF8.self))
            let saved = field.capture(target)
            let after = Self.plain(saved)
            if Self.same(after, wanted) {
                lines.append("\(key): \(Self.jsonText(after))")
            } else if !Self.same(after, before) {
                lines.append("\(key): \(Self.jsonText(after)) (the nearest it allows to \(Self.jsonText(wanted)))")
            } else {
                lines.append("\(key): stays \(Self.jsonText(before)); \(Self.jsonText(wanted)) isn't a value it takes.")
                failed = true
                continue
            }
            changed = true
            if !isCurrent, let saved { profiles.settings[name, default: [:]][key] = saved }
        }
        if changed && !isCurrent { saveProfiles() }
        let head = changed ? "Changed \(layoutLabel(name))'s \(group.rawValue) settings:" : "Nothing changed:"
        return (([head] + lines).joined(separator: "\n"), changed || !failed)
    }

    func copyLayoutSettingsTool(from rawSource: String, group rawGroup: String) -> ToolOutcome {
        let source: String, group: ProfileSettings.Group
        switch layoutNamed(rawSource) {
        case .success(let n): source = n
        case .failure(let f): return (f.text, false)
        }
        switch settingsGroup(rawGroup) {
        case .success(let g): group = g
        case .failure(let f): return (f.text, false)
        }
        guard source != profiles.current else { return ("\(layoutLabel(source)) is the layout in use; pick another one to copy from.", false) }
        guard profiles.settings[source] != nil else {
            return ("\(layoutLabel(source)) has no settings of its own yet, so there's nothing to copy.", false)
        }
        copySettings(group, from: source)
        return ("Copied the \(group.rawValue) settings of \(layoutLabel(source)) into \(layoutLabel(profiles.current)).", true)
    }

    // MARK: Widgets

    private static func sizeText(_ size: WidgetItem.Size) -> String {
        let (w, h) = size.cells
        return "\(size.rawValue) (\(w)×\(h))"
    }

    private static func size(_ text: String) -> WidgetItem.Size? {
        switch text.lowercased().replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: " ", with: "") {
        case "", "small", "s", "2x2": .small
        case "medium", "m", "4x2": .medium
        case "large", "l", "4x4": .large
        default: nil
        }
    }

    func describeWidgetKinds() -> String {
        WidgetRegistry.shared.reload()
        return WidgetRegistry.shared.all.map { provider in
            let sizes = provider.sizes.map(Self.sizeText).joined(separator: ", ")
            let summary = provider.summary.isEmpty ? "" : " — \(provider.summary)"
            return "\(provider.id) — \(provider.name)\(provider.isPlugin ? " (plugin)" : "") — sizes: \(sizes)\(summary)"
        }.joined(separator: "\n")
    }

    /// The widgets on the pages, with where each starts. Pages are kept packed, so a slot is a cell.
    private var placedWidgets: [(widget: WidgetItem, page: Int, slot: Int)] {
        layout.enumerated().flatMap { page, items in
            items.enumerated().compactMap { slot, item in
                if case .widget(let widget) = item { (widget, page, slot) } else { nil }
            }
        }
    }

    private func widgetName(_ widget: WidgetItem) -> String {
        WidgetRegistry.shared.provider(widget.kind)?.name ?? "\(widget.kind) (plugin not installed)"
    }

    private func place(_ slot: Int, page: Int) -> String {
        let columns = max(1, columns)
        return "page \(page + 1), row \(slot / columns + 1), column \(slot % columns + 1)"
    }

    func describeWidgets() -> String {
        let placed = placedWidgets
        guard !placed.isEmpty else { return "There are no widgets on the home screen of \(layoutLabel(profiles.current))." }
        return placed.map { "\($0.widget.id) — \(widgetName($0.widget)) (\($0.widget.kind)) — \(Self.sizeText($0.widget.size)) — \(place($0.slot, page: $0.page))" }
            .joined(separator: "\n")
    }

    func addWidgetTool(_ kindText: String, size sizeText: String, page: Any?, row: Any?, column: Any?) -> ToolOutcome {
        guard !kindText.isEmpty else { return ("Missing \"kind\".", false) }
        WidgetRegistry.shared.reload()
        let all = WidgetRegistry.shared.all
        guard let provider = all.first(where: { $0.id.caseInsensitiveCompare(kindText) == .orderedSame })
            ?? all.first(where: { $0.id.caseInsensitiveCompare("launchus." + kindText) == .orderedSame })
            ?? all.first(where: { $0.name.localizedCaseInsensitiveCompare(kindText) == .orderedSame }) else {
            return ("No widget kind \(kindText). Call list_widget_kinds for the kinds.", false)
        }
        guard let size = Self.size(sizeText) else { return ("Unknown size \(sizeText). Use small, medium or large.", false) }
        func number(_ value: Any?, _ key: String) -> Result<Int, ToolFailure> {
            guard let value, !(value is NSNull) else { return .success(1) }
            let n = (value as? Int) ?? (value as? String).flatMap { Int($0) }
            guard let n, n >= 1 else { return .failure(ToolFailure("\"\(key)\" must be a number from 1.")) }
            return .success(n)
        }
        let p: Int, r: Int, c: Int
        switch (number(page, "page"), number(row, "row"), number(column, "column")) {
        case (.success(let a), .success(let b), .success(let d)): (p, r, c) = (a, b, d)
        case (.failure(let f), _, _), (_, .failure(let f), _), (_, _, .failure(let f)): return (f.text, false)
        }
        guard canAddWidget else { return ("The launcher is showing search results or a category; widgets go on the home pages. Clear the search first.", false) }
        guard c <= columns else { return ("The grid has \(columns) columns.", false) }
        let pageCount = layout.filter { !$0.isEmpty }.count
        guard p <= max(1, pageCount) + 1 else { return ("There are \(pageCount) pages; use page \(pageCount + 1) at most to add a page.", false) }
        // Empty pages are dropped when laid out again, so "one past the last" is a new page.
        let pageIndex = p - 1 >= pageCount ? layout.count : layoutIndex(ofPage: p - 1)
        guard let widget = addWidget(provider.id, size: size, page: pageIndex, cell: (r - 1) * columns + (c - 1)) else {
            return ("Couldn't add the widget.", false)
        }
        var text = "Added \(provider.name) (\(Self.sizeText(widget.size))), ID \(widget.id)"
        if let at = placedWidgets.first(where: { $0.widget.id == widget.id }) { text += ", at \(place(at.slot, page: at.page))" }
        text += "."
        if widget.size != size { text += " It doesn't come in \(size.rawValue), so it got the nearest size." }
        if p > 1, !(settings.sortOrder == .custom && settings.pageStyle == .paged) {
            text += " The launcher is sorted or scrolls, so widgets go on the first page."
        }
        return (text, true)
    }

    /// The index in `layout` of the nth page that has anything on it.
    private func layoutIndex(ofPage n: Int) -> Int {
        var seen = -1
        for (index, page) in layout.enumerated() where !page.isEmpty {
            seen += 1
            if seen == n { return index }
        }
        return layout.count
    }

    func removeWidgetTool(_ text: String) -> ToolOutcome {
        guard !text.isEmpty else { return ("Missing \"widget\".", false) }
        let placed = placedWidgets
        var matches = placed.filter { $0.widget.id == text }
        if matches.isEmpty {
            matches = placed.filter {
                $0.widget.kind.caseInsensitiveCompare(text) == .orderedSame
                    || $0.widget.kind.caseInsensitiveCompare("launchus." + text) == .orderedSame
                    || widgetName($0.widget).localizedCaseInsensitiveCompare(text) == .orderedSame
            }
        }
        guard !matches.isEmpty else { return ("No widget matches \(text). Call list_widgets for their IDs.", false) }
        guard matches.count == 1, let found = matches.first else {
            return ("There are \(matches.count) of those; give the ID of the one to remove:\n"
                + matches.map { "\($0.widget.id) — \(place($0.slot, page: $0.page))" }.joined(separator: "\n"), false)
        }
        let at = place(found.slot, page: found.page)
        removeWidget(found.widget.id)
        guard location(of: "widget:" + found.widget.id) == nil else { return ("Couldn't remove the widget.", false) }
        return ("Removed \(widgetName(found.widget)) from \(at).", true)
    }
}

/// Settings kept only in memory, for checking a waiting profile's values.
private final class ScratchDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: "LaunchUS.Scratch.\(UUID().uuidString)")! }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}
