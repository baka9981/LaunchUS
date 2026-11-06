import AppKit
import CoreServices
import Observation

/// Holds the scanned apps and their pre-rendered icons.
@MainActor @Observable
final class AppCatalog {
    private(set) var apps: [AppItem] = []
    private(set) var icons: [String: CGImage] = [:]

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var iconPriority: (() -> [String])?
    @ObservationIgnored private var isScanning = false
    @ObservationIgnored private var lastScan = Date.distantPast
    /// An app folder changed since the last scan.
    @ObservationIgnored private var isDirty = true
    @ObservationIgnored private var watcher: FolderWatcher?
    /// Called with the apps once the scan in progress (or the one about to start) finishes.
    @ObservationIgnored private var waiters: [([AppItem]) -> Void] = []
    @ObservationIgnored private var nextWaiters: [([AppItem]) -> Void] = []
    @ObservationIgnored private var rescanRequested = false
    @ObservationIgnored private let scan: @Sendable () -> [AppItem]
    @ObservationIgnored private let renderIcon: @Sendable (String) -> CGImage?
    @ObservationIgnored private let folderPaths: () -> [String]
    private struct IconSource: Equatable, Sendable {
        let path: String
        let modified: Date?
    }
    private struct RenderedIcon {
        let id: String
        let source: IconSource
        let image: CGImage?
    }
    @ObservationIgnored private var iconSources: [String: IconSource] = [:]
    /// Icon sources from the last scan, before the user's own icons are applied.
    @ObservationIgnored private var scannedSources: [String: IconSource] = [:]
    /// Icons picked by the user: app ID → image path or symbol (see `CustomIcons`).
    @ObservationIgnored var iconOverrides: [String: String] = [:] {
        didSet {
            guard oldValue != iconOverrides else { return }
            updateSources()
            loadMissingIcons()
        }
    }
    /// Apps draw the dark version of their icon, for those that have one.
    @ObservationIgnored var darkIcons = false {
        didSet {
            guard oldValue != darkIcons else { return }
            refreshDynamicIcons()
        }
    }
    @ObservationIgnored private var loadingIcons: [String: IconSource] = [:]
    /// Apps from the last scan; `apps` adds the launch items to them.
    @ObservationIgnored private var scannedApps: [AppItem]
    @ObservationIgnored private var customSources: [String: IconSource] = [:]
    /// Launch items that aren't apps (see `CustomItem`). Kept apart from the scan, so adding,
    /// editing or deleting one updates `apps` at once instead of rescanning the app folders.
    @ObservationIgnored var customApps: [AppItem] = [] {
        didSet {
            guard oldValue != customApps else { return }
            customSources = Dictionary(customApps.map { ($0.id, Self.source(for: $0)) }, uniquingKeysWith: { _, new in new })
            // Before the first scan there are no apps to add them to yet.
            guard lastScan != .distantPast || !scannedApps.isEmpty else { return }
            if compose() { onChange?() }
            loadMissingIcons()
        }
    }

    init(apps: [AppItem] = [], scan: @escaping @Sendable () -> [AppItem] = { AppScanner.scan() },
         renderIcon: @escaping @Sendable (String) -> CGImage? = { IconRenderer.render(path: $0) },
         folderPaths: @escaping () -> [String] = { AppScanner.roots.map(\.path) }) {
        self.apps = apps
        scannedApps = apps
        self.scan = scan
        self.renderIcon = renderIcon
        self.folderPaths = folderPaths
    }

    /// Rescans in the background. Without `force`, only when an app folder changed since the
    /// last scan, or (at most every few seconds) when sorting by usage needs fresh Spotlight dates.
    func reload(force: Bool = false, then done: (([AppItem]) -> Void)? = nil) {
        watchFolders()
        if calendarDay != CalendarIcon.today { refreshDynamicIcons() }
        if isScanning {
            // A forced refresh may reflect an installation or a changed search folder
            // that the in-flight scan has already passed.
            if force || isDirty || rescanRequested {
                rescanRequested = true
                if let done { nextWaiters.append(done) }
            } else if let done {
                waiters.append(done)
            }
            return
        }
        if let done { waiters.append(done) }
        let usageSort = [.recentlyUsed, .mostUsed].contains(Settings.shared.sortOrder)
        guard force || isDirty || (usageSort && Date().timeIntervalSince(lastScan) > 5) else {
            finishWaiters()
            return
        }
        isScanning = true
        // Cleared before scanning, so a change during the scan triggers another one.
        isDirty = false
        let scan = self.scan
        Task.detached(priority: .userInitiated) { [weak self] in
            let scanned = scan()
            // Bundle metadata is disk I/O; collect it alongside the background scan.
            let sources = Dictionary(scanned.map { ($0.id, Self.source(for: $0)) }, uniquingKeysWith: { _, new in new })
            await self?.apply(scanned, sources: sources)
        }
    }

    nonisolated private static func source(for app: AppItem) -> IconSource {
        let path = app.iconPath
        let modified = path.hasPrefix(IconRenderer.symbolPrefix) ? nil
            : try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return IconSource(path: path, modified: modified)
    }

    /// Merges the scanned apps and the launch items into `apps`; true when that changed it.
    private func compose() -> Bool {
        updateSources()
        let merged = customApps.isEmpty ? scannedApps
            : (scannedApps + customApps).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard merged != apps else { return false }
        apps = merged
        return true
    }

    /// The day the Calendar icon was last drawn for.
    @ObservationIgnored private var calendarDay = ""

    /// Redraws icons that change by themselves (Calendar's date), or after their setting changed.
    func refreshDynamicIcons() {
        updateSources()
        loadMissingIcons()
    }

    /// (Re)starts watching when the set of app folders changes.
    private func watchFolders() {
        let paths = folderPaths()
        guard !paths.isEmpty else { return }
        guard watcher?.paths != paths else { return }
        watcher = FolderWatcher(paths: paths) { [weak self] in
            MainActor.assumeIsolated { self?.isDirty = true }
        }
    }

    private func finishWaiters() {
        let done = waiters
        waiters = []
        done.forEach { $0(apps) }
    }

    private func apply(_ scanned: [AppItem], sources: [String: IconSource]) {
        // Detach this scan's callbacks before notifying clients: onChange can
        // synchronously call reload again and register callbacks for a new scan.
        let done = waiters
        waiters = nextWaiters
        nextWaiters = []
        let shouldRescan = rescanRequested || isDirty
        rescanRequested = false
        isScanning = false
        lastScan = Date()
        scannedApps = scanned
        scannedSources = sources
        let changed = compose()
        if shouldRescan { reload(force: true) }
        if changed { onChange?() }
        let apps = self.apps
        done.forEach { $0(apps) }
        loadMissingIcons()
    }

    /// Applies the user's icons to the scanned sources and drops cached icons whose source changed.
    private func updateSources() {
        var sources = scannedSources.merging(customSources) { _, new in new }
        calendarDay = CalendarIcon.today
        if Settings.shared.dynamicCalendar, sources[CalendarIcon.bundleID] != nil {
            sources[CalendarIcon.bundleID] = IconSource(path: CalendarIcon.prefix + calendarDay, modified: nil)
        }
        if darkIcons {
            // Pictures and symbols the user picked have no dark version.
            let custom = CustomIcons.directory.path + "/"
            for (id, source) in sources where !source.path.hasPrefix(IconRenderer.symbolPrefix) && !source.path.hasPrefix(custom) {
                sources[id] = IconSource(path: IconRenderer.darkPrefix + source.path, modified: source.modified)
            }
        }
        for (id, path) in iconOverrides where sources[id] != nil {
            sources[id] = IconSource(path: path, modified: nil)
        }
        if icons.keys.contains(where: { sources[$0] == nil || sources[$0] != iconSources[$0] }) {
            icons = icons.filter { sources[$0.key] != nil && sources[$0.key] == iconSources[$0.key] }
        }
        iconSources = sources
        loadingIcons = loadingIcons.filter { sources[$0.key] == $0.value }
    }

    private func loadMissingIcons() {
        var missing = apps.compactMap { app -> (String, IconSource)? in
            guard icons[app.id] == nil, let source = iconSources[app.id],
                  loadingIcons[app.id] != source else { return nil }
            return (app.id, source)
        }
        guard !missing.isEmpty else { return }
        // onChange has already reconciled the layout. Render visible page icons
        // first, then retain scanning order for all remaining apps.
        let byID = Dictionary(missing, uniquingKeysWith: { _, new in new })
        var prioritized = Set<String>()
        let first = (iconPriority?() ?? []).compactMap { id -> (String, IconSource)? in
            guard let source = byID[id], prioritized.insert(id).inserted else { return nil }
            return (id, source)
        }
        missing = first + missing.filter { !prioritized.contains($0.0) }
        for (id, source) in missing { loadingIcons[id] = source }
        let renderIcon = self.renderIcon
        Task.detached(priority: .utility) { [weak self] in
            var batch: [RenderedIcon] = []
            for (id, source) in missing {
                batch.append(RenderedIcon(id: id, source: source, image: renderIcon(source.path)))
                if batch.count == 16 {
                    await self?.mergeIcons(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty { await self?.mergeIcons(batch) }
        }
    }

    private func mergeIcons(_ batch: [RenderedIcon]) {
        var accepted: [String: CGImage] = [:]
        for result in batch {
            if loadingIcons[result.id] == result.source { loadingIcons[result.id] = nil }
            guard iconSources[result.id] == result.source, let image = result.image else { continue }
            accepted[result.id] = image
        }
        if !accepted.isEmpty { icons.merge(accepted) { _, new in new } }
    }
}

/// Reports changes anywhere under a set of folders (FSEvents, coalesced over a second).
final class FolderWatcher {
    let paths: [String]
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?

    init(paths: [String], onChange: @escaping () -> Void) {
        self.paths = paths
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
