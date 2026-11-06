import Foundation
import SQLite3

/// Reads the pages and folders of the system Launchpad (macOS 15 and earlier) from its
/// SQLite database. The file is opened read-only and never changed.
enum LaunchpadImport {
    enum Failure: LocalizedError {
        case unreadable, noPages

        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "无法读取这个文件，它可能不是启动台数据库。")
            case .noPages: String(localized: "数据库里没有找到启动台页面。")
            }
        }
    }

    /// Where Launchpad kept its database, if it's still there.
    static var systemDatabase: URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 else { return nil }
        let url = URL(fileURLWithPath: String(cString: buffer))
            .appendingPathComponent("com.apple.dock.launchpad/db/db")
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    /// Run on the old Mac to copy the database to the Desktop.
    static let copyCommand = #"cp "$(getconf DARWIN_USER_DIR)com.apple.dock.launchpad/db/db" ~/Desktop/launchpad.db"#

    /// Pages of bundle IDs and folders, in Launchpad's order. Apps that aren't installed are
    /// left in; reconciling the layout drops them.
    static func read(_ url: URL) throws -> [[LayoutItem]] {
        var db: OpaquePointer?
        // immutable=1: no locks, no journal, nothing written next to the file.
        let uri = "file:\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw Failure.unreadable
        }
        defer { sqlite3_close(db) }

        struct Item { let id: Int64; let uuid: String; let parent: Int64; let ordering: Int64 }
        guard let items = try? query(db, "SELECT rowid, uuid, parent_id, ordering FROM items", {
            Item(id: sqlite3_column_int64($0, 0), uuid: text($0, 1), parent: sqlite3_column_int64($0, 2),
                 ordering: sqlite3_column_int64($0, 3))
        }) else { throw Failure.unreadable }
        let apps = Dictionary((try? query(db, "SELECT item_id, bundleid FROM apps") {
            (sqlite3_column_int64($0, 0), text($0, 1))
        }) ?? [], uniquingKeysWith: { a, _ in a })
        let groups = Dictionary((try? query(db, "SELECT item_id, title FROM groups") {
            (sqlite3_column_int64($0, 0), text($0, 1))
        }) ?? [], uniquingKeysWith: { a, _ in a })

        let children = Dictionary(grouping: items, by: \.parent).mapValues { $0.sorted { $0.ordering < $1.ordering } }
        guard let root = items.first(where: { $0.uuid == "ROOTPAGE" }) else { throw Failure.noPages }

        /// Apps anywhere under an item (a folder's pages), in order.
        func appsUnder(_ id: Int64) -> [String] {
            (children[id] ?? []).flatMap { child -> [String] in
                if let bundle = apps[child.id] { return bundle.isEmpty ? [] : [bundle] }
                return appsUnder(child.id)
            }
        }

        let pages: [[LayoutItem]] = (children[root.id] ?? []).map { page in
            (children[page.id] ?? []).compactMap { item in
                if let bundle = apps[item.id] { return bundle.isEmpty ? nil : .app(bundle) }
                if let title = groups[item.id] {
                    let contents = appsUnder(item.id)
                    guard !contents.isEmpty else { return nil }
                    let name = title.isEmpty ? String(localized: "未命名文件夹") : title
                    return .folder(Folder(name: name, apps: contents))
                }
                return nil
            }
        }.filter { !$0.isEmpty }
        guard !pages.isEmpty else { throw Failure.noPages }
        return pages
    }

    private struct QueryError: Error {}

    private static func query<T>(_ db: OpaquePointer, _ sql: String, _ row: (OpaquePointer) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw QueryError() }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(row(statement)) }
        return result
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
