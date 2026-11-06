import Foundation
import Testing
@testable import LaunchUS

@Suite struct LayoutOpsTests {
    @Test func repackPushesOverflowForward() {
        let pages: [[LayoutItem]] = [["a", "b", "c"].map(LayoutItem.app), ["d"].map(LayoutItem.app)]
        let result = LayoutOps.repack(pages, perPage: 2)
        #expect(result == [[.app("a"), .app("b")], [.app("c"), .app("d")]])
    }

    @Test func repackRemovesEmptyPages() {
        let result = LayoutOps.repack([[.app("a")], [], [.app("b")]], perPage: 4)
        #expect(result == [[.app("a")], [.app("b")]])
    }

    @Test func reconcileDropsMissingAndHiddenAndAppendsNew() {
        let installed = ["a", "b", "c", "new"].map { app($0) }
        let pages: [[LayoutItem]] = [[.app("a"), .app("gone"), .app("b"), .app("c")]]
        let result = LayoutOps.reconcile(pages, installed: installed, hidden: ["b"], perPage: 10)
        #expect(result == [[.app("a"), .app("c"), .app("new")]])
    }

    @Test func reconcileKeepsEachAppOnce() {
        let installed = ["a", "b"].map { app($0) }
        let folder = Folder(id: "f", name: "F", apps: ["a", "b"])
        let result = LayoutOps.reconcile([[.folder(folder), .app("a")]], installed: installed, hidden: [], perPage: 10)
        #expect(result == [[.folder(folder)]])
    }

    @Test func reconcileEmptiesFoldersButKeepsSmartOnes() {
        let smart = Folder(id: "s", name: "Smart", apps: [], query: "#设计")
        let stale = Folder(id: "f", name: "F", apps: ["gone"])
        let result = LayoutOps.reconcile([[.folder(smart), .folder(stale)]], installed: [], hidden: [], perPage: 10)
        #expect(result == [[.folder(smart)]])
    }

    @Test func alphabeticalIgnoresFolders() {
        let result = LayoutOps.alphabetical(["c", "a", "b"].map { app($0) }, perPage: 2)
        #expect(result.joined().count == 3)
        #expect(result.count == 2)
    }

    @Test func backupRoundTrip() throws {
        var meta = AppMeta()
        meta.displayName = "微信"
        meta.tags = ["社交"]
        meta.hidden = true
        let backup = LayoutBackup(pages: [[.app("a"), .folder(Folder(id: "f", name: "F", apps: ["b"]))]],
                                  meta: ["a": meta])
        let decoded = try JSONDecoder().decode(LayoutBackup.self, from: JSONEncoder().encode(backup))
        #expect(decoded.pages == backup.pages)
        #expect(decoded.meta == backup.meta)
    }

    @Test func metaDecodesMissingFields() throws {
        let meta = try JSONDecoder().decode(AppMeta.self, from: Data(#"{"displayName":"X"}"#.utf8))
        #expect(meta.displayName == "X")
        #expect(meta.tags.isEmpty)
        #expect(!meta.hidden)
    }
}

@Suite(.serialized) struct AutoBackupTests {
    private func withTempStore(_ body: (URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchUSTests-\(UUID().uuidString)")
        LayoutStore.directoryOverride = dir
        AutoBackup.schedulingEnabled = false
        UserDefaults.standard.removeObject(forKey: "autoBackupCount")
        defer {
            LayoutStore.directoryOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir)
    }

    @Test func skipsUnchangedAndPrunesOldest() {
        withTempStore { _ in
            LayoutStore.save(layout: [[.app("a")]])
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(AutoBackup.snapshot(now: start) != nil)
            #expect(AutoBackup.snapshot(now: start.addingTimeInterval(1)) == nil, "unchanged layout")

            for i in 1...12 {
                LayoutStore.save(layout: [[.app("a\(i)")]])
                AutoBackup.snapshot(now: start.addingTimeInterval(Double(i) * 10))
            }
            let list = AutoBackup.list()
            #expect(list.count == 10)
            #expect(list.first?.date == start.addingTimeInterval(120))
            #expect(list == list.sorted { $0.date > $1.date })
        }
    }

    @Test func offWhenLimitIsZero() {
        withTempStore { _ in
            UserDefaults.standard.set(0, forKey: "autoBackupCount")
            defer { UserDefaults.standard.removeObject(forKey: "autoBackupCount") }
            LayoutStore.save(layout: [[.app("a")]])
            #expect(AutoBackup.snapshot() == nil)
            #expect(AutoBackup.list().isEmpty)
        }
    }
}
