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

// `LaunchUS --mcp`: serve AI tools over stdio, with no UI.
if arguments.contains("--mcp") {
    MainActor.assumeIsolated { MCPServer.run() }
}

// Before anything reads the settings: carry over what the app left under its old name.
// Not while running from the installer disk, which first offers to move to /Applications.
if !InstallLocation.isOnInstaller(Bundle.main.bundleURL) {
    RenameMigration.runIfNeeded()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(Settings.shared.showDockIcon ? .regular : .accessory)
    withExtendedLifetime(delegate) { app.run() }
}
