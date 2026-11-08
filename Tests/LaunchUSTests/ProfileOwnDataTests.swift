import Foundation
import Testing
@testable import LaunchUS

/// Hidden apps, the AI key, automatic backups and AI chats belong to each layout profile.
/// Shares the serialized suite with other users of LayoutStore.directoryOverride.
extension AutoBackupTests {
    @MainActor private func withProfiles(_ body: @MainActor (LauncherModel) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchUSTests-\(UUID().uuidString)")
        let name = "ProfileOwnDataTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        LayoutStore.directoryOverride = dir
        AutoBackup.schedulingEnabled = false
        AIKey.memory = [:]
        defaults.set(true, forKey: "didSeedCategoryTags")
        defer {
            LayoutStore.directoryOverride = nil
            AIKey.memory = nil
            AIKey.profile = ""
            ProfileFolders.current = ""
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: dir)
        }
        let apps = ["a", "b", "c"].map { app($0) }
        LayoutStore.save(layout: [apps.map { .app($0.id) }])
        let model = LauncherModel(catalog: AppCatalog(apps: apps), settings: Settings(defaults: defaults))
        model.catalogChanged()
        try body(model)
    }

    @MainActor @Test func hiddenAppsAreEachProfilesOwn() {
        withProfiles { model in
            model.setHidden(true, for: "a")
            model.settings.hiddenPhrase = "芝麻"
            model.createProfile("工作", mode: .window)
            #expect(model.hiddenIDs == ["a"], "a new profile starts with the hidden apps it copied")
            #expect(model.settings.hiddenPhrase == "芝麻")
            model.setHidden(false, for: "a")
            model.setHidden(true, for: "b")
            model.settings.hiddenPhrase = ""

            model.switchProfile("")
            #expect(model.hiddenIDs == ["a"])
            #expect(model.settings.hiddenPhrase == "芝麻")
            #expect(!model.layout.flatMap { $0 }.contains(.app("a")))
            #expect(model.layout.flatMap { $0 }.contains(.app("b")))

            model.switchProfile("工作")
            #expect(model.hiddenIDs == ["b"])
            #expect(model.settings.hiddenPhrase.isEmpty)
        }
    }

    @MainActor @Test func eachProfilesDockIconHasItsOwnMenu() {
        withProfiles { model in
            model.setHidden(true, for: "a")
            model.settings.showDockIcon = true
            model.createProfile("工作", mode: .window)
            model.setHidden(false, for: "a")
            model.setHidden(true, for: "b")
            model.settings.showDockIcon = false
            model.settings.appIcon = .rocket
            model.switchProfile("")

            #expect(model.showsDockIcon("") && !model.showsDockIcon("工作"))
            #expect(model.appIcon(of: "工作") == .rocket)
            let titles = { (name: String) in model.dockMenu(of: name).entries.flatMap { $0.children ?? [$0] }.map(\.title) }
            #expect(!titles("").contains("a") && titles("").contains("b"))
            #expect(titles("工作").contains("a") && !titles("工作").contains("b"))
        }
    }

    @MainActor @Test func aiKeyAndSettingsAreEachProfilesOwn() {
        withProfiles { model in
            AIKey.value = "sk-default"
            model.settings.aiModel = "model-a"
            model.createProfile("工作", mode: .window)
            #expect(AIKey.value == "sk-default", "copied with the other settings")
            AIKey.value = "sk-work"
            model.settings.aiModel = "model-b"

            model.switchProfile("")
            #expect(AIKey.value == "sk-default")
            #expect(model.settings.aiModel == "model-a")

            model.renameProfile("工作", to: "公司")
            model.switchProfile("公司")
            #expect(AIKey.value == "sk-work", "the key moves with a rename")
            #expect(model.settings.aiModel == "model-b")

            model.deleteProfile("公司")
            #expect(AIKey.memory?.keys.sorted() == ["apiKey"])
        }
    }

    @MainActor @Test func backupsAndChatsLiveInTheProfilesFolder() throws {
        try withProfiles { model in
            let defaultBackups = AutoBackup.directory
            model.createProfile("工作/家", mode: .window)
            #expect(AutoBackup.directory != defaultBackups)
            #expect(AutoBackup.directory.path.contains("Profiles/工作∕家/Backups"))
            #expect(ChatHistory.directory.path.contains("Profiles/工作∕家/Chats"))
            #expect(AutoBackup.list().isEmpty, "the other profile's backups aren't listed")

            model.setHidden(true, for: "c")
            let url = try #require(AutoBackup.snapshot())
            model.setHidden(false, for: "c")
            try model.restoreProfileBackup(from: url)
            #expect(model.hiddenIDs == ["c"])

            model.switchProfile("")
            #expect(AutoBackup.directory == defaultBackups)
            #expect(model.hiddenIDs.isEmpty, "restoring changed only that profile")
        }
    }

    @MainActor @Test func copyingAGroupBringsItsOwnData() {
        withProfiles { model in
            model.createProfile("工作", mode: .window)
            model.setHidden(true, for: "b")
            AIKey.value = "sk-work"
            model.switchProfile("")
            model.copySettings(.hidden, from: "工作")
            #expect(model.hiddenIDs == ["b"])
            #expect(!AIKey.isSet)
            model.copySettings(.ai, from: "工作")
            #expect(AIKey.value == "sk-work")
        }
    }

    @MainActor @Test func chosenProfilesExportAndImportOnTheirOwn() throws {
        try withProfiles { model in
            model.createProfile("工作", mode: .window)
            model.setHidden(true, for: "b")
            model.settings.columns = 5
            model.switchProfile("")

            // Only 工作, though 默认 is the one in use.
            let backup = try JSONDecoder().decode(LayoutBackup.self, from: JSONEncoder().encode(model.backup(of: ["工作"])))
            let found = backup.allProfiles
            #expect(found.map(\.name) == ["工作"])
            #expect(ProfileSettings.hiddenApps(in: found[0].settings) == ["b"])
            #expect(ProfileSettings.value("columns", in: found[0].settings, as: Int.self) == 5)
            #expect(backup.meta["b"]?.hidden == true && backup.meta["a"]?.hidden != true)

            // As a new profile; 默认 and its hidden apps stay as they are.
            let name = model.unusedProfileName(like: "工作")
            #expect(name == "工作 2")
            // Not a name another profile from the same file is coming in under.
            #expect(model.unusedProfileName(like: "工作", avoiding: ["工作 2"]) == "工作 3")
            model.importProfiles([(profile: found[0], as: name)], from: backup)
            #expect(model.profileNames == ["", "工作", "工作 2"])
            #expect(model.currentProfile == "" && model.hiddenIDs.isEmpty)
            #expect(model.profileMode("工作 2") == .window)

            // Replacing the one in use takes its pages and settings at once.
            model.importProfiles([(profile: found[0], as: "")], from: backup)
            #expect(model.hiddenIDs == ["b"])
            #expect(model.settings.columns == 5)
            #expect(model.profileNames.count == 3)
        }
    }
}
