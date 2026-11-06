import CoreGraphics
import Foundation
import Testing
@testable import LaunchUS

private final class ControlledCatalogScanner: @unchecked Sendable {
    let started: AsyncStream<Int>
    private let start: AsyncStream<Int>.Continuation
    private let lock = NSLock()
    private var next = 0
    private let results: [[AppItem]]
    private let gates: [DispatchSemaphore]

    init(_ results: [[AppItem]]) {
        self.results = results
        gates = results.map { _ in DispatchSemaphore(value: 0) }
        (started, start) = AsyncStream.makeStream(of: Int.self)
    }

    func scan() -> [AppItem] {
        lock.lock()
        let index = next
        next += 1
        lock.unlock()
        start.yield(index)
        guard index < results.count else { return [] }
        gates[index].wait()
        return results[index]
    }

    func finish(_ index: Int) { gates[index].signal() }
    func finishAll() { gates.forEach { $0.signal() } }
}

@Suite(.timeLimit(.minutes(1))) @MainActor
struct AppCatalogTests {
    private func app(_ id: String, path: String? = nil) -> AppItem {
        AppItem(id: id, url: URL(fileURLWithPath: path ?? "/catalog-fixture/\(id).app"),
                bundleID: id, name: id, searchNames: [id], pinyinKeys: [], category: nil)
    }

    private func image(width: Int) -> CGImage {
        CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func reentrantReloadWaitsForItsOwnScan() async {
        let scanner = ControlledCatalogScanner([[app("first")], [app("second")]])
        defer { scanner.finishAll() }
        var starts = scanner.started.makeAsyncIterator()
        let catalog = AppCatalog(scan: { scanner.scan() }, renderIcon: { _ in nil }, folderPaths: { [] })
        let (completed, completion) = AsyncStream.makeStream(of: [String].self)
        var completions = completed.makeAsyncIterator()
        var nestedResults: [[String]] = []
        catalog.onChange = {
            catalog.onChange = nil
            catalog.reload(force: true) {
                nestedResults.append($0.map(\.id))
                completion.yield($0.map(\.id))
            }
        }
        catalog.reload { completion.yield($0.map(\.id)) }
        #expect(await starts.next() == 0)
        scanner.finish(0)
        #expect(await completions.next() == ["first"])
        #expect(nestedResults.isEmpty, "The second reload must not receive the first scan's result")
        #expect(await starts.next() == 1)
        scanner.finish(1)
        if nestedResults.isEmpty {
            #expect(await completions.next() == ["second"])
        }
        #expect(nestedResults == [["second"]])
    }

    @Test func forcedReloadDuringScanReceivesFreshResult() async {
        let scanner = ControlledCatalogScanner([[app("first")], [app("second")]])
        defer { scanner.finishAll() }
        var starts = scanner.started.makeAsyncIterator()
        let catalog = AppCatalog(scan: { scanner.scan() }, renderIcon: { _ in nil }, folderPaths: { [] })
        let (completed, completion) = AsyncStream.makeStream(of: [String].self)
        var completions = completed.makeAsyncIterator()
        var forcedResults: [[String]] = []
        catalog.reload { completion.yield($0.map(\.id)) }
        #expect(await starts.next() == 0)
        catalog.reload(force: true) {
            forcedResults.append($0.map(\.id))
            completion.yield($0.map(\.id))
        }
        scanner.finish(0)
        #expect(await completions.next() == ["first"])
        #expect(forcedResults.isEmpty, "A forced request made during scanning needs a subsequent scan")
        guard forcedResults.isEmpty else { return }
        #expect(await starts.next() == 1)
        scanner.finish(1)
        #expect(await completions.next() == ["second"])
        #expect(forcedResults == [["second"]])
    }

    @Test func movingAnAppRefreshesItsCachedIcon() async {
        let scanner = ControlledCatalogScanner([[app("app", path: "/old/app.app")],
                                                [app("app", path: "/new/app.app")]])
        defer { scanner.finishAll() }
        var starts = scanner.started.makeAsyncIterator()
        let oldIcon = image(width: 1)
        let newIcon = image(width: 2)
        let catalog = AppCatalog(scan: { scanner.scan() },
                                 renderIcon: { $0 == "/old/app.app" ? oldIcon : newIcon },
                                 folderPaths: { [] })
        catalog.reload()
        #expect(await starts.next() == 0)
        scanner.finish(0)
        await waitUntil { catalog.icons["app"]?.width == 1 }
        #expect(catalog.icons["app"]?.width == 1)

        catalog.reload(force: true)
        #expect(await starts.next() == 1)
        scanner.finish(1)
        await waitUntil { catalog.icons["app"]?.width == 2 }
        #expect(catalog.icons["app"]?.width == 2, "A bundle ID at a new path must not reuse the old path's icon")
    }

    @Test func darkIconsRedrawWithTheDarkPath() async {
        let scanner = ControlledCatalogScanner([[app("app", path: "/x/app.app")]])
        defer { scanner.finishAll() }
        var starts = scanner.started.makeAsyncIterator()
        let light = image(width: 1)
        let dark = image(width: 2)
        let catalog = AppCatalog(scan: { scanner.scan() },
                                 renderIcon: { $0 == IconRenderer.darkPrefix + "/x/app.app" ? dark : light },
                                 folderPaths: { [] })
        catalog.reload()
        #expect(await starts.next() == 0)
        scanner.finish(0)
        await waitUntil { catalog.icons["app"]?.width == 1 }

        catalog.darkIcons = true
        await waitUntil { catalog.icons["app"]?.width == 2 }
        #expect(catalog.icons["app"]?.width == 2)
        catalog.darkIcons = false
        await waitUntil { catalog.icons["app"]?.width == 1 }
        #expect(catalog.icons["app"]?.width == 1)
    }

    @Test func darkIconModes() {
        #expect(DarkIconMode.auto.resolve(dark: true) && !DarkIconMode.auto.resolve(dark: false))
        #expect(DarkIconMode.always.resolve(dark: false))
        #expect(!DarkIconMode.never.resolve(dark: true))
        #expect(AppearanceMode.system.nsAppearance == nil)
        #expect(AppearanceMode.dark.nsAppearance?.name == .darkAqua)
    }

    @Test(arguments: [false, true]) func systemIconRendersForASystemApp(dark: Bool) throws {
        let path = "/System/Applications/Notes.app"
        try #require(FileManager.default.fileExists(atPath: path))
        let image = try #require(SystemIcon.image(bundle: path, pixels: 64, dark: dark))
        #expect(image.width >= 64)
    }

    @Test func removedAppsDoNotKeepCachedIcons() async {
        let scanner = ControlledCatalogScanner([[app("app")], []])
        defer { scanner.finishAll() }
        var starts = scanner.started.makeAsyncIterator()
        let icon = image(width: 1)
        let catalog = AppCatalog(scan: { scanner.scan() }, renderIcon: { _ in icon }, folderPaths: { [] })
        catalog.reload()
        #expect(await starts.next() == 0)
        scanner.finish(0)
        await waitUntil { catalog.icons["app"] != nil }
        #expect(catalog.icons["app"] != nil)

        let (completed, completion) = AsyncStream.makeStream(of: Void.self)
        var completions = completed.makeAsyncIterator()
        catalog.reload(force: true) { _ in completion.yield(()) }
        #expect(await starts.next() == 1)
        scanner.finish(1)
        _ = await completions.next()
        #expect(catalog.icons["app"] == nil, "Removed apps should release their icon bitmap")
    }

    @Test func updatedBundleRefreshesIconAtTheSamePath() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = project.appendingPathComponent("work/catalog-fixture-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: directory.path)
        let installed = app("app", path: directory.path)
        let scanner = ControlledCatalogScanner([[installed], [installed]])
        defer { scanner.finishAll() }
        var starts = scanner.started.makeAsyncIterator()
        let oldIcon = image(width: 1)
        let newIcon = image(width: 2)
        let catalog = AppCatalog(scan: { scanner.scan() }, renderIcon: { path in
            let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return date == oldDate ? oldIcon : newIcon
        }, folderPaths: { [] })
        catalog.reload()
        #expect(await starts.next() == 0)
        scanner.finish(0)
        await waitUntil { catalog.icons["app"]?.width == 1 }
        #expect(catalog.icons["app"]?.width == 1)

        try FileManager.default.setAttributes([.modificationDate: oldDate.addingTimeInterval(10)],
                                               ofItemAtPath: directory.path)
        catalog.reload(force: true)
        #expect(await starts.next() == 1)
        scanner.finish(1)
        await waitUntil { catalog.icons["app"]?.width == 2 }
        #expect(catalog.icons["app"]?.width == 2, "An updated bundle must invalidate its cached bitmap")
    }

    @Test func firstIconsPublishBeforeTheWholeCatalogFinishes() async {
        let installed = (0..<20).map { app("app\($0)") }
        let scanner = ControlledCatalogScanner([installed])
        defer { scanner.finishAll() }
        var starts = scanner.started.makeAsyncIterator()
        let lastGate = DispatchSemaphore(value: 0)
        defer { lastGate.signal() }
        let (blocked, block) = AsyncStream.makeStream(of: Void.self)
        var blocks = blocked.makeAsyncIterator()
        let icon = image(width: 1)
        let catalog = AppCatalog(scan: { scanner.scan() }, renderIcon: { path in
            if path.hasSuffix("/app19.app") {
                block.yield(())
                lastGate.wait()
            }
            return icon
        }, folderPaths: { [] })
        var changes = 0
        catalog.onChange = { changes += 1 }
        catalog.reload()
        #expect(await starts.next() == 0)
        scanner.finish(0)
        _ = await blocks.next()
        await waitUntil { catalog.icons.count >= 16 }
        #expect(catalog.icons.count >= 16, "A slow final icon must not hold back the first visible icons")
        #expect(catalog.icons["app19"] == nil)
        #expect(changes == 1, "Publishing icons must not refresh the layout model")
        lastGate.signal()
        await waitUntil { catalog.icons.count == 20 }
        #expect(catalog.icons.count == 20)
    }

    @Test func lateRenderFromAnOldPathCannotReplaceTheNewIcon() async {
        let scanner = ControlledCatalogScanner([[app("app", path: "/old/app.app")],
                                                [app("app", path: "/new/app.app")]])
        defer { scanner.finishAll() }
        var starts = scanner.started.makeAsyncIterator()
        let oldGate = DispatchSemaphore(value: 0)
        defer { oldGate.signal() }
        let (blocked, block) = AsyncStream.makeStream(of: Void.self)
        var blocks = blocked.makeAsyncIterator()
        let oldIcon = image(width: 1)
        let newIcon = image(width: 2)
        let catalog = AppCatalog(scan: { scanner.scan() }, renderIcon: { path in
            if path == "/old/app.app" {
                block.yield(())
                oldGate.wait()
                return oldIcon
            }
            return newIcon
        }, folderPaths: { [] })
        catalog.reload()
        #expect(await starts.next() == 0)
        scanner.finish(0)
        _ = await blocks.next()
        catalog.reload(force: true)
        #expect(await starts.next() == 1)
        scanner.finish(1)
        await waitUntil { catalog.icons["app"]?.width == 2 }
        #expect(catalog.icons["app"]?.width == 2)
        oldGate.signal()
        await waitUntil { catalog.icons["app"]?.width == 1 }
        #expect(catalog.icons["app"]?.width == 2, "The old render must be discarded after its source changes")
    }

    @Test func visibleLayoutIconsPublishBeforeEarlierAlphabeticalApps() async {
        let installed = (0..<40).map { app("app\($0)") }
        let scanner = ControlledCatalogScanner([installed])
        defer { scanner.finishAll() }
        var starts = scanner.started.makeAsyncIterator()
        let otherPageGate = DispatchSemaphore(value: 0)
        defer { otherPageGate.signal() }
        let (blocked, block) = AsyncStream.makeStream(of: Void.self)
        var blocks = blocked.makeAsyncIterator()
        let icon = image(width: 1)
        let catalog = AppCatalog(scan: { scanner.scan() }, renderIcon: { path in
            if path.hasSuffix("/app11.app") {
                block.yield(())
                otherPageGate.wait()
            }
            return icon
        }, folderPaths: { [] })
        let visible = ["app35", "app36", "app37", "app38", "app39"] + (0..<11).map { "app\($0)" }
        var currentPage: [String] = []
        catalog.onChange = { currentPage = visible }
        catalog.iconPriority = { currentPage + ["app35", "not-installed"] }
        catalog.reload()
        #expect(await starts.next() == 0)
        scanner.finish(0)
        _ = await blocks.next()
        await waitUntil { visible.allSatisfy { catalog.icons[$0] != nil } }
        #expect(visible.allSatisfy { catalog.icons[$0] != nil },
                "The first rendered batch must follow the reconciled layout, including apps at the end of scanning")
        #expect(catalog.icons["app11"] == nil)
        otherPageGate.signal()
        await waitUntil { catalog.icons.count == 40 }
        #expect(catalog.icons.count == 40)
    }
}
