import AppKit

/// A plain-text report for bug reports: versions, settings, layout counts, permissions,
/// recent log lines and the newest crash report. App names and the secret phrase are left out.
enum Diagnostics {
    @MainActor
    static func report(model: LauncherModel) async -> String {
        var lines: [String] = []
        func add(_ title: String, _ body: [String]) {
            lines.append("== \(title) ==")
            lines.append(contentsOf: body)
            lines.append("")
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        add("LaunchUS", [
            "Version: \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "Model: \(sysctl("hw.model"))",
            "Languages: \(Locale.preferredLanguages.prefix(3).joined(separator: ", "))",
            "Date: \(Date().formatted(.iso8601))",
        ])
        add("Displays", NSScreen.screens.map { screen in
            "\(Int(screen.frame.width))×\(Int(screen.frame.height)) @\(screen.backingScaleFactor)x"
                + (screen == NSScreen.main ? " (main)" : "")
        })

        let all = model.layout.joined()
        let folders = all.compactMap { item -> Folder? in if case .folder(let f) = item { f } else { nil } }
        add("Layout", [
            "Apps installed: \(model.catalog.apps.count)",
            "Pages: \(model.layout.count)",
            "Folders: \(folders.filter { !$0.isSmart }.count), smart: \(folders.filter(\.isSmart).count)",
            "Hidden apps: \(model.hiddenIDs.count)",
            "Tags: \(model.allTags.count)",
        ])
        add("Permissions", [
            "Accessibility: \(PermissionKind.accessibility.isGranted)",
            "Full Disk Access: \(PermissionKind.fullDiskAccess.isGranted)",
            "iCloud Drive: \(ICloudSync.isAvailable), sync: \(ICloudSync.enabled), last: \(ICloudSync.lastSync.map { $0.formatted(.iso8601) } ?? "never")",
        ])
        add("Settings", settingsLines())

        let log = await Task.detached { recentLog() }.value
        add("Log (last hour)", log)
        add("Newest crash report", newestCrashReport())
        return lines.joined(separator: "\n")
    }

    /// Our defaults, with private values masked.
    private static func settingsLines() -> [String] {
        let id = Bundle.main.bundleIdentifier ?? "local.launchus.LaunchUS"
        let domain = UserDefaults.standard.persistentDomain(forName: id) ?? [:]
        let masked: Set<String> = ["hiddenPhrase", "syncDeviceID"]
        return domain.keys.sorted().compactMap { key in
            guard !key.hasPrefix("NS"), !key.hasPrefix("SU"), key != "newApps" else { return nil }
            let value = domain[key]!
            if masked.contains(key) { return "\(key): \((value as? String)?.isEmpty == false ? "<set>" : "<empty>")" }
            if let data = value as? Data { return "\(key): <\(data.count) bytes>" }
            return "\(key): \(value)"
        }
    }

    private static func recentLog() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--last", "1h", "--style", "compact", "--predicate", "process == \"LaunchUS\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return ["(log unavailable: \(error.localizedDescription))"] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        return lines.count > 400 ? ["… \(lines.count - 400) earlier lines omitted"] + lines.suffix(400) : lines
    }

    private static func newestCrashReport() -> [String] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let reports = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("LaunchUS") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        guard let newest = reports.first, let text = try? String(contentsOf: newest, encoding: .utf8) else { return ["(none)"] }
        return ["\(newest.lastPathComponent) (\(reports.count) in total)"] + text.split(separator: "\n").prefix(300).map(String.init)
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
