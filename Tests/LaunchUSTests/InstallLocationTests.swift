import Foundation
import Testing
@testable import LaunchUS

struct InstallLocationTests {
    private func temp() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeApp(in folder: URL, id: String, version: String, marker: String = "") throws -> URL {
        let app = folder.appendingPathComponent("LaunchUS.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(marker.utf8).write(to: contents.appendingPathComponent("marker"))
        return app
    }

    @Test func recognisesWhereTheAppRuns() {
        #expect(InstallLocation.isOnInstaller(URL(fileURLWithPath:
            "/private/var/folders/ab/T/AppTranslocation/1234/d/LaunchUS.app")))
        #expect(!InstallLocation.isOnInstaller(URL(fileURLWithPath: "/Applications/LaunchUS.app")))
        #expect(!InstallLocation.isOnInstaller(URL(fileURLWithPath: "/Users/me/Projects/LaunchUS/build/LaunchUS.app")))
    }

    @Test func installReplacesTheOldCopy() throws {
        let root = temp()
        let source = try makeApp(in: root.appendingPathComponent("disk"), id: "x", version: "2", marker: "new")
        let folder = root.appendingPathComponent("Applications")
        _ = try makeApp(in: folder, id: "x", version: "1", marker: "old")
        let installed = try InstallLocation.install(source, into: folder, discard: { try FileManager.default.removeItem(at: $0) })
        let marker = try String(contentsOf: installed.appendingPathComponent("Contents/marker"), encoding: .utf8)
        #expect(marker == "new")
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func onlyEjectsTheMatchingInstaller() throws {
        let disk = temp()
        _ = try makeApp(in: disk, id: "local.launchus.LaunchUS", version: "1.2.0")
        // Without the Applications link it's just a folder holding the app.
        #expect(!InstallLocation.isInstaller(volume: disk, bundleID: "local.launchus.LaunchUS", version: "1.2.0"))
        try FileManager.default.createSymbolicLink(atPath: disk.appendingPathComponent("Applications").path,
                                                   withDestinationPath: "/Applications")
        #expect(InstallLocation.isInstaller(volume: disk, bundleID: "local.launchus.LaunchUS", version: "1.2.0"))
        #expect(!InstallLocation.isInstaller(volume: disk, bundleID: "local.launchus.LaunchUS", version: "1.3.0"))
        #expect(!InstallLocation.isInstaller(volume: disk, bundleID: "other.app", version: "1.2.0"))
    }
}
