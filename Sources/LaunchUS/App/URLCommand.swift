import Foundation

/// `launchus://` links, for Shortcuts ("Open URL"), scripts and other launchers.
///
///     launchus://open                 launchus://toggle            launchus://close
///     launchus://search?q=微信         launchus://folder?name=工具   launchus://page?n=2
///     launchus://settings?tab=general  launchus://profile?name=工作
///     launchus://openall?name=写代码      (every app in that folder)
///     launchus://toggle?profile=工作   (opens or closes that profile, as its Dock icon does)
///     launchus://widgets              (the widget gallery)
///     launchus://tool?name=…&args=…&reply=…&token=…   (`LaunchUS --mcp` running a tool, `MCPBridge`)
enum URLCommand: Equatable {
    /// A tool the MCP server runs in the app; `arguments` is JSON text.
    struct ToolRequest: Equatable {
        var name: String
        var arguments: String
        var reply: String
        var token: String
    }

    case open, toggle, close
    /// Opens a profile, or closes it when it's the one on screen.
    case toggleProfile(String)
    case search(String)
    case folder(String)
    /// 1-based, like the dots.
    case page(Int)
    case settings(SettingsTab?)
    /// Switches to a named layout.
    case profile(String)
    /// Opens every app in a named folder.
    case openAll(String)
    case widgets
    case tool(ToolRequest)

    static let scheme = "launchus"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // launchus://search?q=… puts the command in the host; launchus:search?q=… in the path.
        let name = (parts.host ?? parts.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let query = Dictionary((parts.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
                               uniquingKeysWith: { a, _ in a })
        switch name {
        case "", "open", "show": self = .open
        case "toggle":
            if let profile = query["profile"] { self = .toggleProfile(profile) } else { self = .toggle }
        case "close", "hide": self = .close
        case "search":
            self = .search(query["q"] ?? query["query"] ?? "")
        case "folder":
            guard let folder = query["name"], !folder.isEmpty else { return nil }
            self = .folder(folder)
        case "page":
            guard let n = Int(query["n"] ?? query["page"] ?? ""), n >= 1 else { return nil }
            self = .page(n)
        case "profile", "layout":
            guard let profile = query["name"] else { return nil }
            self = .profile(profile)
        case "openall", "group":
            guard let folder = query["name"], !folder.isEmpty else { return nil }
            self = .openAll(folder)
        case "widgets", "widget":
            self = .widgets
        case "tool":
            guard let tool = query["name"], !tool.isEmpty, let reply = query["reply"], !reply.isEmpty else { return nil }
            self = .tool(ToolRequest(name: tool, arguments: query["args"] ?? "{}", reply: reply, token: query["token"] ?? ""))
        case "settings":
            self = .settings(query["tab"].flatMap { SettingsTab.named($0) })
        default:
            return nil
        }
    }
}
