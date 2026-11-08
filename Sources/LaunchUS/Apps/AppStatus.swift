import AppKit

/// Apps installed since LaunchUS last looked, marked until they're first opened, like
/// Launchpad's blue dot. Opening counts from anywhere: Spotlight's last-used date is checked too.
enum NewApps {
    struct State: Codable, Equatable {
        /// Every app seen so far.
        var known: Set<String>
        /// New apps and when they turned up.
        var new: [String: Date]
    }

    private static let key = "newApps"

    static func load() -> State? {
        UserDefaults.app.data(forKey: key).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }

    static func save(_ state: State) {
        UserDefaults.app.set(try? JSONEncoder().encode(state), forKey: key)
    }

    /// The first time, everything already installed counts as known.
    static func update(_ state: State?, apps: [AppItem], elsewhere: Set<String> = [], now: Date = Date()) -> State {
        let ids = Set(apps.map(\.id))
        guard let state else { return State(known: ids, new: [:]) }
        var new = state.new.filter { ids.contains($0.key) }
        for app in apps where !state.known.contains(app.id) {
            new[app.id] = now
        }
        for app in apps {
            if let found = new[app.id], let used = app.lastUsedDate, used > found { new[app.id] = nil }
        }
        // Apps on another profile's pages stay known: a profile with fewer app folders
        // doesn't make them new again when switching back.
        return State(known: ids.union(state.known.intersection(elsewhere)), new: new)
    }
}

/// Keeps a set of running apps' IDs (bundle ID, or path for apps without one).
@MainActor
final class RunningApps {
    private var observers: [Any] = []
    var onChange: ((Set<String>) -> Void)?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish() }
            })
        }
    }

    func publish() {
        onChange?(Self.current())
    }

    /// The running copies of an app, found the same way `current()` names them.
    static func instances(of app: AppItem) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { running in
            (running.bundleIdentifier ?? running.bundleURL?.path) == app.id
        }
    }

    /// Asks the app to quit (it may still ask to save), or ends it at once.
    static func quit(_ app: AppItem, force: Bool) {
        for running in instances(of: app) {
            _ = force ? running.forceTerminate() : running.terminate()
        }
    }

    static func current() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular else { return nil }
            return app.bundleIdentifier ?? app.bundleURL?.path
        })
    }
}
