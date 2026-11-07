import Foundation

/// Keeps the last few layouts in Backups/, one per change. Changes a few seconds apart
/// (a drag, then another) count as one, and a backup equal to the newest is skipped.
enum AutoBackup {
    struct Entry: Identifiable, Hashable {
        let url: URL
        let date: Date
        var id: URL { url }
    }

    static var directory: URL { LayoutStore.directory.appendingPathComponent("Backups", isDirectory: true) }
    /// 0 turns automatic backups off.
    static var limit: Int { UserDefaults.app.object(forKey: "autoBackupCount") as? Int ?? 10 }
    nonisolated(unsafe) private static var pending: DispatchWorkItem?
    /// Tests take snapshots by hand.
    nonisolated(unsafe) static var schedulingEnabled = true
    private static let prefix = "layout-"

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    static func schedule(after delay: TimeInterval = 3) {
        guard schedulingEnabled else { return }
        DispatchQueue.main.async {
            pending?.cancel()
            let work = DispatchWorkItem { snapshot() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Writes a backup of the saved layout and app settings now, unless nothing changed.
    @discardableResult
    static func snapshot(now: Date = Date()) -> URL? {
        let keep = limit
        guard keep > 0, let pages = LayoutStore.loadLayout() else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(LayoutBackup(pages: pages, meta: LayoutStore.loadMeta(),
                                                                  custom: CustomItemStore.load(), barFolders: LayoutStore.loadBarFolders(),
                                                                  profiles: LayoutProfiles.load())) else { return nil }
        if let newest = list().first, (try? Data(contentsOf: newest.url)) == data { return nil }
        let url = directory.appendingPathComponent(prefix + stampFormat.string(from: now) + ".json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("LaunchUS: auto backup failed: \(error)")
            return nil
        }
        prune(keeping: keep)
        return url
    }

    /// Newest first.
    static func list() -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> Entry? in
            guard name.hasPrefix(prefix), name.hasSuffix(".json"),
                  let date = stampFormat.date(from: String(name.dropFirst(prefix.count).dropLast(5))) else { return nil }
            return Entry(url: directory.appendingPathComponent(name), date: date)
        }
        .sorted { $0.date > $1.date }
    }

    static func prune(keeping keep: Int) {
        for entry in list().dropFirst(max(0, keep)) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }
}
