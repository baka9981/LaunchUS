import Foundation

/// Keeps the layout the same on every Mac signed in to the same iCloud account, through a
/// file in the user's iCloud Drive (iCloud Drive/LaunchUS/sync.json). The last change wins;
/// the layout it replaces is auto-backed-up first. Apps installed on only one Mac go to the
/// end on the others.
enum ICloudSync {
    struct Payload: Codable {
        var app = "LaunchUS"
        var version = 1
        var device: String
        var deviceID: String
        var modified: Date
        var pages: [[LayoutItem]]
        var meta: [String: AppMeta]
        var custom: [CustomItem]?
        /// Layout profile the pages belong to; "" or missing is the default one.
        var profile: String?
        /// Smart folders shown only in the smart bar; missing from older versions.
        var barFolders: [Folder]?
    }

    static var driveRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }
    static var isAvailable: Bool { FileManager.default.fileExists(atPath: driveRoot.path) }
    static var folder: URL { driveRoot.appendingPathComponent("LaunchUS", isDirectory: true) }
    static var fileURL: URL { folder.appendingPathComponent("sync.json") }

    static var enabled: Bool { UserDefaults.app.bool(forKey: "iCloudSync") && isAvailable }
    /// When this Mac last sent or received a layout.
    static var lastSync: Date? { UserDefaults.app.object(forKey: "iCloudLastSync") as? Date }

    /// Called with a newer layout from another Mac.
    @MainActor static var onRemoteChange: ((LayoutBackup) -> Void)?
    /// Set while a received layout is being saved, so it isn't sent straight back.
    /// LayoutStore can call localChanged from a background task, so this flag
    /// must be readable immediately without crossing the main actor.
    static var applying: Bool {
        get { applicationState.lock.withLock { applicationState.applying } }
        set { applicationState.lock.withLock { applicationState.applying = newValue } }
    }
    private final class ApplicationState: @unchecked Sendable {
        let lock = NSLock()
        var applying = false
    }
    private static let applicationState = ApplicationState()
    @MainActor private static var pending: DispatchWorkItem?
    @MainActor private static var watcher: FolderWatcher?

    private static var deviceID: String {
        if let id = UserDefaults.app.string(forKey: "syncDeviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.app.set(id, forKey: "syncDeviceID")
        return id
    }

    /// Modified date of the newest remote layout taken over, so it's applied once.
    private static var lastApplied: Date {
        get { UserDefaults.app.object(forKey: "iCloudLastApplied") as? Date ?? .distantPast }
        set { UserDefaults.app.set(newValue, forKey: "iCloudLastApplied") }
    }

    /// Turning sync on takes over a layout already in iCloud from another Mac; otherwise this
    /// Mac's layout goes up.
    @MainActor static func start() {
        stop()
        guard enabled else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watcher = FolderWatcher(paths: [folder.path]) {
            MainActor.assumeIsolated { _ = checkRemote() }
        }
        if !checkRemote() { upload() }
    }

    @MainActor static func stop() {
        watcher = nil
        pending?.cancel()
        pending = nil
    }

    /// The layout or app settings were saved here.
    static func localChanged() {
        guard !applying, enabled else { return }
        DispatchQueue.main.async {
            pending?.cancel()
            let work = DispatchWorkItem { MainActor.assumeIsolated { upload() } }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    @MainActor static func upload() {
        guard enabled, let pages = LayoutStore.loadLayout() else { return }
        let payload = Payload(device: Host.current().localizedName ?? "Mac", deviceID: deviceID,
                              modified: Date(), pages: pages, meta: LayoutStore.loadMeta(),
                              custom: CustomItemStore.load(), profile: LayoutProfiles.load().current,
                              barFolders: LayoutStore.loadBarFolders())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(payload).write(to: fileURL, options: .atomic)
            UserDefaults.app.set(Date(), forKey: "iCloudLastSync")
        } catch {
            NSLog("LaunchUS: iCloud upload failed: \(error)")
        }
    }

    /// Takes over the iCloud layout if another Mac saved a newer one. Returns whether it did.
    @discardableResult
    @MainActor static func checkRemote() -> Bool {
        guard enabled, let payload = read(), payload.deviceID != deviceID, payload.modified > lastApplied else { return false }
        lastApplied = payload.modified
        UserDefaults.app.set(Date(), forKey: "iCloudLastSync")
        var backup = LayoutBackup(pages: payload.pages, meta: payload.meta, custom: payload.custom, barFolders: payload.barFolders)
        backup.profile = payload.profile ?? ""
        onRemoteChange?(backup)
        return true
    }

    static func read() -> Payload? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Payload.self, from: data)
    }
}
