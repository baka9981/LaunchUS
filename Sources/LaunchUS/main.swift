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

// A profile's own Dock icon (DockTiles): this program run from a stand-in bundle.
if DockTiles.runningAsTile {
    MainActor.assumeIsolated { TileApp.run() }
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
    // The Dock icon is the default profile's; the other profiles have their own (DockTiles).
    let profiles = LayoutProfiles.load()
    let dock = profiles.current.isEmpty ? Settings.shared.showDockIcon
        : ProfileSettings.value("showDockIcon", in: profiles.settings[""], as: Bool.self) ?? false
    app.setActivationPolicy(dock ? .regular : .accessory)
    withExtendedLifetime(delegate) { app.run() }
}
