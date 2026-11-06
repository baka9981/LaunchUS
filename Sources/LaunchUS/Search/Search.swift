import Foundation

enum Pinyin {
    /// Returns romanized keys for a name:
    /// - full:     "微信" → "weixin", "QQ音乐" → "qqyinle"
    /// - compact:  Latin runs kept whole, Han reduced to initials: "QQ音乐" → "qqyl"
    /// - initials: first letter of every word / syllable: "Final Cut Pro" → "fcp", "RimWorld" → "rw"
    static func keys(for name: String) -> [String] {
        var full = "", compact = "", initials = ""
        var wordStart = true
        var prevLower = false

        for ch in name {
            if isHan(ch) {
                let syllable = romanize(ch)
                full += syllable
                compact += syllable.prefix(1)
                initials += syllable.prefix(1)
                wordStart = true
                prevLower = false
            } else if ch.isLetter || ch.isNumber {
                if ch.isUppercase && prevLower { wordStart = true }
                let latin = String(ch)
                    .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
                    .lowercased()
                full += latin
                compact += latin
                if wordStart {
                    initials += latin.prefix(1)
                    wordStart = false
                }
                prevLower = ch.isLowercase
            } else {
                wordStart = true
                prevLower = false
            }
        }
        return [full, compact, initials].filter { !$0.isEmpty }
    }

    private static func isHan(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0x20000...0x2A6DF).contains(v)
    }

    private static func romanize(_ ch: Character) -> String {
        let s = NSMutableString(string: String(ch))
        CFStringTransform(s, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(s, nil, kCFStringTransformStripDiacritics, false)
        return (s as String).lowercased().replacingOccurrences(of: " ", with: "")
    }
}

enum AppSearch {
    /// Splits "#设计 #常用 ps" into tag tokens (without "#") and the remaining text.
    static func parse(_ query: String) -> (tags: [String], text: String) {
        var tags: [String] = []
        var words: [String] = []
        for token in query.split(whereSeparator: \.isWhitespace) {
            if let first = token.first, first == "#" || first == "＃" {
                let tag = token.dropFirst().lowercased()
                if !tag.isEmpty { tags.append(tag) }
            } else {
                words.append(String(token))
            }
        }
        return (tags, words.joined(separator: " "))
    }

    /// Tags a "#…" token refers to: the tag with exactly that name, else every tag starting
    /// with it (pinyin included), so results narrow down while the tag is being typed.
    static func tagsMatching(_ token: String, in allTags: [String]) -> [String] {
        let t = token.lowercased()
        if let exact = allTags.first(where: { $0.lowercased() == t }) { return [exact] }
        return allTags.filter { tag in
            tag.lowercased().hasPrefix(t) || Pinyin.keys(for: tag).contains { $0.hasPrefix(t) }
        }
    }

    /// Searches names, aliases and pinyin; "#tag" tokens filter by tag (several = all of them).
    static func search(_ query: String, in apps: [AppItem], aliases: [String: [String]] = [:],
                       tags: [String: [String]] = [:]) -> [AppItem] {
        let (tagTokens, text) = parse(query)
        var pool = apps
        if !tagTokens.isEmpty {
            let allTags = Array(Set(tags.values.joined()))
            for token in tagTokens {
                let wanted = Set(tagsMatching(token, in: allTags))
                pool = pool.filter { !wanted.isDisjoint(with: tags[$0.id] ?? []) }
            }
            if text.isEmpty {
                return pool.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        return search(text, in: pool, aliases: aliases)
    }

    private static func search(_ query: String, in apps: [AppItem], aliases: [String: [String]]) -> [AppItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return apps }
        let compactQuery = q.replacingOccurrences(of: " ", with: "")

        var scored: [(app: AppItem, score: Int)] = []
        for app in apps {
            var best = 0
            let extra = (aliases[app.id] ?? []).map { $0.lowercased() }
            // An exact alias is the user telling us what they mean: rank it first.
            if extra.contains(q) { best = 110 }
            let names = app.searchNames + extra
            let keys = extra.isEmpty ? app.pinyinKeys : app.pinyinKeys + extra.flatMap(Pinyin.keys(for:))
            for name in names {
                if name == q { best = max(best, 100) }
                else if name.hasPrefix(q) { best = max(best, 85) }
                else if hasWordPrefix(name, q) { best = max(best, 70) }
                else if name.contains(q) { best = max(best, 50) }
            }
            for key in keys {
                if key == compactQuery { best = max(best, 90) }
                else if key.hasPrefix(compactQuery) { best = max(best, 65) }
                else if compactQuery.count >= 2 && key.contains(compactQuery) { best = max(best, 30) }
            }
            if best > 0 { scored.append((app, best)) }
        }

        return scored.sorted {
            $0.score != $1.score
                ? $0.score > $1.score
                : $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending
        }.map(\.app)
    }

    private static func hasWordPrefix(_ s: String, _ q: String) -> Bool {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(q) }
    }
}
