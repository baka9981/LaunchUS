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

        var json: [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
        }
    }

    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }

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
    ]

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
                      "instructions": "LaunchUS is the user's Mac app launcher. Use search_apps to find an app before opening or quitting it."]
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
