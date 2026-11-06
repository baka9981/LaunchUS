import Foundation

/// Named layouts ("工作", "娱乐"…), switched from the menu, a link or Shortcuts. `layout.json`
/// always holds the active one; the others wait in `profiles.json`. Names, tags, hidden apps
/// and icons are shared by all of them.
enum LayoutProfiles {
    struct File: Codable, Equatable {
        /// "" is the built-in default profile.
        var current = ""
        var saved: [String: [[LayoutItem]]] = [:]
    }

    static var url: URL { LayoutStore.directory.appendingPathComponent("profiles.json") }

    static func load() -> File {
        guard let data = try? Data(contentsOf: url) else { return File() }
        return (try? JSONDecoder().decode(File.self, from: data)) ?? File()
    }

    static func save(_ file: File) {
        do {
            try FileManager.default.createDirectory(at: LayoutStore.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(file).write(to: url, options: .atomic)
        } catch {
            NSLog("LaunchUS: failed to save profiles.json: \(error)")
        }
    }

    /// Default first, then the others by name.
    static func names(_ file: File) -> [String] {
        let others = Set(file.saved.keys).union([file.current]).subtracting([""])
        return [""] + others.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func title(_ name: String) -> String { name.isEmpty ? String(localized: "默认") : name }

    /// Matches a name from a link or Shortcuts; "默认" and "default" mean the default profile.
    static func resolve(_ text: String, in file: File) -> String? {
        let wanted = text.trimmingCharacters(in: .whitespaces)
        if wanted.isEmpty || wanted == "默认" || wanted == title("") || wanted.lowercased() == "default" { return "" }
        return names(file).first { $0.localizedCaseInsensitiveCompare(wanted) == .orderedSame }
    }
}
