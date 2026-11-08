import AppKit
import SwiftUI

/// 编辑智能栏: every smart folder in one place. On the left the list, in smart-bar order, with
/// whether each shows in the smart bar and on the pages; on the right the picked one's name and
/// condition, which apply as they're typed.
struct SmartBarEditor: View {
    let model: LauncherModel
    /// The folder to start on; nil with a query starts a new one from it.
    var initialFolder: String?
    var initialQuery = ""
    let close: () -> Void

    /// nil while a new folder is being written.
    @State private var selected: String?
    @State private var name = ""
    @State private var query = ""
    /// Set while a picked folder's name and condition are being loaded, so loading them isn't
    /// taken for an edit (the name would otherwise be saved with the previous one's condition).
    @State private var loading = false
    @FocusState private var focus: Int?

    var body: some View {
        let tabs = model.allCategoryTabs
        let hidden = Set(model.settings.hiddenCategoryTabs)
        // Looked up once per render rather than once per row.
        let folders = Dictionary(model.smartFolders.map { (LauncherModel.smartTabPrefix + $0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let barOnly = Set(model.barFolders.map(\.id))
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("编辑智能栏").font(.system(size: 17, weight: .semibold))
                Spacer()
                Toggle(String(localized: "显示智能栏"), isOn: Binding(get: { model.settings.showCategoryBar },
                                                                  set: { model.settings.showCategoryBar = $0 }))
                    .toggleStyle(.switch).controlSize(.small)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("智能文件夹").frame(maxWidth: .infinity, alignment: .leading)
                        Text("智能栏").frame(width: 46)
                        Text("主界面").frame(width: 46)
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    List(selection: Binding(get: { selected }, set: { if let id = $0 { pick(id) } })) {
                        ForEach(tabs, id: \.key) { tab in
                            if let folder = folders[tab.key] {
                                HStack(spacing: 0) {
                                    Text(folder.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    Toggle("", isOn: Binding(get: { !hidden.contains(tab.key) },
                                                             set: { model.setCategoryTab(tab.key, hidden: !$0) }))
                                        .toggleStyle(.checkbox).labelsHidden().frame(width: 46)
                                    Toggle("", isOn: Binding(get: { !barOnly.contains(folder.id) },
                                                             set: { model.setSmartFolder(folder.id, onPages: $0) }))
                                        .toggleStyle(.checkbox).labelsHidden().frame(width: 46)
                                }
                                .tag(folder.id)
                            }
                        }
                        .onMove { from, to in
                            var keys = tabs.map(\.key)
                            keys.move(fromOffsets: from, toOffset: to)
                            model.setCategoryTabOrder(keys)
                        }
                    }
                    .listStyle(.inset)
                    .overlay {
                        if tabs.isEmpty {
                            Text("还没有智能文件夹").font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                    }
                    Divider()
                    HStack(spacing: 6) {
                        Button { startNew("") } label: { Image(systemName: "plus").frame(width: 18, height: 16) }
                            .help(String(localized: "新建智能文件夹"))
                        Button { if let selected { delete(selected) } } label: { Image(systemName: "minus").frame(width: 18, height: 16) }
                            .help(String(localized: "删除智能文件夹"))
                            .disabled(selected == nil)
                        Spacer()
                        if !model.importableCategories.isEmpty {
                            Button(String(localized: "导入系统分类")) { model.importSystemCategories() }
                                .help(String(localized: "按 App Store 分类建好智能文件夹，只放在智能栏里"))
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .frame(width: 290)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack {
                Spacer()
                if selected == nil {
                    if !model.allCategoryTabs.isEmpty {
                        Button(String(localized: "取消")) {
                            if let first = model.allCategoryTabs.first.flatMap({ model.smartFolder(forTab: $0.key) }) { pick(first.id) }
                        }
                    }
                    Button(String(localized: "创建"), action: create)
                        .keyboardShortcut(.defaultAction)
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || !AppSearch.isComplete(AppSearch.tokens(query)))
                    Button(String(localized: "关闭"), action: close)
                } else {
                    Button(String(localized: "关闭"), action: close).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .onAppear {
            if let initialFolder, model.folder(initialFolder) != nil {
                pick(initialFolder)
            } else if initialFolder == nil, !initialQuery.isEmpty || model.allCategoryTabs.isEmpty {
                startNew(initialQuery)
            } else if let first = model.allCategoryTabs.first.flatMap({ model.smartFolder(forTab: $0.key) }) {
                pick(first.id)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView { fields.padding(20) }
                .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder private var fields: some View {
        let count = model.search(query).count
        let importable = selected == nil ? model.importableCategories : []
        VStack(alignment: .leading, spacing: 14) {
            Text(selected == nil ? String(localized: "新建智能文件夹") : String(localized: "内容由条件决定，符合条件的 App 会自动出现在里面"))
                .font(.system(size: selected == nil ? 15 : 12, weight: selected == nil ? .semibold : .regular))
                .foregroundStyle(selected == nil ? .primary : .secondary)
            if !importable.isEmpty, model.allCategoryTabs.isEmpty {
                // The first smart folders can simply be the system's categories.
                HStack(spacing: 10) {
                    Text("按 App Store 分类建好 \(importable.count) 个智能文件夹，放在智能栏里，新装的 App 会自动归进去")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(String(localized: "导入系统分类")) {
                        model.importSystemCategories()
                        if let first = model.allCategoryTabs.first.flatMap({ model.smartFolder(forTab: $0.key) }) { pick(first.id) }
                    }
                }
                .padding(10)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            FieldRow(label: String(localized: "文件夹名称")) {
                TextField(LauncherModel.smartFolderName(for: query), text: $name)
                    .textFieldStyle(CardFieldStyle()).focused($focus, equals: 0)
                    .onChange(of: name) { apply() }
            }
            FieldRow(label: String(localized: "规则")) {
                FormulaBuilder(query: $query, tags: model.allTags)
                let complete = AppSearch.isComplete(AppSearch.tokens(query))
                Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? " "
                     : complete ? String(localized: "符合条件的 App：\(count) 个") : String(localized: "规则还没写完：括号要配对，符号两边都要有内容"))
                    .font(.system(size: 11)).foregroundStyle(complete ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
        }
    }

    private func pick(_ id: String) {
        guard let folder = model.folder(id) else { return }
        loading = true
        selected = id
        name = folder.name
        query = folder.query ?? ""
        DispatchQueue.main.async { loading = false }
    }

    private func startNew(_ initial: String) {
        selected = nil
        name = ""
        query = initial
        DispatchQueue.main.async { focus = initial.isEmpty ? 1 : 0 }
    }

    /// Edits apply as they're typed; an empty condition waits until there's one.
    private func apply() {
        guard !loading, let selected, let folder = model.folder(selected) else { return }
        let q = query.trimmingCharacters(in: .whitespaces)
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, AppSearch.isComplete(AppSearch.tokens(q)),
              q != folder.query || (!n.isEmpty && n != folder.name) else { return }
        model.saveSmartFolder(selected, name: n, query: q, onPages: model.isOnPages(selected))
    }

    private func create() {
        // In the smart bar and on the pages; the list's checkboxes change either.
        guard let id = model.saveSmartFolder(nil, name: name, query: query, onPages: true) else { return }
        pick(id)
    }

    private func delete(_ id: String) {
        let order = model.allCategoryTabs.compactMap { model.smartFolder(forTab: $0.key)?.id }
        let next = order.firstIndex(of: id).flatMap { i in order.indices.contains(i + 1) ? order[i + 1] : (i > 0 ? order[i - 1] : nil) }
        model.dissolveFolder(id)
        if let next { pick(next) } else { startNew("") }
    }
}

/// A smart folder's rule, built by clicking: tags, categories, keywords and the set symbols
/// go into the formula as bubbles; clicking a bubble in the formula takes it out again.
struct FormulaBuilder: View {
    @Binding var query: String
    let tags: [String]
    @State private var keyword = ""

    /// The formula with the ∩ that two terms side by side mean anyway written out.
    private var tokens: [AppSearch.Token] {
        var out: [AppSearch.Token] = []
        for token in AppSearch.tokens(query) {
            if let last = out.last, Self.endsOperand(last), Self.startsOperand(token) { out.append(.and) }
            out.append(token)
        }
        return out
    }

    private static func endsOperand(_ t: AppSearch.Token) -> Bool { t.isTerm || t == .close }
    private static func startsOperand(_ t: AppSearch.Token) -> Bool { t.isTerm || t == .open || t == .not }

    var body: some View {
        let toks = tokens
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                FlowLayout(spacing: 5) {
                    if toks.isEmpty {
                        Text("点下面的标签、分类和符号，组成规则")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .frame(height: 24)
                    }
                    ForEach(Array(toks.enumerated()), id: \.offset) { i, token in
                        FormulaBubble(token: token) { remove(at: i, in: toks) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !toks.isEmpty {
                    Button { remove(at: toks.count - 1, in: toks) } label: { Image(systemName: "delete.left") }
                        .help(String(localized: "删掉最后一个"))
                    Button { set([]) } label: { Image(systemName: "xmark.circle.fill") }
                        .help(String(localized: "清空"))
                }
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .padding(8)
            .frame(minHeight: 40, alignment: .topLeading)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 6) {
                OperatorButton(symbol: "∩", title: String(localized: "交集（且）")) { add(.and) }
                OperatorButton(symbol: "∪", title: String(localized: "并集（或）")) { add(.or) }
                OperatorButton(symbol: "¬", title: String(localized: "补集（非）")) { add(.not) }
                OperatorButton(symbol: "(", title: nil) { add(.open) }
                OperatorButton(symbol: ")", title: nil) { add(.close) }
            }
            if !tags.isEmpty {
                section(String(localized: "标签"), items: tags.map { "#" + $0 })
            }
            section(String(localized: "App Store 分类"), items: AppCategoryName.Group.allCases.map(AppSearch.categoryToken))
            VStack(alignment: .leading, spacing: 5) {
                Text("名称").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField(String(localized: "名称里的关键词"), text: $keyword)
                        .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 150)
                        .onSubmit(addKeyword)
                    Button(String(localized: "加入"), action: addKeyword)
                        .controlSize(.small)
                        .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func section(_ title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            FlowLayout(spacing: 5) {
                ForEach(items, id: \.self) { item in
                    FormulaBubble(token: .term(item)) { add(.term(item)) }
                }
            }
        }
    }

    private func set(_ toks: [AppSearch.Token]) { query = AppSearch.formulaText(toks) }

    /// Adds at the end; a term, "(" or "¬" right after an operand gets the ∩ it means.
    private func add(_ token: AppSearch.Token) {
        var toks = tokens
        if let last = toks.last, Self.endsOperand(last), Self.startsOperand(token) { toks.append(.and) }
        toks.append(token)
        set(toks)
    }

    private func remove(at index: Int, in toks: [AppSearch.Token]) { set(Self.removing(index, from: toks)) }

    /// The formula without the bubble at `index`, and without what only made sense next to it:
    /// a bracket's partner, the ¬ in front of a term, and one ∩/∪ joining it (the one before
    /// it, so "a ∩ b ∪ c" without b is "a ∪ c").
    static func removing(_ index: Int, from tokens: [AppSearch.Token]) -> [AppSearch.Token] {
        var toks = tokens
        let removed = toks.remove(at: index)
        var i = index
        if removed == .open || removed == .close {
            // Its partner: the bracket that closes (or opens) the same level.
            var depth = 0
            let range: [Int] = removed == .open ? Array(i..<toks.count) : Array((0..<i).reversed())
            for j in range {
                if toks[j] == removed { depth += 1 }
                else if toks[j] == (removed == .open ? .close : .open) {
                    if depth == 0 {
                        toks.remove(at: j)
                        if j < i { i -= 1 }
                        break
                    }
                    depth -= 1
                }
            }
            return toks
        }
        func startsHere() -> Bool { toks.indices.contains(i) && startsOperand(toks[i]) }
        while i > 0, toks[i - 1] == .not, !startsHere() { toks.remove(at: i - 1); i -= 1 }
        let binary: Set<AppSearch.Token> = [.and, .or]
        if i > 0, binary.contains(toks[i - 1]), !startsHere() {
            toks.remove(at: i - 1)
        } else if toks.indices.contains(i), binary.contains(toks[i]), i == 0 || !endsOperand(toks[i - 1]) {
            toks.remove(at: i)
        }
        return toks
    }

    private func addKeyword() {
        let words = keyword.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return }
        for word in words { add(.term(word)) }
        keyword = ""
    }
}

/// One bubble: a term in the accent colour, an operator as a small grey symbol.
private struct FormulaBubble: View {
    let token: AppSearch.Token
    let tap: () -> Void

    var body: some View {
        let isTerm = token.isTerm
        Text(token.text)
            .font(.system(size: isTerm ? 12 : 14, weight: isTerm ? .regular : .semibold))
            .foregroundStyle(isTerm ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            .padding(.horizontal, isTerm ? 9 : 7)
            .frame(minWidth: 24, minHeight: 24)
            .background(isTerm ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.09), in: Capsule())
            .contentShape(Capsule())
            .onTapGesture(perform: tap)
    }
}

private struct OperatorButton: View {
    let symbol: String
    let title: String?
    let tap: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(symbol).font(.system(size: 15, weight: .semibold))
            if let title { Text(title).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: tap)
        .help(title ?? symbol)
    }
}
