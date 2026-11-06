import Foundation
import Testing
@testable import LaunchUS

/// Shares the serialized suite with other users of LayoutStore.directoryOverride.
extension AutoBackupTests {
    /// With apps hidden behind verification, their settings and backup restores are locked too.
    @Test @MainActor func hiddenSettingsLockedWhileHiddenAppsNeedVerification() async throws {
        try await withFolderFixture { model in
            var ran = false
            model.whenHiddenUnlocked { ran = true }
            #expect(!model.hiddenGuarded && ran, "nothing hidden yet: no verification")

            model.setHidden(true, for: "fixture-1")
            #expect(model.hiddenGuarded)

            model.settings.hiddenRequireAuth = false
            ran = false
            model.whenHiddenUnlocked { ran = true }
            #expect(!model.hiddenGuarded && ran, "verification turned off: nothing to guard")
        }
    }

    @Test @MainActor func portraitScreenTurnsTheGridOnItsSide() async throws {
        try await withFolderFixture { model in
            let (columns, rows) = (model.settings.columns, model.settings.rows)
            model.screenSize = CGSize(width: 1080, height: 1920)
            #expect(model.columns == min(columns, rows) && model.rows == max(columns, rows))
            #expect(model.perPage == columns * rows, "same apps per page, so nothing changes page")
            model.screenSize = CGSize(width: 1920, height: 1080)
            #expect(model.columns == columns && model.rows == rows)
        }
    }

    @Test @MainActor func folderScrollClampsBothEndsWithOneHundredApps() async throws {
        try await withFolderFixture { model in
            model.scrollFolder(by: 100_000)
            #expect(model.folderScrollOffset == 1_590)
            model.scrollFolder(by: -100_000)
            #expect(model.folderScrollOffset == 0)
        }
    }

    @Test @MainActor func folderKeyboardRevealKeepsLastAndEarlierRowsVisible() async throws {
        try await withFolderFixture { model in
            model.selection = GridPos(page: 0, slot: 99)
            model.revealFolderSelection()
            #expect(model.folderScrollOffset == 1_590)
            model.selection = GridPos(page: 0, slot: 7)
            model.revealFolderSelection()
            #expect(model.folderScrollOffset == 159)
            model.moveSelection(dx: -1, dy: 0)
            model.revealFolderSelection()
            #expect(model.selection == GridPos(page: 0, slot: 6))
            #expect(model.folderScrollOffset == 0)
        }
    }

    @Test @MainActor func folderContentShrinkClampsOffsetAfterHidingApps() async throws {
        try await withFolderFixture { model in
            model.scrollFolder(by: 100_000)
            model.multiSelection = Set((35..<100).map { "fixture-\($0)" })
            model.hideSelection()
            #expect(model.openFolder?.1.count == 35)
            #expect(model.folderScrollOffset == 0)
        }
    }

    @Test @MainActor func folderGeometryChangeClampsOffsetToNewExtent() async throws {
        try await withFolderFixture { model in
            model.scrollFolder(by: 100_000)
            model.screenSize = CGSize(width: 1_400, height: 500)
            #expect(model.folderScrollOffset == 795)
        }
    }

    @Test @MainActor func folderKeyboardSelectionRemainsVisibleAfterResize() async throws {
        try await withFolderFixture { model in
            model.screenSize = CGSize(width: 1_400, height: 500)
            model.selection = GridPos(page: 0, slot: 99)
            model.revealFolderSelection()
            #expect(model.folderScrollOffset == 795)
            model.screenSize = CGSize(width: 1_400, height: 1_000)
            #expect(model.folderScrollOffset == 1_590)
        }
    }

    @Test @MainActor func folderBrowseModeChangeClearsStalePageAndScroll() async throws {
        try await withFolderFixture { model in
            model.scrollFolder(by: 100_000)
            model.settings.folderBrowseStyle = .paged
            model.settingsChanged()
            #expect(model.folderScrollOffset == 0)
            model.goToFolderPage(2)
            model.folderDragOffset = 50
            model.selection = GridPos(page: 2, slot: 1)
            model.settings.folderBrowseStyle = .scroll
            model.settingsChanged()
            #expect(model.folderPage == 0)
            #expect(model.folderDragOffset == 0)
            #expect(model.selection == nil)
            #expect(model.folderScrollOffset == 0)
        }
    }

    @Test @MainActor func folderDragHitTestingUsesScrolledContentPosition() async throws {
        try await withFolderFixture { model in
            model.scrollFolder(by: 100_000)
            let grid = model.metrics.folderGridRect
            // Ten hidden rows: the visible row starts with app 70, not app 0.
            let start = CGPoint(x: grid.minX + 87.5, y: grid.minY + 79.5)
            let target = CGPoint(x: grid.minX + 262.5, y: start.y)
            model.beginDrag(.app(model.app("fixture-70")!), inFolder: "fixture-folder", pointer: start, iconCenter: start)
            model.dragMoved(to: target)
            try await Task.sleep(for: .milliseconds(350))
            #expect(model.openFolder?.0.apps[70] == "fixture-71")
            #expect(model.openFolder?.0.apps[71] == "fixture-70")
            model.endDrag()
        }
    }

    @Test @MainActor func folderReturningDragToSourceCancelsPendingReorder() async throws {
        try await withFolderFixture { model in
            model.scrollFolder(by: 100_000)
            let grid = model.metrics.folderGridRect
            let start = CGPoint(x: grid.minX + 87.5, y: grid.minY + 79.5)
            let target = CGPoint(x: grid.minX + 262.5, y: start.y)
            model.beginDrag(.app(model.app("fixture-70")!), inFolder: "fixture-folder", pointer: start, iconCenter: start)
            model.dragMoved(to: target)
            model.dragMoved(to: start)
            try await Task.sleep(for: .milliseconds(350))
            #expect(model.openFolder?.0.apps[70] == "fixture-70")
            #expect(model.openFolder?.0.apps[71] == "fixture-71")
            model.endDrag()
        }
    }

    @Test func folderCoordinatesContinueBelowFirstPage() {
        let metrics = GridMetrics(size: CGSize(width: 1_400, height: 1_000), columns: 7, rows: 5,
                                  folderItemCount: 100)
        let first = metrics.folderIconCenter(slot: 0)
        let sixthRow = metrics.folderIconCenter(slot: 35)
        let last = metrics.folderIconCenter(slot: 99)
        #expect(sixthRow.x == first.x)
        #expect(sixthRow.y - first.y == 795)
        #expect(last.x - first.x == 175)
        #expect(last.y - first.y == 2_226)
    }

    @Test @MainActor func folderDragLeavingGridCancelsPendingReorder() async throws {
        try await withFolderFixture { model in
            model.scrollFolder(by: 100_000)
            let grid = model.metrics.folderGridRect
            let start = CGPoint(x: grid.minX + 87.5, y: grid.minY + 79.5)
            let target = CGPoint(x: grid.minX + 262.5, y: start.y)
            model.beginDrag(.app(model.app("fixture-70")!), inFolder: "fixture-folder", pointer: start, iconCenter: start)
            model.dragMoved(to: target)
            model.dragMoved(to: CGPoint(x: start.x, y: grid.maxY + 4))
            try await Task.sleep(for: .milliseconds(350))
            #expect(model.openFolder?.0.apps[70] == "fixture-70")
            #expect(model.openFolder?.0.apps[71] == "fixture-71")
            model.endDrag()
        }
    }

    @MainActor @Test func marqueePicksTheAppsItTouchesAndKeepsEarlierPicks() async throws {
        try await withFolderFixture { model in
            model.closeFolder()
            model.ungroupAllFolders()
            #expect(model.layout.joined().allSatisfy { if case .app = $0 { true } else { false } })
            model.multiSelection = ["fixture-50"]
            let m = model.metrics
            model.marqueeChanged(from: CGPoint(x: m.iconCenter(slot: 0).x - 5, y: m.iconCenter(slot: 0).y - 5),
                                 to: CGPoint(x: m.iconCenter(slot: 1).x, y: m.iconCenter(slot: 1).y))
            let first = model.pages[0].prefix(2).compactMap { entry -> String? in
                if case .app(let app) = entry { app.id } else { nil }
            }
            #expect(model.multiSelection == Set(first + ["fixture-50"]))
            // Shrinking the rectangle drops what it no longer touches, but not the earlier pick.
            model.marqueeChanged(from: CGPoint(x: -100, y: -100), to: CGPoint(x: -90, y: -90))
            #expect(model.multiSelection == ["fixture-50"])
            model.marqueeEnded()
            #expect(model.marqueeBase == nil)
        }
    }

    @MainActor private func withFolderFixture(_ body: @MainActor (LauncherModel) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("work/folder-fixtures/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldDirectory = LayoutStore.directoryOverride
        let oldScheduling = AutoBackup.schedulingEnabled
        let oldApplying = ICloudSync.applying
        let previousDefaults = ["didSeedCategoryTags", "newApps"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        LayoutStore.directoryOverride = directory
        AutoBackup.schedulingEnabled = false
        ICloudSync.applying = true
        UserDefaults.standard.set(true, forKey: "didSeedCategoryTags")
        defer {
            LayoutStore.directoryOverride = oldDirectory
            AutoBackup.schedulingEnabled = oldScheduling
            ICloudSync.applying = oldApplying
            for (key, value) in previousDefaults {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let apps = (0..<100).map { app("Fixture \($0)", id: "fixture-\($0)") }
        LayoutStore.save(layout: [[.folder(Folder(id: "fixture-folder", name: "Fixture", apps: apps.map(\.id)))]])
        let defaults = FolderMemoryDefaults()
        defaults.set("scroll", forKey: "folderBrowseStyle")
        let model = LauncherModel(catalog: AppCatalog(apps: apps), settings: Settings(defaults: defaults))
        model.screenSize = CGSize(width: 1_400, height: 1_000)
        model.catalogChanged()
        model.openFolder("fixture-folder")
        defer { model.endDrag() }
        try await body(model)
    }
}

/// Preferences used by the fixture never reach an app's persistent defaults domain.
private final class FolderMemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: "LaunchUS.FolderFixture.\(UUID().uuidString)")! }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}
