import SwiftUI

// MARK: - 激活

/// 设置 › 激活: type a code to activate this Mac. Without one, everything keeps working.
struct LicenseTab: View {
    enum Mode: Hashable { case code, email }
    /// Where the code flow is: the code alone, then the email it gets bound to (or, for a
    /// code bound already, the email that moves it here; `hint` shows which).
    enum Step: Equatable { case code, email(hint: String?) }

    @State private var mode: Mode = .code
    @State private var step: Step = .code
    @State private var code = ""
    @AppStorage("licenseEmailTyped") private var email = ""
    @State private var otp = ""
    /// The address the last verification code went to, and when.
    @State private var sentTo: String?
    @State private var sentAt: Date?
    @State private var binding = false
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
                        } else {
                            Picker("", selection: $mode) {
                                Text("激活码").tag(Mode.code)
                                Text("邮箱登录").tag(Mode.email)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                            .onChange(of: mode) { _, _ in reset() }
                        }
                    }
                    .padding(14)
                    if license.isActivated {
                        Divider().padding(.horizontal, 14)
                        boundRow(license)
                        if binding, license.email == nil {
                            Divider().padding(.horizontal, 14)
                            emailForm(button: String(localized: "绑定"), purpose: .bind, submit: bindNow)
                        }
                        Divider().padding(.horizontal, 14)
                        // Only an activated Mac can turn it off; before that it's not mentioned at all.
                        perkRow(icon: "bell", title: String(localized: "每日反馈提醒"),
                                detail: String(localized: "每天第一次打开时，在底部请你提些建议和反馈")) {
                            Toggle("", isOn: $feedbackReminder).toggleStyle(.switch).labelsHidden()
                        }
                    } else if mode == .email {
                        Divider().padding(.horizontal, 14)
                        emailForm(button: String(localized: "登录"), purpose: .login, submit: loginNow)
                    } else {
                        Divider().padding(.horizontal, 14)
                        HStack(spacing: 10) {
                            TextField(String(localized: "LUS-XXXX-XXXX-XXXX-XXXX"), text: $code)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, design: .monospaced))
                                .disabled(step != .code)
                                .onSubmit(activate)
                            if step != .code {
                                Button(String(localized: "换一个")) { reset() }
                            } else {
                                if license.busy { ProgressView().controlSize(.small) }
                                Button(String(localized: "激活"), action: activate)
                                    .keyboardShortcut(.defaultAction)
                                    .disabled(license.busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                        .padding(14)
                        if case .email(let hint) = step {
                            Divider().padding(.horizontal, 14)
                            Text(hint.map { String(localized: "这个激活码绑定了 \($0)。填写这个邮箱，收到验证码后就能在这台 Mac 上激活") }
                                 ?? String(localized: "激活码需要绑定一个邮箱：以后换 Mac 或重装系统，用邮箱就能找回。验证码会发到这个邮箱"))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding([.horizontal, .top], 14)
                            emailForm(button: String(localized: "激活"), purpose: .activate, submit: activateWithEmail)
                        }
                    }
                }
            }
            if !license.isActivated {
                Text(mode == .email ? String(localized: "已经绑定过邮箱的激活码，在新的 Mac 上用邮箱登录即可；激活台数满了会自动退出最久没用的那台。")
                                    : String(localized: "您可通过购买激活码赞助开发者。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
            }
            if justActivated, license.isActivated {
                Text("激活成功，谢谢你的支持！")
                    .font(.system(size: 12)).foregroundStyle(.green).padding(.leading, 4)
            }
            if let message {
                Text(verbatim: message)
                    .font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
            }
        }
        .onAppear { license.checkIfDue(force: true) }
        SettingsSection(title: String(localized: "支持 LaunchUS")) {
            Card {
                perkRow(icon: "megaphone", title: String(localized: "博主计划"),
                        detail: String(localized: "在任何平台发帖介绍 LaunchUS，上传截图，审核通过后自动发码，没有粉丝数要求")) {
                    Button(String(localized: "参加…")) {
                        NSWorkspace.shared.open(URL(string: "https://launchusapp.com/creators/")!)
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    rowIcon("heart")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("捐赠").font(.system(size: 13))
                        Text("捐赠时请备注邮箱，或通过反馈联系。在 2.0 版本之前，无论金额大小，您将获得一个激活码。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 12) {
                        DonateCode(file: "wechat", title: String(localized: "微信"))
                        DonateCode(file: "alipay", title: String(localized: "支付宝"))
                    }
                }
                .padding(14)
            }
        }
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 34)
    }

    /// An icon, a title with a line under it, and a control on the right.
    private func perkRow(icon: String, title: String, detail: String,
                         @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 10) {
            rowIcon(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(14)
    }

    /// The bound email with 解绑, or a nudge to bind one.
    @ViewBuilder private func boundRow(_ license: License) -> some View {
        HStack(spacing: 10) {
            Image(systemName: license.email == nil ? "envelope.badge" : "envelope")
                .font(.system(size: 15))
                .foregroundStyle(license.needsEmail ? Color.orange : .secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                if let bound = license.email {
                    Text("已绑定邮箱 \(bound)").font(.system(size: 13))
                    Text("换 Mac 时在新 Mac 上用这个邮箱登录").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("还没有绑定邮箱").font(.system(size: 13))
                        .foregroundStyle(license.needsEmail ? Color.orange : .primary)
                    Text("不绑定的话，这个激活码只能用在这台 Mac 上，换 Mac 也没法找回")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if license.email != nil {
                Button(String(localized: "解绑…")) { confirmUnbind() }.disabled(license.busy)
            } else if !binding {
                Button(String(localized: "绑定邮箱…")) { reset(); binding = true }.disabled(license.busy)
            }
        }
        .padding(14)
    }

    /// Email, then the six-digit code mailed to it, then `button`.
    private func emailForm(button: String, purpose: License.Purpose, submit: @escaping () -> Void) -> some View {
        let license = License.shared
        let typed = email.trimmingCharacters(in: .whitespaces)
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                TextField(String(localized: "邮箱"), text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .onSubmit { send(purpose) }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let wait = sentAt.map { 60 - Int(context.date.timeIntervalSince($0)) } ?? 0
                    Button(wait > 0 && sentTo == typed ? String(localized: "重新发送（\(wait)）")
                           : sentTo == nil ? String(localized: "发送验证码") : String(localized: "重新发送")) { send(purpose) }
                        .disabled(license.busy || !typed.contains("@") || (wait > 0 && sentTo == typed))
                }
            }
            if sentTo != nil {
                HStack(spacing: 10) {
                    TextField(String(localized: "6 位验证码"), text: $otp)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .onSubmit(submit)
                    if license.busy { ProgressView().controlSize(.small) }
                    Button(button, action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(license.busy || otp.filter(\.isNumber).count != 6)
                }
                Text("验证码已发到 \(sentTo ?? "")，10 分钟内有效。没收到的话看看垃圾邮件")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
    }

    private func reset() {
        step = .code
        otp = ""
        sentTo = nil
        sentAt = nil
        binding = false
        message = nil
    }

    private func send(_ purpose: License.Purpose) {
        let typed = email.trimmingCharacters(in: .whitespaces)
        guard typed.contains("@") else { return }
        message = nil
        Task {
            if let error = await License.shared.sendCode(to: typed, for: purpose, code: purpose == .activate ? code : nil) {
                message = error
            } else {
                sentTo = typed
                sentAt = Date()
                otp = ""
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
                     button: String(localized: "激活")) { run { await License.shared.activate(code) } }
    }

    private func activateWithEmail() {
        let typed = sentTo ?? email
        run { await License.shared.activate(code, email: typed, otp: otp) }
    }

    private func loginNow() {
        let typed = sentTo ?? email
        confirmAlert(String(localized: "用邮箱激活这台 Mac？"),
                     String(localized: "会把下面这些发给 LaunchUS 的服务器，用来核对激活台数，服务器还会按网络地址记下大致所在地区：") + "\n\n"
                        + ServiceAPI.deviceSummary,
                     button: String(localized: "激活")) { run { await License.shared.login(email: typed, otp: otp) } }
    }

    private func run(_ work: @escaping () async -> License.Outcome) {
        message = nil
        Task {
            switch await work() {
            case .activated:
                code = ""
                reset()
                justActivated = true
            case .needsEmail:
                step = .email(hint: nil)
            case .needsOTP(let hint):
                step = .email(hint: hint)
            case .failed(let error):
                message = error
            }
        }
    }

    private func bindNow() {
        let typed = sentTo ?? email
        Task {
            if let error = await License.shared.bind(email: typed, otp: otp) {
                message = error
            } else {
                reset()
            }
        }
    }

    private func confirmUnbind() {
        confirmAlert(String(localized: "解绑邮箱？"),
                     String(localized: "解绑后这台 Mac 仍然是激活的，也可以再绑定邮箱；但这个激活码不能再用到别的 Mac 上，直到重新绑定。"),
                     button: String(localized: "解绑")) {
            Task {
                if let error = await License.shared.unbind() {
                    confirmAlert(String(localized: "没能解绑"), error, button: String(localized: "好")) {}
                }
            }
        }
    }

    private func confirmDeactivate() {
        confirmAlert(String(localized: "解除这台 Mac 的激活？"),
                     License.shared.email == nil && License.shared.needsEmail
                        ? String(localized: "这个激活码没有绑定邮箱，解除后只能在这台 Mac 上重新激活。想换到别的 Mac，请先绑定邮箱。")
                        : String(localized: "解除后这台 Mac 显示未激活，激活码可以用在另一台 Mac 上。"),
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

/// One payment QR code, bundled in Resources/Donate.
private struct DonateCode: View {
    let file: String
    let title: String

    var body: some View {
        VStack(spacing: 6) {
            if let url = Bundle.main.url(forResource: file, withExtension: "png", subdirectory: "Donate"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            }
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
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
                    // Opens at the latest message and follows new ones. Not scrollTo: that also
                    // scrolled the settings page around it, so the page jumped as the tab opened.
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(feedback.messages) { message in
                                Bubble(message: message)
                            }
                        }
                        .padding(14)
                    }
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    .frame(height: 260)
                }
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
