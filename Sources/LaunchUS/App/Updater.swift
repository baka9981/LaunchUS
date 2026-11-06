import AppKit
import Sparkle

/// In-app updates through Sparkle. The feed address is written into Info.plist (SUFeedURL)
/// by scripts/build.sh from update.conf; a build without one has no updater.
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    /// Hides the launcher, which would otherwise cover Sparkle's windows.
    var hideLauncher: (() -> Void)?
    private var controller: SPUStandardUpdaterController?

    var isConfigured: Bool {
        !((Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? "").isEmpty
    }

    func start() {
        guard isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
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

    // MARK: SPUStandardUserDriverDelegate

    /// LaunchUS has no Dock icon by default; let Sparkle remind gently instead of
    /// popping a window over whatever the user is doing.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        MainActor.assumeIsolated { if handleShowingUpdate { hideLauncher?() } }
    }

    nonisolated func standardUserDriverWillShowModalAlert() {
        MainActor.assumeIsolated { hideLauncher?() }
    }
}
