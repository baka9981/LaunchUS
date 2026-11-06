import Foundation
import SQLite3
import Testing
@testable import LaunchUS

@Suite struct URLCommandTests {
    func parse(_ s: String) -> URLCommand? { URLCommand(url: URL(string: s)!) }

    @Test func commands() {
        #expect(parse("launchus://") == .open)
        #expect(parse("launchus://toggle") == .toggle)
        #expect(parse("launchus://hide") == .close)
        #expect(parse("launchus://search?q=%E5%BE%AE%E4%BF%A1") == .search("微信"))
        #expect(parse("launchus://folder?name=Tools") == .folder("Tools"))
        #expect(parse("launchus://page?n=2") == .page(2))
        #expect(parse("launchus://page?n=0") == nil)
        #expect(parse("launchus://settings?tab=general") == .settings(.general))
        #expect(parse("launchus://nope") == nil)
        #expect(parse("https://open") == nil)
    }
}

@Suite struct NewAppsTests {
    @Test func firstRunMarksNothing() {
        let state = NewApps.update(nil, apps: [app("A"), app("B")])
        #expect(state.new.isEmpty)
        #expect(state.known == ["A", "B"])
    }

    @Test func newAppsAreMarkedUntilOpened() {
        let found = Date(timeIntervalSince1970: 1000)
        var state = NewApps.update(NewApps.State(known: ["A"], new: [:]), apps: [app("A"), app("B")], now: found)
        #expect(state.new.keys.sorted() == ["B"])
        var b = app("B")
        b.lastUsedDate = found.addingTimeInterval(60)
        state = NewApps.update(state, apps: [app("A"), b], now: found.addingTimeInterval(120))
        #expect(state.new.isEmpty)
    }

    @Test func removedAppsAreForgotten() {
        let state = NewApps.update(NewApps.State(known: ["A", "B"], new: ["B": Date()]), apps: [app("A")])
        #expect(state.new.isEmpty)
        #expect(state.known == ["A"])
    }
}

@Suite struct LaunchpadImportTests {
    @Test func readsPagesAndFolders() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lp-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE items (rowid INTEGER PRIMARY KEY, uuid TEXT, flags INTEGER, type INTEGER, parent_id INTEGER, ordering INTEGER);
        CREATE TABLE apps (item_id INTEGER, title TEXT, bundleid TEXT);
        CREATE TABLE groups (item_id INTEGER, category_id INTEGER, title TEXT);
        INSERT INTO items VALUES (1,'ROOTPAGE',0,1,0,0);
        INSERT INTO items VALUES (2,'p1',0,3,1,0), (3,'p2',0,3,1,1);
        INSERT INTO items VALUES (10,'a',0,4,2,1), (11,'b',0,4,2,0), (12,'g',0,2,2,2);
        INSERT INTO items VALUES (13,'gp',0,3,12,0), (14,'c',0,4,13,0), (15,'d',0,4,13,1);
        INSERT INTO items VALUES (16,'e',0,4,3,0);
        INSERT INTO apps VALUES (10,'A','com.a'), (11,'B','com.b'), (14,'C','com.c'), (15,'D','com.d'), (16,'E','com.e');
        INSERT INTO groups VALUES (12,0,'Tools');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let pages = try LaunchpadImport.read(url)
        #expect(pages.count == 2)
        #expect(pages[0].count == 3)
        if case .folder(let folder) = pages[0][2] {
            #expect(folder.name == "Tools")
            #expect(folder.apps == ["com.c", "com.d"])
        } else { Issue.record("expected a folder") }
        #expect(Array(pages[0].prefix(2)) == [.app("com.b"), .app("com.a")])
        #expect(pages[1] == [.app("com.e")])
    }

    @Test func rejectsOtherFiles() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-db-\(UUID().uuidString)")
        try? Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: LaunchpadImport.Failure.self) { try LaunchpadImport.read(url) }
    }
}
