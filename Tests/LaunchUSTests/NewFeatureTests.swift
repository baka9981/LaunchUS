import Foundation
import Testing
@testable import LaunchUS

struct CurrencyTests {
    let rates = CurrencyRates.Table(date: "2026-11-05", rates: ["EUR": 1, "USD": 1.1, "CNY": 7.7, "JPY": 165])

    @Test func convertsCodesSymbolsAndChineseNames() throws {
        let a = try #require(Calculator.evaluate("100 usd to cny", rates: rates))
        #expect(a.display == "700.00 CNY")
        #expect(a.copyText == "700.00")
        #expect(a.note != nil)
        #expect(Calculator.evaluate("$100 in eur", rates: rates)?.copyText == "90.91")
        #expect(Calculator.evaluate("110美元换人民币", rates: rates)?.copyText == "770.00")
        #expect(Calculator.evaluate("1 jpy to usd", rates: rates)?.copyText == "0.006667")
    }

    @Test func staysOffWithoutRatesAndLeavesUnitsAlone() {
        #expect(Calculator.evaluate("100 usd to cny") == nil)
        #expect(Calculator.evaluate("10 km to mi", rates: rates)?.display.hasSuffix("mi") == true)
        #expect(Calculator.evaluate("100 xyz to cny", rates: rates) == nil)
    }

    @Test func parsesFrankfurter() throws {
        let json = #"{"amount":1.0,"base":"EUR","date":"2026-11-05","rates":{"USD":1.0812,"CNY":7.71}}"#
        let table = try #require(CurrencyRates.parse(Data(json.utf8)))
        #expect(table.date == "2026-11-05")
        #expect(table.rates["EUR"] == 1)
        #expect(table.rates["USD"] == 1.0812)
        #expect(CurrencyRates.parse(Data("{}".utf8)) == nil)
    }
}

struct HomebrewTests {
    @Test func mapsCasksToTheirApps() {
        let json = #"""
        {"formulae":[],"casks":[
          {"token":"libreoffice","artifacts":[{"app":["LibreOffice.app"]},{"zap":[]}]},
          {"token":"renamed","artifacts":[{"app":["Foo.app",{"target":"Bar.app"}]}]},
          {"token":"temurin@21","artifacts":[{"pkg":["x.pkg"]}]}
        ]}
        """#
        let found = Homebrew.apps(inInfo: Data(json.utf8),
                                  versions: ["libreoffice": "26.8.2", "renamed": "2.0,123", "temurin@21": "21"])
        #expect(found["LibreOffice.app"]?.version == "26.8.2")
        #expect(found["LibreOffice.app"]?.token == "libreoffice")
        #expect(found["Bar.app"]?.version == "2.0")
        #expect(found.count == 2)
    }
}

struct CleanupTests {
    @Test func readsBundleIDsFromLibraryNames() {
        #expect(AppCleanup.bundleID(inName: "com.example.Foo.plist") == "com.example.Foo")
        #expect(AppCleanup.bundleID(inName: "com.example.Foo.savedState") == "com.example.Foo")
        #expect(AppCleanup.bundleID(inName: "io.sample.app") == "io.sample.app")
        #expect(AppCleanup.bundleID(inName: "com.apple.Safari.plist") == nil)
        #expect(AppCleanup.bundleID(inName: "Google") == nil)
        #expect(AppCleanup.bundleID(inName: "Some.Folder.Name") == nil)
        #expect(AppCleanup.bundleID(inName: ".GlobalPreferences.plist") == nil)
        #expect(AppCleanup.bundleID(inName: "org.swift.swiftpm") == nil)
        #expect(AppCleanup.bundleID(inName: "group.com.example.Foo") == "com.example.Foo")
        #expect(AppCleanup.bundleID(inName: "ABCDE12345.com.example.Foo") == "com.example.Foo")
        #expect(AppCleanup.bundleID(inName: "com.example.Foo.0A1B2C3D-0000-1111-2222-333344445555.plist") == "com.example.Foo")
    }

    @Test func vendorsWithSomethingInstalledAreNotLeftovers() {
        let installed: Set<String> = ["com.google.chrome"]
        #expect(AppCleanup.isKnown("com.google.Keystone", installed: installed))
        #expect(AppCleanup.isKnown("com.google.Chrome.helper", installed: installed))
        #expect(!AppCleanup.isKnown("com.nonexistent-vendor-zz.Gone", installed: installed))
    }

    @Test func sharedFoldersNeedTheirCreatorGone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        func group(_ name: String, creator: String?) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if let creator {
                (["MCMMetadataCreator": creator] as NSDictionary)
                    .write(to: url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"), atomically: true)
            }
            return url
        }
        let installed: Set<String> = ["com.hegenberg.bettertouchtool"]
        // Named after the developer, made by an installed app: keep.
        let btt = try group("group.com.folivora.BTTShared", creator: "com.hegenberg.BetterTouchTool")
        #expect(AppCleanup.isShared("group.com.folivora.BTTShared", place: "Group Containers", at: btt, installed: installed))
        // Its app is gone: a leftover.
        let gone = try group("group.com.example.gone", creator: "com.example.gone")
        #expect(!AppCleanup.isShared("group.com.example.gone", place: "Group Containers", at: gone, installed: installed))
        // No record of who made it, or a shared folder elsewhere: keep.
        let unknown = try group("ABCDE12345.com.example.x", creator: nil)
        #expect(AppCleanup.isShared("ABCDE12345.com.example.x", place: "Group Containers", at: unknown, installed: installed))
        #expect(AppCleanup.isShared("group.com.example.gone", place: "Application Scripts", at: gone, installed: installed))
        // Ordinary names aren't shared folders.
        #expect(!AppCleanup.isShared("com.example.gone", place: "Containers", at: gone, installed: installed))
    }

    @Test func keepsTheNewestCopyPreferringApplications() {
        let now = Date()
        func copy(_ path: String, _ version: String, _ age: Double) -> DuplicateApp.Copy {
            .init(url: URL(fileURLWithPath: path), version: version, size: 1, modified: now.addingTimeInterval(-age))
        }
        let a = DuplicateApp(bundleID: "x", name: "X", copies: [
            copy("/Users/me/build/X.app", "1.2", 0), copy("/Applications/X.app", "1.2", 100), copy("/Users/me/old/X.app", "1.10", 500)])
        #expect(a.keeper?.url.path == "/Users/me/old/X.app")
        let b = DuplicateApp(bundleID: "y", name: "Y", copies: [copy("/Users/me/build/Y.app", "2", 0), copy("/Applications/Y.app", "2", 100)])
        #expect(b.keeper?.url.path == "/Applications/Y.app")
    }

    @Test func onlyStandaloneCopiesCount() {
        #expect(AppCleanup.isStandalone("/Applications/Foo.app"))
        #expect(AppCleanup.isStandalone(NSHomeDirectory() + "/Applications/Foo.app"))
        #expect(!AppCleanup.isStandalone("/Applications/Xcode.app/Contents/Applications/Simulator.app"))
        #expect(!AppCleanup.isStandalone(NSHomeDirectory() + "/.Trash/Foo.app"))
        #expect(!AppCleanup.isStandalone("/System/Applications/Notes.app"))
    }
}

struct FileSearchTests {
    @Test func skipsLibraryHiddenAndPackageInsides() {
        let home = NSHomeDirectory()
        #expect(FileSearch.isShown(home + "/Documents/Report.pdf"))
        #expect(FileSearch.isShown(home + "/Desktop/Project"))
        #expect(!FileSearch.isShown(home + "/Library/Caches/x.txt"))
        #expect(!FileSearch.isShown(home + "/.config/report"))
        #expect(!FileSearch.isShown(home + "/Pictures/Photos Library.photoslibrary/database/report"))
        #expect(!FileSearch.isShown(home + "/code/web/node_modules/report/index.js"))
    }
}

struct OpenAllCommandTests {
    @Test func parsesTheLink() {
        #expect(URLCommand(url: URL(string: "launchus://openall?name=%E5%B7%A5%E4%BD%9C")!) == .openAll("工作"))
        #expect(URLCommand(url: URL(string: "launchus://group?name=Dev")!) == .openAll("Dev"))
        #expect(URLCommand(url: URL(string: "launchus://openall")!) == nil)
    }
}
