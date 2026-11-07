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
        for token in query.split(whereSeparator: \.isWhitespace) where !isOperator(token) {
            if let first = token.first, first == "#" || first == "＃" {
                let tag = token.dropFirst().lowercased()
                if !tag.isEmpty { tags.append(tag) }
            } else {
                words.append(String(token))
            }
        }
        return (tags, words.joined(separator: " "))
    }

    private static func isOperator(_ token: Substring) -> Bool {
        let t = String(token)
        return orWords.contains(t) || andWords.contains(t) || notWords.contains(t) || t == "(" || t == ")"
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

    /// Splits "@开发者工具 #常用" into the App Store category groups its "@…" tokens name (by
    /// title or raw value) and the rest of the query. An "@…" naming no group matches nothing.
    static func categories(in query: String) -> (groups: [AppCategoryName.Group?], rest: String) {
        var groups: [AppCategoryName.Group?] = []
        var rest: [Substring] = []
        for token in query.split(whereSeparator: \.isWhitespace) {
            if let first = token.first, first == "@" || first == "＠", token.count > 1 {
                let name = token.dropFirst().lowercased()
                groups.append(AppCategoryName.Group.allCases.first {
                    categoryToken($0).dropFirst().lowercased() == name || $0.rawValue.lowercased() == name
                })
            } else {
                rest.append(token)
            }
        }
        return (groups, rest.joined(separator: " "))
    }

    /// The "@…" token for a category group, as smart folders store it.
    static func categoryToken(_ group: AppCategoryName.Group) -> String {
        "@" + group.title.replacingOccurrences(of: " ", with: "")
    }

    // MARK: - Formulas

    /// A piece of a smart folder's formula: a "#tag", "@category" or keyword, or an operator.
    enum Token: Hashable {
        case term(String)
        case and, or, not, open, close

        /// How the token is stored and shown: the set symbols, so a formula reads the same in
        /// every language.
        var text: String {
            switch self {
            case .term(let t): t
            case .and: "∩"
            case .or: "∪"
            case .not: "¬"
            case .open: "("
            case .close: ")"
            }
        }

        var isTerm: Bool { if case .term = self { true } else { false } }
    }

    private static let orWords: Set<String> = ["∪", "|", "｜", "或", "OR"]
    private static let andWords: Set<String> = ["∩", "&", "＆", "且", "AND"]
    private static let notWords: Set<String> = ["¬", "非", "NOT"]

    /// Reads "( #工具 ∪ #效率 ) ∩ ¬ @游戏" into tokens. Words ("或", "且", "非", "OR"…), brackets
    /// glued to a term and "-#tag" are understood too; plain "#a #b" stays two terms.
    /// "¬" glued to a plain keyword ("¬ps") is a negation too, since nobody searches for that.
    static func tokens(_ query: String) -> [Token] {
        var out: [Token] = []
        for raw in query.split(whereSeparator: \.isWhitespace).map(String.init) {
            if orWords.contains(raw) { out.append(.or); continue }
            if andWords.contains(raw) { out.append(.and); continue }
            if notWords.contains(raw) { out.append(.not); continue }
            var word = Substring(raw)
            var closes = 0
            while let first = word.first {
                if first == "(" || first == "（" { out.append(.open) }
                // Glued only to a "#…" or "@…" term, so a typed "-ps" or "非常" stays a search.
                else if first == "¬", word.count > 1 { out.append(.not) }
                else if "-!！非".contains(first), let next = word.dropFirst().first, "#＃@＠(（".contains(next) { out.append(.not) }
                else { break }
                word = word.dropFirst()
            }
            while let last = word.last, last == ")" || last == "）" { closes += 1; word = word.dropLast() }
            if !word.isEmpty { out.append(.term(String(word))) }
            out += Array(repeating: .close, count: closes)
        }
        return out
    }

    static func formulaText(_ tokens: [Token]) -> String { tokens.map(\.text).joined(separator: " ") }

    /// Whether the brackets pair up and every operator has something on each side.
    static func isComplete(_ tokens: [Token]) -> Bool {
        var depth = 0
        var wantsOperand = true
        for token in tokens {
            switch token {
            case .term: wantsOperand = false
            case .open: depth += 1; wantsOperand = true
            case .close:
                if wantsOperand || depth == 0 { return false }
                depth -= 1
            case .not: wantsOperand = true
            case .and, .or:
                if wantsOperand { return false }
                wantsOperand = true
            }
        }
        return depth == 0 && !wantsOperand
    }

    private indirect enum Expr {
        case term(String), not(Expr), and(Expr, Expr), or(Expr, Expr)
    }

    /// ¬ binds tightest, then ∩ (also between two terms side by side), then ∪. A missing ")"
    /// closes at the end and stray operators are skipped, so a half-built formula still works.
    private static func parse(tokens: [Token]) -> Expr? {
        var i = 0
        func unary() -> Expr? {
            while i < tokens.count {
                switch tokens[i] {
                case .not:
                    i += 1
                    return unary().map(Expr.not)
                case .term(let t):
                    i += 1
                    return .term(t)
                case .open:
                    i += 1
                    let inner = or()
                    if i < tokens.count, tokens[i] == .close { i += 1 }
                    return inner
                case .and, .or, .close:
                    return nil
                }
            }
            return nil
        }
        func and() -> Expr? {
            var left = unary()
            while i < tokens.count {
                if tokens[i] == .and { i += 1 }
                else if tokens[i] == .or || tokens[i] == .close { break }
                guard let right = unary() else { continue }
                left = left.map { .and($0, right) } ?? right
            }
            return left
        }
        func or() -> Expr? {
            var left = and()
            while i < tokens.count, tokens[i] == .or {
                i += 1
                if let right = and() { left = left.map { .or($0, right) } ?? right }
            }
            return left
        }
        var result: Expr?
        while i < tokens.count {
            if let e = or() { result = result.map { .and($0, e) } ?? e }
            if i < tokens.count { i += 1 }   // a stray ")" or operator
        }
        return result
    }

    /// Searches names, aliases and pinyin; "#tag" tokens filter by tag (several = all of them),
    /// "@category" by App Store category (the user's own choice when `group` says so). With
    /// ∩ ∪ ¬ and brackets the query is a formula over those.
    static func search(_ query: String, in apps: [AppItem], aliases: [String: [String]] = [:],
                       tags: [String: [String]] = [:],
                       group: (AppItem) -> AppCategoryName.Group = { AppCategoryName.group(for: $0.category) }) -> [AppItem] {
        let toks = tokens(query)
        if toks.allSatisfy(\.isTerm) {
            // A typed search keeps its ranking and its spaces.
            return searchRow(query, in: apps, aliases: aliases, tags: tags, group: group)
        }
        guard let expr = parse(tokens: toks) else { return [] }
        func eval(_ e: Expr) -> Set<String> {
            switch e {
            case .term(let t): Set(searchRow(t, in: apps, aliases: aliases, tags: tags, group: group).map(\.id))
            case .not(let x): Set(apps.map(\.id)).subtracting(eval(x))
            case .and(let l, let r): eval(l).intersection(eval(r))
            case .or(let l, let r): eval(l).union(eval(r))
            }
        }
        let ids = eval(expr)
        return apps.filter { ids.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func searchRow(_ query: String, in apps: [AppItem], aliases: [String: [String]],
                                  tags: [String: [String]], group: (AppItem) -> AppCategoryName.Group) -> [AppItem] {
        let (groups, query) = categories(in: query)
        let (tagTokens, text) = parse(query)
        var pool = apps
        if !groups.isEmpty {
            pool = pool.filter { app in groups.allSatisfy { $0 == group(app) } }
            if tagTokens.isEmpty && text.isEmpty {
                return pool.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
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
