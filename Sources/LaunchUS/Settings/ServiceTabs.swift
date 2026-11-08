import SwiftUI

/// 已激活 / 未激活, as a small pill.
struct LicenseBadge: View {
    var body: some View {
        let on = License.shared.isActivated
        Label(on ? String(localized: "已激活") : String(localized: "未激活"),
              systemImage: on ? "checkmark.seal.fill" : "seal")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(on ? Color.green : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((on ? Color.green : Color.primary).opacity(on ? 0.14 : 0.07), in: Capsule())
    }
}

// MARK: - 激活

/// 设置 › 激活: type a code to activate this Mac. Without one, everything keeps working.
struct LicenseTab: View {
    @State private var code = ""
    @State private var message: String?
    @State private var justActivated = false

    var body: some View {
        let license = License.shared
        SettingsSection(title: String(localized: "激活")) {
            Card {
                HStack(spacing: 14) {
                    Image(systemName: license.isActivated ? "checkmark.seal.fill" : "key.horizontal")
                        .font(.system(size: 28))
                        .foregroundStyle(license.isActivated ? Color.green : .secondary)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(license.isActivated ? String(localized: "这台 Mac 已激活") : String(localized: "未激活"))
                            .font(.system(size: 15, weight: .semibold))
                        Text(license.isActivated
                             ? String(localized: "激活码 \(license.maskedCode ?? "")，永久有效")
                             : String(localized: "未激活也可以继续使用。有激活码的话，在下面输入。"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            }

            if license.isActivated {
                if justActivated {
                    Text("激活成功，谢谢你的支持！")
                        .font(.system(size: 12)).foregroundStyle(.green).padding(.leading, 4)
                }
                Card {
                    Row(title: String(localized: "解除这台 Mac 的激活"),
                        subtitle: String(localized: "换电脑时先解除，激活码就能用在另一台 Mac 上")) {
                        Button(String(localized: "解除激活…")) { confirmDeactivate() }
                            .disabled(license.busy)
                    }
                }
            } else {
                Card {
                    HStack(spacing: 10) {
                        TextField(String(localized: "LUS-XXXX-XXXX-XXXX-XXXX"), text: $code)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                            .onSubmit(activate)
                        if license.busy {
                            ProgressView().controlSize(.small)
                        }
                        Button(String(localized: "激活"), action: activate)
                            .keyboardShortcut(.defaultAction)
                            .disabled(license.busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(14)
                }
                if let message {
                    Text(verbatim: message)
                        .font(.system(size: 12)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 4)
                }
            }

            Text("激活时会把激活码和这台 Mac 的名称、型号、芯片、系统版本、语言和时区发给 LaunchUS 的服务器，用来核对激活台数；不会发送其他信息。")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
        }
    }

    private func activate() {
        message = nil
        Task {
            if let error = await License.shared.activate(code) {
                message = error
            } else {
                code = ""
                justActivated = true
            }
        }
    }

    private func confirmDeactivate() {
        confirmAlert(String(localized: "解除这台 Mac 的激活？"),
                     String(localized: "解除后这台 Mac 显示未激活，激活码可以用在另一台 Mac 上。"),
                     button: String(localized: "解除激活")) {
            Task {
                justActivated = false
                if let error = await License.shared.deactivate() {
                    confirmAlert(String(localized: "没能解除激活"), error, button: String(localized: "好")) {}
                }
            }
        }
    }
}

// MARK: - 反馈

/// 设置 › 反馈: write to the developer and read the replies, as a conversation.
struct FeedbackTab: View {
    @AppStorage("feedbackContact") private var contact = ""
    @State private var category: Feedback.Category = .bug
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        let feedback = Feedback.shared
        SettingsSection(title: String(localized: "反馈")) {
            Text("遇到问题、想要新功能，或者催更新，都可以写在这里。开发者会在这里回复，回复时会发通知给你。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)

            if !feedback.messages.isEmpty {
                Card {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 10) {
                                ForEach(feedback.messages) { message in
                                    Bubble(message: message).id(message.id)
                                }
                            }
                            .padding(14)
                        }
                        .frame(height: 260)
                        .onAppear { proxy.scrollTo(feedback.messages.last?.id, anchor: .bottom) }
                        .onChange(of: feedback.messages.count) { _, _ in
                            withAnimation { proxy.scrollTo(feedback.messages.last?.id, anchor: .bottom) }
                        }
                    }
                }
            } else if feedback.loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("分类").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(Feedback.Category.allCases) { item in
                            CategoryChip(category: item, selected: item == category) { category = item }
                        }
                    }
                    TextEditor(text: $text)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 110)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text(placeholder)
                                    .font(.system(size: 13)).foregroundStyle(.tertiary)
                                    .padding(.horizontal, 11).padding(.vertical, 6)
                                    .allowsHitTesting(false)
                            }
                        }
                    HStack(spacing: 10) {
                        TextField(String(localized: "联系方式（选填：邮箱、微信……）"), text: $contact)
                            .textFieldStyle(.roundedBorder)
                        if feedback.sending { ProgressView().controlSize(.small) }
                        Button(String(localized: "发送"), action: send)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(feedback.sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let error {
                        Text(verbatim: error).font(.system(size: 12)).foregroundStyle(.red)
                    }
                }
                .padding(14)
            }

            Text("发送时会附上 LaunchUS 版本、系统版本、芯片和语言，方便排查问题。")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
        .task {
            // While the page is open, replies show up within half a minute.
            while !Task.isCancelled {
                await feedback.refresh()
                feedback.markRead()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var placeholder: String {
        switch category {
        case .bug: String(localized: "哪里出了问题？怎么操作会出现？")
        case .update: String(localized: "希望下个版本加上或改进什么？")
        case .feature: String(localized: "想要什么新功能？")
        case .question: String(localized: "有什么不会用的？")
        case .license: String(localized: "激活遇到了什么问题？")
        case .other: String(localized: "想说的话")
        }
    }

    private func send() {
        error = nil
        Task {
            if let failure = await Feedback.shared.send(text, category: category, contact: contact) {
                error = failure
            } else {
                text = ""
            }
        }
    }
}

private struct CategoryChip: View {
    let category: Feedback.Category
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(category.title, systemImage: category.symbol)
                .font(.system(size: 12))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 9).padding(.vertical, 5)
                .foregroundStyle(selected ? Color.white : .primary)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct Bubble: View {
    let message: Feedback.Message

    var body: some View {
        let mine = !message.fromDeveloper
        HStack {
            if mine { Spacer(minLength: 60) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                Text(verbatim: header)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(verbatim: message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .foregroundStyle(mine ? Color.white : .primary)
                    .background(mine ? Color.accentColor : Color.primary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if !mine { Spacer(minLength: 60) }
        }
    }

    private var header: String {
        var parts: [String] = []
        if message.fromDeveloper { parts.append(String(localized: "开发者")) }
        if let category = message.category, !message.fromDeveloper { parts.append(category.title) }
        parts.append(message.date.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }
}
