import Foundation
import Testing
@testable import LaunchUS

@MainActor
struct WidgetPluginTests {
    private func plugin(_ manifest: String, files: [String] = ["index.html"]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("test.launchuswidget")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        for file in files { try Data("<p>hi</p>".utf8).write(to: folder.appendingPathComponent(file)) }
        return folder
    }

    @Test func loadsAValidPlugin() throws {
        let folder = try plugin(#"{"id":"com.example.hello","name":"Hello","sizes":["medium","small","huge"],"permissions":["system","camera"],"refresh":5}"#)
        let manifest = try WidgetManifest.load(folder).get()
        #expect(manifest.spec == 1)
        #expect(manifest.entry == "index.html")
        #expect(manifest.sizes == [.small, .medium])
        #expect(manifest.permissions == [.system])
        #expect(manifest.refresh == 5)
    }

    @Test func rejectsBadPlugins() throws {
        let cases: [(String, WidgetManifest.Problem)] = [
            (#"{"id":"launchus.clock","name":"x","sizes":["small"]}"#, .badID("launchus.clock")),
            (#"{"id":"hello","name":"x","sizes":["small"]}"#, .badID("hello")),
            (#"{"id":"com.example.x","name":"x","sizes":["huge"]}"#, .noSizes),
            (#"{"id":"com.example.x","name":"x","sizes":["small"],"spec":2}"#, .newerSpec(2)),
            (#"{"id":"com.example.x","name":"x","sizes":["small"],"entry":"main.html"}"#, .missingEntry("main.html")),
            (#"{"id":"com.example.x","name":"x","sizes":["small"],"entry":"../../etc/hosts"}"#, .missingEntry("../../etc/hosts")),
        ]
        for (json, problem) in cases {
            let result = WidgetManifest.load(try plugin(json))
            #expect(throws: problem) { try result.get() }
        }
        guard case .failure(.unreadable) = WidgetManifest.load(try plugin(#"{"name":"x"}"#)) else {
            Issue.record("missing id should be unreadable")
            return
        }
    }

    @Test func validIDs() {
        #expect(WidgetManifest.isValidID("com.example.weather-2"))
        #expect(WidgetManifest.isValidID("io.github.some_one.clock"))
        #expect(!WidgetManifest.isValidID("LaunchUS.clock"))
        #expect(!WidgetManifest.isValidID("com..example"))
        #expect(!WidgetManifest.isValidID("com.exämple"))
        #expect(!WidgetManifest.isValidID("com.example/../x"))
    }

    @Test func textPicksTheBestLanguage() throws {
        let text = try JSONDecoder().decode(WidgetManifest.Text.self,
                                            from: Data(#"{"en":"Weather","zh-Hans":"天气","ja":"天気"}"#.utf8))
        #expect(text.resolved(["zh-Hans-CN"]) == "天气")
        #expect(text.resolved(["ja-JP"]) == "天気")
        #expect(text.resolved(["fr-FR"]) == "Weather")
        #expect(WidgetManifest.Text("Plain").resolved(["ja"]) == "Plain")
    }

    @Test func filesStayInTheFolder() throws {
        let folder = try plugin(#"{"id":"com.example.x","name":"x","sizes":["small"]}"#)
        let manifest = try WidgetManifest.load(folder).get()
        #expect(manifest.file("index.html", in: folder) != nil)
        #expect(manifest.file("../other/index.html", in: folder) == nil)
        #expect(manifest.file("/etc/hosts", in: folder)?.path.hasSuffix("test.launchuswidget/etc/hosts") == true)
    }

    @Test func sizeFitsWhatThePluginOffers() throws {
        let folder = try plugin(#"{"id":"com.example.x","name":"x","sizes":["medium"],"open":"javascript:alert(1)"}"#)
        let provider = WidgetProvider(id: "com.example.x", source: .plugin(folder: folder, manifest: try WidgetManifest.load(folder).get()))
        #expect(provider.fit(.small) == .medium)
        #expect(provider.fit(.large) == .medium)
        #expect(provider.openTarget == nil)
        let clock = WidgetProvider(id: BuiltInWidget.clock.rawValue, source: .builtIn(.clock))
        #expect(clock.sizes == WidgetItem.Size.allCases)
    }

    @Test func examplePluginsLoad() throws {
        let examples = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/widgets")
        let folders = try FileManager.default.contentsOfDirectory(at: examples, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == WidgetRegistry.pluginExtension }
        #expect(folders.count == 2)
        for folder in folders {
            #expect(throws: Never.self) { try WidgetManifest.load(folder).get() }
        }
    }

    @Test func widgetsURL() {
        #expect(URLCommand(url: URL(string: "launchus://widgets")!) == .widgets)
    }
}
