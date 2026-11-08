import SwiftUI

// MARK: - 激活

/// 设置 › 激活: type a code to activate this Mac. Without one, everything keeps working.
struct LicenseTab: View {
    @State private var code = ""
    @State private var message: String?
    @State private var justActivated = false
    @AppStorage(Settings.feedbackReminderKey, store: .app) private var feedbackReminder = true

    var body: some View {
        let license = License.shared
        SettingsSection(title: String(localized: "激活")) {
            Card {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        Image(systemName: license.isActivated ? "checkmark.seal.fill" : "key.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(license.isActivated ? Color.green : .secondary)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(license.isActivated ? String(localized: "这台 Mac 已激活") : String(localized: "未激活"))
                                .font(.system(size: 14, weight: .semibold))
                            if license.isActivated {
                                Text("激活码 \(license.maskedCode ?? "")，永久有效")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if license.isActivated {
                            Button(String(localized: "解除激活…")) { confirmDeactivate() }
                                .disabled(license.busy)
                                .help(String(localized: "换电脑时先解除，激活码就能用在另一台 Mac 上"))
                        }
                    }
                    .padding(14)
                    if !license.isActivated {
                        Divider().padding(.horizontal, 14)
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
                }
            }
            if !license.isActivated {
                Text("您可通过购买激活码赞助开发者。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            if justActivated, license.isActivated {
                Text("激活成功，谢谢你的支持！")
                    .font(.system(size: 12)).foregroundStyle(.green).padding(.leading, 4)
            }
            if let message, !license.isActivated {
                Text(verbatim: message)
                    .font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
            }
        }
        // Only an activated Mac has these; before that they're not mentioned at all.
        if license.isActivated {
            SettingsSection(title: String(localized: "激活后可用")) {
                Card {
                    Row(title: String(localized: "每日反馈提醒"),
                        info: String(localized: "每天第一次打开时，在底部请你提些建议和反馈")) {
                        Toggle("", isOn: $feedbackReminder).toggleStyle(.switch).labelsHidden()
                    }
                }
            }
        }
    }

    private func activate() {
        message = nil
        let typed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        confirmAlert(String(localized: "激活这台 Mac？"),
                     String(localized: "会把下面这些发给 LaunchUS 的服务器，用来核对激活台数，服务器还会按网络地址记下大致所在地区：") + "\n\n"
                        + String(localized: "激活码：\(typed)") + "\n" + ServiceAPI.deviceSummary,
                     button: String(localized: "激活")) { activateNow() }
    }

    private func activateNow() {
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
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
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
        guard !Feedback.shared.started else { return sendNow() }
        confirmAlert(String(localized: "发送反馈？"),
                     String(localized: "为了方便排查问题，会和你写的内容、联系方式一起发送这台 Mac 的信息，服务器还会按网络地址记下大致所在地区：") + "\n\n" + ServiceAPI.deviceSummary
                        + "\n\n" + String(localized: "只在第一次发送时问。"),
                     button: String(localized: "发送")) { sendNow() }
    }

    private func sendNow() {
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
