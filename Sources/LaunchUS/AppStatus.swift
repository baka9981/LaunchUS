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
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }

    static func save(_ state: State) {
        UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: key)
    }

    /// The first time, everything already installed counts as known.
    static func update(_ state: State?, apps: [AppItem], now: Date = Date()) -> State {
        let ids = Set(apps.map(\.id))
        guard let state else { return State(known: ids, new: [:]) }
        var new = state.new.filter { ids.contains($0.key) }
        for app in apps where !state.known.contains(app.id) {
            new[app.id] = now
        }
        for app in apps {
            if let found = new[app.id], let used = app.lastUsedDate, used > found { new[app.id] = nil }
        }
        return State(known: ids, new: new)
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

    static func current() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular else { return nil }
            return app.bundleIdentifier ?? app.bundleURL?.path
        })
    }
}
