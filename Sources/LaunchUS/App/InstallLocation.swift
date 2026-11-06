import AppKit

/// Finishes the drag-to-install from the disk image. Opened straight from the image, the app
/// offers to copy itself into /Applications and reopen from there; opened from anywhere else
/// with its installer image still mounted, it ejects that image.
@MainActor
enum InstallLocation {
    nonisolated static let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)

    /// Call first thing at launch. Returns true when the app is quitting to reopen from /Applications.
    static func checkAtLaunch() -> Bool {
        let bundle = Bundle.main.bundleURL
        guard isOnInstaller(bundle) else {
            ejectInstallerLater()
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "把 LaunchUS 移到「应用程序」文件夹？")
        alert.informativeText = String(localized: "LaunchUS 正在从安装盘上运行，推出安装盘后就打不开了。移过去后会从「应用程序」重新打开，并推出安装盘。")
        alert.addButton(withTitle: String(localized: "移到「应用程序」"))
        alert.addButton(withTitle: String(localized: "从这里运行"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            // Debug aid: LAUNCHUS_INSTALL_DIR=<dir> installs there instead of /Applications.
            let folder = ProcessInfo.processInfo.environment["LAUNCHUS_INSTALL_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            let installed = try install(bundle, into: folder ?? applications)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", installed.path]
            try task.run()
            NSApp.terminate(nil)
            return true
        } catch {
            let failed = NSAlert()
            failed.alertStyle = .warning
            failed.messageText = String(localized: "没能移到「应用程序」")
            failed.informativeText = error.localizedDescription + "\n\n"
                + String(localized: "请在安装盘窗口里把 LaunchUS 拖到「应用程序」文件夹，再从那里打开。")
            failed.runModal()
            return false
        }
    }

    /// Running from a mounted read-only volume, or from the read-only copy macOS makes of a
    /// downloaded app it hasn't moved (App Translocation).
    nonisolated static func isOnInstaller(_ bundle: URL) -> Bool {
        let path = bundle.standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return true }
        guard path.hasPrefix("/Volumes/") else { return false }
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly
        return readOnly ?? false
    }

    /// Copies the app into `folder`, moving an app already there to the Trash first.
    @discardableResult
    nonisolated static func install(_ bundle: URL, into folder: URL,
                                    discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws -> URL {
        let fm = FileManager.default
        let target = folder.appendingPathComponent(bundle.lastPathComponent, isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            try discard(target)
        }
        try fm.copyItem(at: bundle, to: target)
        return target
    }

    /// The image this version was installed from: its window shows this same app (same id and
    /// version) next to a link to /Applications.
    nonisolated static func isInstaller(volume: URL, bundleID: String, version: String) -> Bool {
        let fm = FileManager.default
        let link = volume.appendingPathComponent("Applications").path
        guard (try? fm.destinationOfSymbolicLink(atPath: link)) == "/Applications" else { return false }
        let app = volume.appendingPathComponent("LaunchUS.app", isDirectory: true)
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return false }
        return info["CFBundleIdentifier"] as? String == bundleID
            && info["CFBundleShortVersionString"] as? String == version
    }

    private static func ejectInstallerLater() {
        guard let id = Bundle.main.bundleIdentifier,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            let keys: [URLResourceKey] = [.volumeIsReadOnlyKey, .volumeIsEjectableKey]
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                                 options: .skipHiddenVolumes) ?? []
            for volume in volumes where volume.path.hasPrefix("/Volumes/") {
                let values = try? volume.resourceValues(forKeys: Set(keys))
                guard values?.volumeIsReadOnly == true,
                      isInstaller(volume: volume, bundleID: id, version: version) else { continue }
                try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            }
        }
    }
}
