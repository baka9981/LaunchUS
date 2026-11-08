import CryptoKit
import Foundation
import IOKit
import UserNotifications

/// LaunchUS's own server, next to the update feed (`dl.launchusapp.com/app/…`): activation
/// codes and the feedback conversation in Settings.
@MainActor
enum ServiceAPI {
    static var base: URL? {
        if let custom = ProcessInfo.processInfo.environment["LAUNCHUS_SERVICE"] { return URL(string: custom) }
        guard let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:)),
              feed.scheme == "https" else { return nil }
        return feed.deletingLastPathComponent().appendingPathComponent("app")
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Posts JSON and returns the reply; a refusal from the server carries its own message.
    static func post(_ path: String, _ body: [String: Any]) async throws -> (status: Int, json: [String: Any]) {
        guard let base else { throw Failure(message: String(localized: "这个版本没有连接服务器")) }
        var request = URLRequest(url: base.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("LaunchUS/\(version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure(message: String(localized: "连不上服务器，请检查网络后再试"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    private static let session = URLSession(configuration: .ephemeral)

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    /// This Mac, as reported when activating or sending feedback.
    static var device: [String: String] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "name": Host.current().localizedName ?? "",
            "model": sysctl("hw.model"),
            "chip": sysctl("machdep.cpu.brand_string"),
            "os": "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "version": version,
            "locale": Locale.preferredLanguages.first ?? "",
            "tz": TimeZone.current.identifier,
        ]
    }

    /// What `device` holds, one per line, for the dialog that asks before sending it.
    static var deviceSummary: String {
        let d = device
        let lines: [(String, String)] = [
            (String(localized: "Mac 名称"), d["name"] ?? ""),
            (String(localized: "型号"), d["model"] ?? ""),
            (String(localized: "芯片"), d["chip"] ?? ""),
            (String(localized: "系统"), d["os"] ?? ""),
            (String(localized: "LaunchUS 版本"), d["version"] ?? ""),
            (String(localized: "语言"), d["locale"] ?? ""),
            (String(localized: "时区"), d["tz"] ?? ""),
        ]
        return lines.filter { !$0.1.isEmpty }.map { "\($0.0)：\($0.1)" }.joined(separator: "\n")
    }

    /// The Mac's hardware UUID, hashed: the same on every install on this Mac, and says nothing else.
    static let deviceID: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? Heartbeat.installID
        let digest = SHA256.hash(data: Data(("LaunchUS|" + uuid).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }()

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    static var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }
}

// MARK: - Activation

/// 设置 › 激活: a code from the server, for one or a few Macs, kept for good. Not activating
/// changes nothing but the 未激活 label.
@MainActor @Observable
final class License {
    static let shared = License()

    private static let codeKey = "licenseCode"
    private static let receiptKey = "licenseReceipt"
    private static let checkedKey = "licenseChecked"
    /// The server's Ed25519 key that signs receipts (`admin_server.py license-key`).
    private static let publicKey = "+gD/D0LALzTxCN4k0scs6wF+KmciijGLdh4P7v4G6oY="

    private(set) var code: String?
    private(set) var busy = false

    var isActivated: Bool { code != nil }

    private init() {
        let defaults = UserDefaults.standard
        if let code = defaults.string(forKey: Self.codeKey), let receipt = defaults.string(forKey: Self.receiptKey),
           Self.verify(receipt, code: code) {
            self.code = code
        }
    }

    /// The code as people see it, the middle hidden: LUS-AB12-••••-••••-9XYZ.
    var maskedCode: String? {
        guard let code else { return nil }
        let parts = code.split(separator: "-")
        guard parts.count == 5 else { return code }
        return [parts[0], parts[1], "••••", "••••", parts[4]].joined(separator: "-")
    }

    /// Nil when it worked, else what to tell the user.
    func activate(_ typed: String) async -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return String(localized: "请输入激活码") }
        busy = true
        defer { busy = false }
        var body: [String: Any] = ServiceAPI.device
        body["code"] = trimmed
        body["device"] = ServiceAPI.deviceID
        do {
            let (status, json) = try await ServiceAPI.post("activate", body)
            guard status == 200, let code = json["code"] as? String, let receipt = json["receipt"] as? String,
                  Self.verify(receipt, code: code) else {
                return json["error"] as? String ?? String(localized: "激活失败，请稍后再试")
            }
            let defaults = UserDefaults.standard
            defaults.set(code, forKey: Self.codeKey)
            defaults.set(receipt, forKey: Self.receiptKey)
            defaults.set(Date().timeIntervalSince1970, forKey: Self.checkedKey)
            self.code = code
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Frees this Mac's seat so the code can go on another one.
    func deactivate() async -> String? {
        guard let code else { return nil }
        busy = true
        defer { busy = false }
        do {
            let (status, json) = try await ServiceAPI.post("deactivate", ["code": code, "device": ServiceAPI.deviceID])
            guard status == 200 else { return json["error"] as? String ?? String(localized: "解除失败，请稍后再试") }
        } catch {
            return error.localizedDescription
        }
        clear()
        return nil
    }

    private func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.codeKey)
        defaults.removeObject(forKey: Self.receiptKey)
        code = nil
    }

    /// Once a day: a code stopped on the server, or this Mac released there, goes back to 未激活.
    /// No network keeps it as it is.
    func checkIfDue() {
        guard let code else { return }
        let defaults = UserDefaults.standard
        guard Date().timeIntervalSince1970 - defaults.double(forKey: Self.checkedKey) > 20 * 3600 else { return }
        Task {
            var body: [String: Any] = ServiceAPI.device
            body["code"] = code
            body["device"] = ServiceAPI.deviceID
            guard let (status, json) = try? await ServiceAPI.post("check", body),
                  status == 200, let active = json["active"] as? Bool else { return }
            defaults.set(Date().timeIntervalSince1970, forKey: Self.checkedKey)
            if !active, self.code == code { clear() }
        }
    }

    /// The receipt is the server's signature over this code and this Mac.
    private static func verify(_ receipt: String, code: String) -> Bool {
        let parts = receipt.split(separator: ".")
        guard parts.count == 2, let payload = Data(base64Encoded: String(parts[0])),
              let signature = Data(base64Encoded: String(parts[1])),
              let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              key.isValidSignature(signature, for: payload),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return false }
        return json["code"] as? String == code && json["device"] as? String == ServiceAPI.deviceID
    }
}

// MARK: - Feedback

/// 设置 › 反馈: one conversation with the developer. A random key made on this Mac is all that
/// ties the messages together; replies show here and as a notification.
@MainActor @Observable
final class Feedback {
    static let shared = Feedback()

    enum Category: String, CaseIterable, Identifiable {
        case bug, update, feature, question, license, other
        var id: String { rawValue }

        var title: String {
            switch self {
            case .bug: String(localized: "修 bug")
            case .update: String(localized: "求更新")
            case .feature: String(localized: "新功能")
            case .question: String(localized: "使用问题")
            case .license: String(localized: "激活")
            case .other: String(localized: "其他")
            }
        }

        var symbol: String {
            switch self {
            case .bug: "ladybug"
            case .update: "arrow.down.circle"
            case .feature: "lightbulb"
            case .question: "questionmark.circle"
            case .license: "key"
            case .other: "ellipsis.bubble"
            }
        }
    }

    struct Message: Identifiable, Equatable {
        let id: Int
        let fromDeveloper: Bool
        let category: Category?
        let text: String
        let date: Date
    }

    private static let keyKey = "feedbackKey"
    private static let seenKey = "feedbackSeen"
    private static let startedKey = "feedbackStarted"
    private static let polledKey = "feedbackPolled"

    private(set) var messages: [Message] = []
    private(set) var loading = false
    private(set) var sending = false
    /// Replies not seen yet in Settings.
    private(set) var unread = 0
    private var timer: Timer?

    private var key: String {
        let defaults = UserDefaults.standard
        if let key = defaults.string(forKey: Self.keyKey), key.count >= 20 { return key }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = Data(bytes).base64EncodedString()
        defaults.set(key, forKey: Self.keyKey)
        return key
    }

    /// Only Macs that wrote something look for replies.
    /// The first message also asks before sending what comes with it; later ones don't.
    var started: Bool { UserDefaults.standard.bool(forKey: Self.startedKey) }

    private init() {
        unread = UserDefaults.standard.integer(forKey: "feedbackUnread")
    }

    /// Every few hours, for a reply to show as a notification and a badge.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Feedback.shared.pollIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { self.pollIfDue() }
    }

    private func pollIfDue() {
        let defaults = UserDefaults.standard
        guard started, Date().timeIntervalSince1970 - defaults.double(forKey: Self.polledKey) > 2.5 * 3600 else { return }
        Task { await refresh(notify: true) }
    }

    func refresh(notify: Bool = false) async {
        guard started else { return }
        loading = messages.isEmpty
        defer { loading = false }
        guard let (status, json) = try? await ServiceAPI.post("messages", ["key": key]), status == 200,
              let rows = json["messages"] as? [[String: Any]] else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.polledKey)
        let fresh = rows.compactMap { row -> Message? in
            guard let id = row["id"] as? Int, let text = row["text"] as? String, let at = row["at"] as? Double else { return nil }
            return Message(id: id, fromDeveloper: row["admin"] as? Bool ?? false,
                           category: (row["category"] as? String).flatMap(Category.init(rawValue:)), text: text,
                           date: Date(timeIntervalSince1970: at))
        }
        let seen = UserDefaults.standard.integer(forKey: Self.seenKey)
        let replies = fresh.filter { $0.fromDeveloper && $0.id > seen }
        if notify, replies.count > unread, let last = replies.last, ServiceAPI.canNotify {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "开发者回复了你的反馈")
            content.body = String(last.text.prefix(120))
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "feedback-\(last.id)", content: content, trigger: nil))
        }
        messages = fresh
        setUnread(replies.count)
    }

    /// Settings shows the conversation: the replies count as read.
    func markRead() {
        guard let last = messages.last(where: \.fromDeveloper) else { return }
        UserDefaults.standard.set(last.id, forKey: Self.seenKey)
        setUnread(0)
    }

    private func setUnread(_ n: Int) {
        unread = n
        UserDefaults.standard.set(n, forKey: "feedbackUnread")
    }

    /// Nil when sent, else what went wrong.
    func send(_ text: String, category: Category, contact: String) async -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return String(localized: "写点什么再发送") }
        sending = true
        defer { sending = false }
        var body: [String: Any] = ServiceAPI.device
        body["device"] = ServiceAPI.deviceID
        body["key"] = key
        body["category"] = category.rawValue
        body["text"] = text
        body["contact"] = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let (status, json) = try await ServiceAPI.post("feedback", body)
            guard status == 200, let id = json["id"] as? Int else {
                return json["error"] as? String ?? String(localized: "发送失败，请稍后再试")
            }
            UserDefaults.standard.set(true, forKey: Self.startedKey)
            let at = (json["at"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
            messages.append(Message(id: id, fromDeveloper: false, category: category, text: text, date: at))
            if ServiceAPI.canNotify {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
