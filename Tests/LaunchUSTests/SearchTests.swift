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

@Suite struct CategoryConditionTests {
    func categorized(_ name: String, _ category: String?) -> AppItem {
        AppItem(id: name, url: URL(fileURLWithPath: "/Applications/\(name).app"), bundleID: name,
                name: name, searchNames: [name.lowercased()], pinyinKeys: Pinyin.keys(for: name), category: category)
    }

    @Test func atTokenPicksAppStoreCategory() {
        let apps = [categorized("Xcode", "public.app-category.developer-tools"),
                    categorized("Notes", "public.app-category.productivity"),
                    categorized("Numbers", "public.app-category.business")]
        let token = AppSearch.categoryToken(.productivity)
        #expect(AppSearch.search(token, in: apps).map(\.name) == ["Notes", "Numbers"])
        #expect(AppSearch.search("@developer", in: apps).map(\.name) == ["Xcode"])
        #expect(AppSearch.search(token + " num", in: apps).map(\.name) == ["Numbers"])
        #expect(AppSearch.search("@不存在的分类", in: apps).isEmpty, "an unknown category matches nothing")
    }

    @Test func userChoiceOverridesDeveloperCategory() {
        let apps = [categorized("Xcode", "public.app-category.developer-tools")]
        #expect(AppSearch.search("@utilities", in: apps, group: { _ in .utilities }).map(\.name) == ["Xcode"])
    }

    @Test func categoryTokenRoundTrips() {
        for group in AppCategoryName.Group.allCases {
            #expect(AppSearch.categories(in: AppSearch.categoryToken(group)).groups == [group])
        }
    }
}

@Suite struct FormulaTests {
    let apps = ["Xcode", "Figma", "Notes", "Steam"].map { name in
        AppItem(id: name, url: URL(fileURLWithPath: "/Applications/\(name).app"), bundleID: name,
                name: name, searchNames: [name.lowercased()], pinyinKeys: Pinyin.keys(for: name), category: nil)
    }
    let tags = ["Xcode": ["工具"], "Figma": ["设计", "工具"], "Notes": ["效率"], "Steam": ["游戏"]]

    func names(_ q: String) -> [String] { AppSearch.search(q, in: apps, tags: tags).map(\.name) }

    @Test func unionIntersectionComplement() {
        #expect(names("#工具 ∪ #效率") == ["Figma", "Notes", "Xcode"])
        #expect(names("#工具 ∩ #设计") == ["Figma"])
        #expect(names("#工具 #设计") == ["Figma"], "side by side is ∩")
        #expect(names("¬ #游戏") == ["Figma", "Notes", "Xcode"])
        #expect(names("( #工具 ∪ #效率 ) ∩ ¬ #设计") == ["Notes", "Xcode"])
        #expect(names("#工具 ∪ #效率 ∩ #设计") == ["Figma", "Xcode"], "∩ binds tighter than ∪")
    }

    @Test func wordsAndGluedForms() {
        #expect(names("#工具 或 #效率") == names("#工具 ∪ #效率"))
        #expect(names("(#工具 | #游戏) -#设计") == ["Steam", "Xcode"])
        #expect(AppSearch.tokens("(#a ∪ #b) ∩ ¬#c") == [.open, .term("#a"), .or, .term("#b"), .close, .and, .not, .term("#c")])
    }

    @Test func completeness() {
        #expect(AppSearch.isComplete(AppSearch.tokens("( #a ∪ #b ) ∩ ¬ #c")))
        #expect(AppSearch.isComplete(AppSearch.tokens("#a #b")))
        #expect(!AppSearch.isComplete(AppSearch.tokens("( #a ∪ #b")))
        #expect(!AppSearch.isComplete(AppSearch.tokens("#a ∪")))
        #expect(!AppSearch.isComplete(AppSearch.tokens("#a ) #b")))
        #expect(names("( #工具 ∪") == ["Figma", "Xcode"], "a half-built formula still shows something")
    }
}

@Suite struct FormulaEditingTests {
    func removing(_ i: Int, _ q: String) -> String {
        AppSearch.formulaText(FormulaBuilder.removing(i, from: AppSearch.tokens(q)))
    }

    @Test func removingKeepsTheRestReadable() {
        #expect(removing(2, "#a ∩ #b ∪ #c") == "#a ∪ #c")
        #expect(removing(0, "#a ∩ #b ∪ #c") == "#b ∪ #c")
        #expect(removing(2, "#a ∩ #b") == "#a")
        #expect(removing(1, "¬ #a ∪ #b") == "#b")
        #expect(removing(3, "#a ∩ ¬ #b ∪ #c") == "#a ∪ #c")
        #expect(removing(1, "#a ∪ #b") == "#a #b", "taking out an operator leaves the implied ∩")
    }

    @Test func bracketsGoInPairs() {
        #expect(removing(0, "( #a ∪ #b ) ∩ #c") == "#a ∪ #b ∩ #c")
        #expect(removing(4, "( #a ∪ #b ) ∩ #c") == "#a ∪ #b ∩ #c")
        #expect(removing(0, "( ( #a ) )") == "( #a )")
    }

    @Test func typedSearchesAreNotNegations() {
        #expect(AppSearch.tokens("-ps") == [.term("-ps")])
        #expect(AppSearch.tokens("非常") == [.term("非常")])
        #expect(AppSearch.tokens("-#游戏") == [.not, .term("#游戏")])
        #expect(AppSearch.tokens("¬ps") == [.not, .term("ps")])
    }
}
