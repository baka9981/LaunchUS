import AppKit

// Build-time helper: `LaunchUS --write-iconset <dir>` draws the default app icon.
let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--write-iconset" {
    MainActor.assumeIsolated {
        do {
            try IconArt.writeIconset(.grid, to: URL(fileURLWithPath: arguments[2]))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
    exit(0)
}

// Before anything reads the settings: carry over what the app left under its old name.
RenameMigration.runIfNeeded()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(Settings.shared.showDockIcon ? .regular : .accessory)
    withExtendedLifetime(delegate) { app.run() }
}
