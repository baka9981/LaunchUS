import Foundation

/// How far the chat may act on LaunchUS.
enum AIToolAccess: String, CaseIterable, Codable {
    case off, readOnly, confirm

    var title: String {
        switch self {
        case .off: String(localized: "关闭")
        case .readOnly: String(localized: "只能查询")
        case .confirm: String(localized: "操作前确认")
        }
    }

    var detail: String {
        switch self {
        case .off: String(localized: "AI 只聊天，不碰你的 App")
        case .readOnly: String(localized: "可以搜索和查看 App、文件夹、布局，不能打开、退出或整理")
        case .confirm: String(localized: "查询直接进行；打开 App、整理主屏幕、切换布局等先问你，退出 App 总要确认")
        }
    }
}

/// The MCP tools the built-in chat may use, and how each is shown and guarded.
enum AITools {
    /// Run without asking.
    static let readOnly: Set<String> = ["search_apps", "list_apps", "running_apps", "list_folders", "list_layouts", "get_layout"]
    /// Asked first, unless allowed for the whole chat.
    static let actions: Set<String> = ["open_app", "open_group", "switch_layout", "quit_app",
                                       "move_app", "create_folder", "rename_folder", "dissolve_folder", "hide_app"]

    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }

    /// Tools only the built-in chat has: they edit the live layout, so they run inside the app.
    static let launcherTools: [MCPServer.Tool] = [
        .init(name: "get_layout", description: "Show the home screen in order: each page with its apps and folders (folder contents in brackets). Call this before moving things.",
              properties: [:], required: []),
        .init(name: "move_app", description: "Move an app (or a folder, by its name) on the home screen.",
              properties: ["app": string("App name or bundle ID, or a folder's name"),
                           "to": string("Where: \"first\", \"last\", \"page:N\" (end of page N, 1-based), \"before:<app or folder>\", \"after:<app or folder>\", \"folder:<folder name>\" (into a folder), or \"out\" (out of its folder)")],
              required: ["app", "to"]),
        .init(name: "create_folder", description: "Put apps together in a new folder, where the first app was.",
              properties: ["name": string("Folder name"),
                           "apps": ["type": "array", "items": ["type": "string"], "description": "Two or more app names or bundle IDs"]],
              required: ["name", "apps"]),
        .init(name: "rename_folder", description: "Rename a folder.",
              properties: ["name": string("The folder's name now"), "new_name": string("The new name")], required: ["name", "new_name"]),
        .init(name: "dissolve_folder", description: "Remove a folder, putting its apps back on the page.",
              properties: ["name": string("Folder name")], required: ["name"]),
        .init(name: "hide_app", description: "Hide an app from the launcher, or show a hidden one again.",
              properties: ["app": string("App name or bundle ID"),
                           "hidden": ["type": "boolean", "description": "true hides it (the default), false shows it again"]],
              required: ["app"]),
    ]
    /// Asked every time.
    static let risky: Set<String> = ["quit_app"]

    static let context = """
        You are the assistant inside LaunchUS, the user's Mac app launcher. Use the tools to look up \
        and act on the user's apps, folders and layouts when that helps, including arranging the home \
        screen (call get_layout first to see where things are); actions are shown to the user, \
        who may approve or decline them. If an action is declined, accept it. Keep answers short and \
        answer in the user's language.
        """

    static func available(_ access: AIToolAccess) -> [MCPServer.Tool] {
        let names: Set<String> = switch access {
        case .off: []
        case .readOnly: readOnly
        case .confirm: readOnly.union(actions)
        }
        return (MCPServer.tools + launcherTools).filter { names.contains($0.name) }
    }

    static func needsApproval(_ call: ToolCall, allowAll: Bool) -> Bool {
        actions.contains(call.name) && (risky.contains(call.name) || !allowAll)
    }

    static func isForce(_ call: ToolCall) -> Bool { call.name == "quit_app" && call.input["force"] as? Bool == true }

    static func title(_ call: ToolCall) -> String {
        let input = call.input
        let app = input["app"] as? String ?? ""
        let name = input["name"] as? String ?? ""
        switch call.name {
        case "search_apps": return String(localized: "搜索 App「\(input["query"] as? String ?? "")」")
        case "list_apps": return String(localized: "查看 App 列表")
        case "running_apps": return String(localized: "查看正在运行的 App")
        case "list_folders": return String(localized: "查看文件夹")
        case "list_layouts": return String(localized: "查看布局")
        case "open_app": return String(localized: "打开「\(app)」")
        case "open_group": return String(localized: "打开「\(name)」里的所有 App")
        case "switch_layout": return String(localized: "切换到布局「\(name)」")
        case "quit_app": return isForce(call) ? String(localized: "强制退出「\(app)」") : String(localized: "退出「\(app)」")
        case "get_layout": return String(localized: "查看主屏幕排列")
        case "move_app": return moveTitle(app, to: input["to"] as? String ?? "")
        case "create_folder":
            let apps = (input["apps"] as? [String] ?? []).joined(separator: "、")
            return String(localized: "把 \(apps) 放进新文件夹「\(name)」")
        case "rename_folder": return String(localized: "把文件夹「\(name)」改名为「\(input["new_name"] as? String ?? "")」")
        case "dissolve_folder": return String(localized: "解散文件夹「\(name)」")
        case "hide_app": return input["hidden"] as? Bool == false ? String(localized: "取消隐藏「\(app)」") : String(localized: "隐藏「\(app)」")
        default: return call.name
        }
    }

    private static func moveTitle(_ app: String, to: String) -> String {
        let target = LauncherTarget(to)
        switch target {
        case .first: return String(localized: "把「\(app)」移到最前")
        case .last: return String(localized: "把「\(app)」移到最后")
        case .page(let n): return String(localized: "把「\(app)」移到第 \(n) 页")
        case .before(let other): return String(localized: "把「\(app)」移到「\(other)」前面")
        case .after(let other): return String(localized: "把「\(app)」移到「\(other)」后面")
        case .folder(let folder): return String(localized: "把「\(app)」放进文件夹「\(folder)」")
        case .out: return String(localized: "把「\(app)」移出文件夹")
        case nil: return String(localized: "移动「\(app)」")
        }
    }

    static func symbol(_ name: String) -> String {
        switch name {
        case "get_layout": "square.grid.3x3"
        case "move_app": "arrow.up.and.down.and.arrow.left.and.right"
        case "create_folder", "rename_folder", "dissolve_folder": "folder"
        case "hide_app": "eye.slash"
        case "search_apps": "magnifyingglass"
        case "list_apps", "list_folders": "square.grid.2x2"
        case "running_apps": "app.badge"
        case "list_layouts", "switch_layout": "rectangle.3.group"
        case "open_app", "open_group": "arrow.up.forward.app"
        case "quit_app": "xmark.app"
        default: "wrench.and.screwdriver"
        }
    }
}

/// Where `move_app` puts something, read from its `to` argument.
enum LauncherTarget: Equatable {
    case first, last, out
    case page(Int)
    case before(String), after(String), folder(String)

    init?(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func rest(_ prefix: String) -> String? {
            guard value.lowercased().hasPrefix(prefix) else { return nil }
            let tail = value.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return tail.isEmpty ? nil : tail
        }
        switch value.lowercased() {
        case "first", "start": self = .first; return
        case "last", "end": self = .last; return
        case "out", "out_of_folder", "home": self = .out; return
        default: break
        }
        if let n = rest("page:").flatMap(Int.init), n > 0 { self = .page(n) }
        else if let other = rest("before:") { self = .before(other) }
        else if let other = rest("after:") { self = .after(other) }
        else if let folder = rest("folder:") { self = .folder(folder) }
        else { return nil }
    }
}
