import Foundation
import Testing
@testable import LaunchUS

func app(_ name: String, id: String? = nil) -> AppItem {
    AppItem(id: id ?? name, url: URL(fileURLWithPath: "/Applications/\(name).app"), bundleID: id,
            name: name, searchNames: [name.lowercased()], pinyinKeys: Pinyin.keys(for: name), category: nil)
}

@Suite struct PinyinTests {
    @Test func chinese() {
        let keys = Pinyin.keys(for: "微信")
        #expect(keys.contains("weixin"))
        #expect(keys.contains("wx"))
    }

    @Test func mixedLatinAndChinese() {
        let keys = Pinyin.keys(for: "QQ音乐")
        #expect(keys.contains("qqyinle"))
        #expect(keys.contains("qqyl"))
    }

    @Test func latinInitials() {
        #expect(Pinyin.keys(for: "Final Cut Pro").contains("fcp"))
        #expect(Pinyin.keys(for: "RimWorld").contains("rw"))
    }
}

@Suite struct AppSearchTests {
    let apps = [app("微信"), app("网易云音乐"), app("Safari"), app("System Settings"), app("Photoshop")]

    @Test func pinyinInitialsFindChineseApp() {
        #expect(AppSearch.search("wx", in: apps).first?.name == "微信")
    }

    @Test func prefixBeatsSubstring() {
        let results = AppSearch.search("s", in: apps).map(\.name)
        #expect(results.first == "Safari")
        #expect(results.contains("System Settings"))
    }

    @Test func wordPrefixMatches() {
        #expect(AppSearch.search("sett", in: apps).map(\.name) == ["System Settings"])
    }

    @Test func exactAliasRanksFirst() {
        let results = AppSearch.search("ps", in: apps, aliases: ["Safari": ["ps"]])
        #expect(results.first?.name == "Safari")
    }

    @Test func noMatch() {
        #expect(AppSearch.search("zzzz", in: apps).isEmpty)
    }

    @Test func parseSplitsTags() {
        let parsed = AppSearch.parse("#设计 ＃常用 ps")
        #expect(parsed.tags == ["设计", "常用"])
        #expect(parsed.text == "ps")
    }

    @Test func tagFilter() {
        let tags = ["Photoshop": ["设计"], "Safari": ["常用"]]
        #expect(AppSearch.search("#设计", in: apps, tags: tags).map(\.name) == ["Photoshop"])
        // A tag prefix in pinyin narrows down while typing.
        #expect(AppSearch.search("#sj", in: apps, tags: tags).map(\.name) == ["Photoshop"])
        #expect(AppSearch.search("#设计 #常用", in: apps, tags: tags).isEmpty)
    }
}
