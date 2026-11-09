import AppKit
import Sparkle

/// In-app updates through Sparkle. The feed address is written into Info.plist (SUFeedURL)
/// by scripts/build.sh from update.conf; a build without one has no updater.
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let shared = Updater()

    /// Hides the launcher, which would otherwise cover Sparkle's windows.
    var hideLauncher: (() -> Void)?
    private var controller: SPUStandardUpdaterController?

    var isConfigured: Bool {
        !((Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? "").isEmpty
    }

    func start() {
        guard isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    func checkForUpdates() {
        hideLauncher?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.activate()
            self.controller?.checkForUpdates(nil)
        }
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// How often it checks: once an hour, a day or a week.
    static let intervals: [TimeInterval] = [3600, 86400, 604800]

    var checkInterval: TimeInterval {
        get {
            let now = controller?.updater.updateCheckInterval ?? 86400
            return Self.intervals.min { abs($0 - now) < abs($1 - now) } ?? 86400
        }
        set { controller?.updater.updateCheckInterval = newValue }
    }

    static func intervalTitle(_ interval: TimeInterval) -> String {
        switch interval {
        case 3600: String(localized: "每小时")
        case 604800: String(localized: "每周")
        default: String(localized: "每天")
        }
    }

    /// Downloads new versions in the background, then quits and restarts into them right away.
    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// Beta versions come through the same feed, marked with Sparkle's "beta" channel; only
    /// Macs that opted in see them. A beta later becomes the release as it is (the same build),
    /// so turning this off never goes back: the next release arrives as usual.
    nonisolated static let betaKey = "updateChannelBeta"

    var receivesBeta: Bool {
        get { UserDefaults.app.bool(forKey: Self.betaKey) }
        set {
            UserDefaults.app.set(newValue, forKey: Self.betaKey)
            // Look for the beta now rather than at the next scheduled check.
            if newValue { controller?.updater.checkForUpdatesInBackground() }
        }
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.app.bool(forKey: Self.betaKey) ? ["beta"] : []
    }

    /// A downloaded update would otherwise wait for LaunchUS to quit, which it rarely does:
    /// install it right away and restart.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        // Once Sparkle is done asking, not from inside its own call.
        DispatchQueue.main.async { immediateInstallationBlock() }
        return true
    }
}

