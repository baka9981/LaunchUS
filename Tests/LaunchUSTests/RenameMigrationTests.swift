import Foundation
import Testing
@testable import LaunchUS

struct RenameMigrationTests {
    private func temp() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func copiesOldPreferencesAndFoldersOnce() throws {
        let suite = "rename-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = temp()
        let old = root.appendingPathComponent("LaunchNew"), new = root.appendingPathComponent("LaunchUS")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: old.appendingPathComponent("layout.json"))

        RenameMigration.run(defaults: defaults, oldPreferences: ["columns": 9, "liquidGlass": false],
                            ownPreferences: nil, folderPairs: [(old, new)])
        #expect(defaults.integer(forKey: "columns") == 9)
        #expect(defaults.object(forKey: "liquidGlass") as? Bool == false)
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("layout.json").path))
        #expect(FileManager.default.fileExists(atPath: old.path), "the old folder stays")

        // Only once: later changes to the old app's preferences are not copied again.
        RenameMigration.run(defaults: defaults, oldPreferences: ["columns": 4], ownPreferences: nil, folderPairs: [])
        #expect(defaults.integer(forKey: "columns") == 9)
    }

    @Test func keepsOwnSettingsAndExistingFolder() throws {
        let suite = "rename-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = temp()
        let old = root.appendingPathComponent("LaunchNew"), new = root.appendingPathComponent("LaunchUS")
        for dir in [old, new] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("old".utf8).write(to: old.appendingPathComponent("layout.json"))

        RenameMigration.run(defaults: defaults, oldPreferences: ["columns": 9],
                            ownPreferences: ["columns": 6, "NSWindow Frame x": "…"], folderPairs: [(old, new)])
        #expect(defaults.object(forKey: "columns") == nil)
        #expect(!FileManager.default.fileExists(atPath: new.appendingPathComponent("layout.json").path))
    }
}
