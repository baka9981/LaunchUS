import AppKit

/// `LaunchUS --mcp`: a Model Context Protocol server on stdin/stdout, so AI tools can find,
/// open and quit apps and drive the launcher. Runs without any UI; launcher actions go to the
/// running app through `launchus://` links.
enum MCPServer {
    static let protocolVersion = "2025-06-18"

    struct Tool {
        let name: String
        let description: String
        let properties: [String: [String: Any]]
        let required: [String]
        /// MCP tool hints: readOnlyHint, destructiveHint, idempotentHint.
        var annotations: [String: Bool] = [:]

        var json: [String: Any] {
            var json: [String: Any] = ["name": name, "description": description,
                                       "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
            if !annotations.isEmpty { json["annotations"] = annotations }
            return json
        }
    }

    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private static func integer(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
    private static let readOnly = ["readOnlyHint": true]
    private static let destructive = ["readOnlyHint": false, "destructiveHint": true]
    private static let additive = ["readOnlyHint": false, "destructiveHint": false]

    /// The groups `get_layout_settings` and the other settings tools take.
    static let settingsGroups = "display, appearance, organize, general (how it opens, login, menu bar and Dock), behavior, apps or ai"

    static let tools: [Tool] = [
        Tool(name: "search_apps", description: "Search the installed apps the way LaunchUS does (names, pinyin, initials, aliases). Returns name, bundle ID and path.",
             properties: ["query": string("What to look for, e.g. \"safari\", \"微信\" or \"wx\""),
                          "limit": ["type": "integer", "description": "Most results to return (default 10)"]],
             required: ["query"]),
        Tool(name: "list_apps", description: "List every app LaunchUS shows, with bundle IDs and paths.",
             properties: [:], required: []),
        Tool(name: "open_app", description: "Open an app, found by bundle ID, path or name.",
             properties: ["app": string("Bundle ID, path, or name of the app")], required: ["app"]),
        Tool(name: "quit_app", description: "Quit a running app. Unsaved work may prompt; set force to quit at once.",
             properties: ["app": string("Bundle ID or name of the app"),
                          "force": ["type": "boolean", "description": "Force quit (unsaved changes are lost)"]],
             required: ["app"]),
        Tool(name: "running_apps", description: "List the apps that are running now.", properties: [:], required: []),
        Tool(name: "list_folders", description: "List the launcher's folders and the apps in each.", properties: [:], required: []),
        Tool(name: "open_folder", description: "Show the launcher with a folder open.",
             properties: ["name": string("Folder name")], required: ["name"]),
        Tool(name: "open_group", description: "Open every app in a folder at once.",
             properties: ["name": string("Folder name")], required: ["name"]),
        Tool(name: "show_launcher", description: "Show the LaunchUS launcher.", properties: [:], required: []),
        Tool(name: "search", description: "Show the launcher with something typed in its search field.",
             properties: ["query": string("Text to search for")], required: ["query"]),
        Tool(name: "list_layouts", description: "List the saved layouts and which one is in use.", properties: [:], required: []),
        Tool(name: "switch_layout", description: "Switch the launcher to another saved layout.",
             properties: ["name": string("Layout name; \"default\" is the default layout")], required: ["name"]),
    ] + appTools

    /// Tools the running app runs (`MCPBridge`): they change its live layouts, settings and widgets.
    /// The built-in chat runs them directly (`LauncherModel.runLocalTool`).
    static let appTools: [Tool] = [
        // Layouts (profiles): each has its own pages, settings and way to open.
        Tool(name: "create_layout", description: "Create a new layout (a profile with its own pages and settings) and switch to it. It starts without a shortcut, F4, pinch or hot corner of its own.",
             properties: ["name": string("Name for the new layout"),
                          "mode": string("How it's shown: \"fullScreen\" or \"window\" (default: like the layout in use)"),
                          "pages": string("\"copy\" copies the pages of the layout in use (the default); \"by_name\" puts every app in name order"),
                          "settings_from": string("The layout whose settings it starts with (default: the one in use)")],
             required: ["name"], annotations: additive),
        Tool(name: "duplicate_layout", description: "Copy a layout, with its pages and settings, under a new name and switch to the copy. The copy has no shortcut, F4, pinch or hot corner of its own.",
             properties: ["name": string("The layout to copy; \"default\" is the default layout"),
                          "new_name": string("Name for the copy")],
             required: ["name", "new_name"], annotations: additive),
        Tool(name: "rename_layout", description: "Rename a layout. The default layout can't be renamed.",
             properties: ["name": string("The layout's name now"), "new_name": string("The new name")],
             required: ["name", "new_name"], annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true]),
        Tool(name: "delete_layout", description: "Delete a layout for good: its pages, settings, hidden-app list, automatic backups and AI chats are removed and can't be brought back. The default layout can't be deleted. Deleting the layout in use switches to the default one.",
             properties: ["name": string("The layout to delete")], required: ["name"], annotations: destructive),
        // Settings
        Tool(name: "get_layout_settings", description: "Read a layout's settings by group (\(settingsGroups)), as JSON: group, then setting, then value. Values are in the form set_layout_settings takes.",
             properties: ["layout": string("Layout name (default: the one in use)"),
                          "group": string("One group; leave out for all of them")],
             required: [], annotations: readOnly),
        Tool(name: "set_layout_settings", description: "Change settings in one group of a layout. Call get_layout_settings first for the setting names and the form of their values; values out of range are brought into range.",
             properties: ["layout": string("Layout name (default: the one in use)"),
                          "group": string("The group the settings are in: \(settingsGroups)"),
                          "values": ["type": "object", "description": "Setting name to new value, e.g. {\"columns\": 8, \"hideNames\": true}"]],
             required: ["group", "values"], annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true]),
        Tool(name: "copy_layout_settings", description: "Copy one group of settings from another layout into the layout in use, replacing its settings in that group. Afterwards each layout changes on its own.",
             properties: ["from": string("The layout to copy from"),
                          "group": string("The group to copy: \(settingsGroups)")],
             required: ["from", "group"], annotations: ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": true]),
        // Widgets
        Tool(name: "list_widget_kinds", description: "List the widgets that can be added (built in and plugins), with their kind IDs and sizes: small (2×2 cells), medium (4×2) and large (4×4).",
             properties: [:], required: [], annotations: readOnly),
        Tool(name: "list_widgets", description: "List the widgets on the home screen of the layout in use, with their IDs, sizes and where they are.",
             properties: [:], required: [], annotations: readOnly),
        Tool(name: "add_widget", description: "Add a widget to the home screen of the layout in use. The apps there move along to make room.",
             properties: ["kind": string("The widget's kind ID from list_widget_kinds, e.g. \"launchus.clock\", or its name"),
                          "size": string("small (2×2), medium (4×2) or large (4×4); default small. A widget that doesn't come in that size gets the nearest one"),
                          "page": integer("Page number, 1-based (default 1); one past the last page adds a page"),
                          "row": integer("Row of its top-left cell, 1-based (default 1)"),
                          "column": integer("Column of its top-left cell, 1-based (default 1)")],
             required: ["kind"], annotations: additive),
        Tool(name: "remove_widget", description: "Remove a widget from the home screen. What it holds (a note's text, a timer) is deleted and can't be brought back.",
             properties: ["widget": string("The widget's ID from list_widgets, or its kind or name when there's only one of it")],
             required: ["widget"], annotations: destructive),
    ]

    static let appToolNames = Set(appTools.map(\.name))

    // MARK: Loop

    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) else {
                write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let batch = message as? [[String: Any]] {
                let replies = batch.compactMap(handle)
                if !replies.isEmpty { write(replies) }
            } else if let single = message as? [String: Any], let reply = handle(single) {
                write(reply)
            }
        }
        exit(0)
    }

    private static func write(_ object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    /// The reply to one message; nil for notifications.
    static func handle(_ message: [String: Any]) -> [String: Any]? {
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            result = ["protocolVersion": params["protocolVersion"] as? String ?? protocolVersion,
                      "capabilities": ["tools": [String: Any]()],
                      "serverInfo": ["name": "launchus", "title": "LaunchUS", "version": version],
                      "instructions": "LaunchUS is the user's Mac app launcher. Use search_apps to find an app before opening or quitting it. Layouts are profiles with their own pages, settings and widgets; read before changing (list_layouts, get_layout_settings, list_widgets)."]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": tools.map(\.json)]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                result = ["content": [["type": "text", "text": try call(name, arguments)]], "isError": false]
            } catch {
                result = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
            }
        default:
            guard id != nil else { return nil }
            return ["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
        guard let id else { return nil }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    // MARK: Tools

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// A call whose arguments are still JSON text (from the built-in chat).
    static func call(_ name: String, json: String) throws -> String {
        let input = json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return try call(name, input ?? [:])
    }

    static func call(_ name: String, _ arguments: [String: Any]) throws -> String {
        func text(_ key: String) throws -> String {
            let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { throw Failure("Missing \"\(key)\".") }
            return value
        }
        switch name {
        case "search_apps":
            let limit = max(1, (arguments["limit"] as? Int) ?? 10)
            let found = Array(search(try text("query")).prefix(limit))
            return found.isEmpty ? "No app matches." : describe(found)
        case "list_apps":
            let list = apps()
            return "\(list.count) apps:\n" + describe(list)
        case "open_app":
            let app = try resolve(try text("app"))
            guard NSWorkspace.shared.open(app.url) else { throw Failure("Couldn't open \(app.name).") }
            return "Opened \(app.name)."
        case "quit_app":
            let query = try text("app")
            let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            let target = running.first { $0.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame }
                ?? (try? resolve(query)).flatMap { app in running.first { $0.bundleIdentifier == app.bundleID || $0.bundleURL == app.url } }
                ?? running.first { $0.localizedName?.localizedCaseInsensitiveContains(query) == true }
            guard let target else { throw Failure("\(query) isn't running.") }
            let force = arguments["force"] as? Bool ?? false
            let sent = force ? target.forceTerminate() : target.terminate()
            let title = target.localizedName ?? query
            guard sent else { throw Failure("\(title) didn't accept the request to quit.") }
            return force ? "Force quit \(title)." : "Asked \(title) to quit."
        case "running_apps":
            let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            return running.map { "\($0.localizedName ?? "?") — \($0.bundleIdentifier ?? "")\($0.isActive ? " (in front)" : "")" }
                .joined(separator: "\n")
        case "list_folders":
            let names = Dictionary(apps().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            let folders = (LayoutStore.loadLayout() ?? []).joined().compactMap { item -> Folder? in
                if case .folder(let folder) = item { folder } else { nil }
            }
            guard !folders.isEmpty else { return "No folders." }
            return folders.map { folder in
                if let query = folder.query { return "\(folder.name) (smart folder: \(query))" }
                return "\(folder.name): " + folder.apps.compactMap { names[$0] }.joined(separator: ", ")
            }.joined(separator: "\n")
        case "open_folder":
            return try openLink("folder", ["name": try text("name")], done: "Opened the folder in LaunchUS.")
        case "open_group":
            return try openLink("openall", ["name": try text("name")], done: "Asked LaunchUS to open the folder's apps.")
        case "show_launcher":
            return try openLink("open", [:], done: "Showed LaunchUS.")
        case "search":
            return try openLink("search", ["q": try text("query")], done: "Showed LaunchUS with the search.")
        case "list_layouts":
            let file = LayoutProfiles.load()
            return LayoutProfiles.names(file).map { ($0.isEmpty ? "default" : $0) + ($0 == file.current ? " (in use)" : "") }
                .joined(separator: "\n")
        case "switch_layout":
            return try openLink("layout", ["name": try text("name")], done: "Asked LaunchUS to switch layouts.")
        case _ where appToolNames.contains(name):
            return try MCPBridge.send(name, arguments)
        default:
            throw Failure("Unknown tool: \(name)")
        }
    }

    private static func openLink(_ command: String, _ query: [String: String], done: String) throws -> String {
        var parts = URLComponents()
        parts.scheme = URLCommand.scheme
        parts.host = command
        if !query.isEmpty { parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = parts.url, NSWorkspace.shared.open(url) else { throw Failure("Couldn't reach LaunchUS.") }
        return done
    }

    // MARK: Apps

    /// What the launcher shows: renamed as the user renamed them, hidden ones left out.
    static func apps() -> [AppItem] {
        let meta = LayoutStore.loadMeta()
        return AppScanner.scan().compactMap { app in
            let extra = meta[app.id]
            if extra?.hidden == true { return nil }
            if let name = extra?.displayName, !name.isEmpty { return app.renamed(name) }
            return app
        }
    }

    static func search(_ query: String) -> [AppItem] {
        let meta = LayoutStore.loadMeta()
        return AppSearch.search(query, in: apps(),
                                aliases: meta.compactMapValues { $0.aliases.isEmpty ? nil : $0.aliases },
                                tags: meta.compactMapValues { $0.tags.isEmpty ? nil : $0.tags })
    }

    static func resolve(_ text: String) throws -> AppItem {
        let list = apps()
        if let app = list.first(where: { $0.bundleID?.caseInsensitiveCompare(text) == .orderedSame || $0.url.path == text }) {
            return app
        }
        if let app = list.first(where: { $0.name.caseInsensitiveCompare(text) == .orderedSame }) { return app }
        guard let app = search(text).first else { throw Failure("No app matches \"\(text)\".") }
        return app
    }

    private static func describe(_ apps: [AppItem]) -> String {
        apps.map { "\($0.name) — \($0.bundleID ?? "no bundle ID") — \($0.url.path)" }.joined(separator: "\n")
    }
}
