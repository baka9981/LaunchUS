import Foundation

/// What went wrong talking to the gateway, said plainly in the app's language. Gateways answer
/// in English with their own wording; `detail` keeps that raw text for the curious and for support.
struct AIFailure: LocalizedError, Equatable {
    enum Kind: Equatable {
        case missingKey, badKey, forbidden, notFound, quota, rateLimited, tooLong, badRequest
        case timeout, unavailable, offline, unreachable, insecure, other
        /// Already in plain words (LaunchUS's own message): `detail` is the whole of it.
        case plain
    }

    var kind: Kind
    /// The gateway's own words, e.g. "HTTP 401 · Incorrect API key provided".
    var detail: String
    /// The model asked for, named in the not-found message.
    var model: String = ""
    /// The gateway's host, named when it can't be reached.
    var host: String = ""

    var title: String {
        switch kind {
        case .missingKey: String(localized: "还没有填 API 密钥")
        case .badKey: String(localized: "API 密钥无效")
        case .forbidden: String(localized: "这个密钥没有权限")
        case .notFound: model.isEmpty ? String(localized: "找不到这个模型") : String(localized: "找不到模型「\(model)」")
        case .quota: String(localized: "额度用完了")
        case .rateLimited: String(localized: "请求太频繁")
        case .tooLong: String(localized: "对话太长了")
        case .badRequest: String(localized: "网关不接受这次请求")
        case .timeout: String(localized: "网关没有回应")
        case .unavailable: String(localized: "模型服务暂时不可用")
        case .offline: String(localized: "网络断开了")
        case .unreachable: String(localized: "连不上网关")
        case .insecure: String(localized: "安全连接失败")
        case .other: String(localized: "出错了")
        case .plain: detail
        }
    }

    var hint: String {
        switch kind {
        case .missingKey: String(localized: "这个网关需要密钥，到 设置 › AI 里填写。")
        case .badKey: String(localized: "密钥可能填错、过期或已被删除，到 设置 › AI 里检查。")
        case .forbidden: String(localized: "账户可能没有开通这个模型，或地区不受支持。")
        case .notFound: String(localized: "检查 设置 › AI 里的模型名称和地址，可以点「获取」列出可用的模型。")
        case .quota: String(localized: "账户余额或免费额度不足，充值或换一个密钥后再试。")
        case .rateLimited: String(localized: "被网关限流了，等一会儿再试。")
        case .tooLong: String(localized: "超出了模型能处理的长度，开一个新对话再问。")
        case .badRequest: String(localized: "模型可能不支持某个功能（如工具调用），可以换个模型，或在设置里关掉「让 AI 操作 LaunchUS」。")
        case .timeout: String(localized: "等了很久没有回答，稍后重试。")
        case .unavailable: String(localized: "服务繁忙或在维护，稍后重试。")
        case .offline: String(localized: "检查网络连接后重试。")
        case .unreachable: host.isEmpty
            ? String(localized: "检查地址是否正确、服务是否在运行。")
            : String(localized: "检查地址「\(host)」是否正确、服务是否在运行。")
        case .insecure: String(localized: "网关的证书有问题，或网络拦截了连接。")
        case .other: String(localized: "下面是网关返回的原文。")
        case .plain: ""
        }
    }

    /// Wrong settings: the error offers to open them.
    var opensSettings: Bool { [.missingKey, .badKey, .notFound, .badRequest, .unreachable].contains(kind) }

    /// The raw text is worth showing: not for LaunchUS's own messages.
    var hasDetail: Bool { kind != .plain && !detail.isEmpty }

    var errorDescription: String? { hint.isEmpty ? title : title + String(localized: "：") + hint }

    /// An error answer from the gateway, sorted by status code and the code words gateways use.
    static func gateway(status: Int?, json: [String: Any]?, body: String = "", keyMissing: Bool = false, model: String = "") -> AIFailure {
        let error = json?["error"]
        let object = error as? [String: Any] ?? [:]
        let message = object["message"] as? String ?? error as? String ?? body.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = [object["code"], object["type"], json?["type"], message]
            .compactMap { $0.map { "\($0)" } }.joined(separator: " ").lowercased()
        func has(_ any: String...) -> Bool { any.contains { words.contains($0) } }

        let kind: Kind
        if status == 401 || has("invalid_api_key", "authentication_error", "incorrect api key", "invalid api key", "unauthorized") {
            kind = keyMissing || has("didn't provide an api key", "no api key", "missing api key", "api key is required") ? .missingKey : .badKey
        } else if has("insufficient_quota", "billing", "credit balance", "quota", "insufficient balance", "payment required") || status == 402 {
            kind = .quota
        } else if has("context_length", "context length", "maximum context", "too many tokens", "prompt is too long") || status == 413 {
            kind = .tooLong
        } else if status == 429 || has("rate_limit", "rate limit") {
            kind = .rateLimited
        } else if status == 404 || has("model_not_found", "not_found_error", "does not exist", "no such model") {
            kind = .notFound
        } else if status == 403 || has("permission_error", "permission denied", "unsupported_country") {
            kind = .forbidden
        } else if [408, 504, 524].contains(status ?? 0) {
            kind = .timeout
        } else if (status ?? 0) >= 500 || has("overloaded", "server_error", "api_error", "service unavailable") {
            kind = .unavailable
        } else if status == 400 || status == 422 || has("invalid_request") {
            kind = .badRequest
        } else {
            kind = .other
        }
        let prefix = status.map { "HTTP \($0)" } ?? ""
        let text = String(message.prefix(600))
        return AIFailure(kind: kind, detail: [prefix, text].filter { !$0.isEmpty }.joined(separator: " · "), model: model)
    }

    /// Any error from a chat, a test or a model list, in plain words.
    static func from(_ error: Error, host: String = "") -> AIFailure {
        if let failure = error as? AIFailure { return failure }
        if let error = error as? AIError { return AIFailure(kind: .plain, detail: error.localizedDescription) }
        if let error = error as? URLError {
            let kind: Kind = switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: .offline
            case .timedOut: .timeout
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .badURL, .unsupportedURL: .unreachable
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected: .insecure
            default: .other
            }
            return AIFailure(kind: kind, detail: error.localizedDescription, host: error.failingURL?.host ?? host)
        }
        return AIFailure(kind: .other, detail: error.localizedDescription)
    }
}
