import Foundation

/// Files a layout profile keeps for itself: its automatic backups and AI chats. The default
/// profile's stay where they always were (`Backups/`, `Chats/`); another profile's live under
/// `Profiles/<name>/`.
enum ProfileFolders {
    /// The active profile; `LauncherModel` keeps it in step.
    nonisolated(unsafe) static var current = ""

    static func url(_ kind: String, for profile: String = current) -> URL {
        guard let root = root(of: profile) else {
            return LayoutStore.directory.appendingPathComponent(kind, isDirectory: true)
        }
        return root.appendingPathComponent(kind, isDirectory: true)
    }

    /// `Profiles/<name>/`; nil for the default profile.
    static func root(of profile: String) -> URL? {
        guard !profile.isEmpty else { return nil }
        return LayoutStore.directory.appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(folderName(profile), isDirectory: true)
    }

    /// A profile name as a folder name: no path separators, no hidden folders.
    static func folderName(_ profile: String) -> String {
        var name = profile.replacingOccurrences(of: "/", with: "∕").replacingOccurrences(of: ":", with: "-")
        if name.hasPrefix(".") { name = "_" + name.dropFirst() }
        return name
    }

    static func rename(_ old: String, to new: String) {
        guard let from = root(of: old), let to = root(of: new),
              FileManager.default.fileExists(atPath: from.path) else { return }
        try? FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: from, to: to)
    }

    static func remove(_ profile: String) {
        guard let root = root(of: profile) else { return }
        try? FileManager.default.removeItem(at: root)
    }
}
