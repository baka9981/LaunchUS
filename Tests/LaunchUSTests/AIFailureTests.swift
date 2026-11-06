import Foundation
import Testing
@testable import LaunchUS

@Suite struct AIFailureTests {
    private func kind(_ status: Int?, _ error: [String: Any], keyMissing: Bool = false) -> AIFailure.Kind {
        AIFailure.gateway(status: status, json: ["error": error], keyMissing: keyMissing).kind
    }

    @Test func sortsGatewayAnswers() {
        #expect(kind(401, ["message": "You didn't provide an API key."]) == .missingKey)
        #expect(kind(401, ["message": "Incorrect API key provided"], keyMissing: true) == .missingKey)
        #expect(kind(401, ["message": "Incorrect API key provided", "code": "invalid_api_key"]) == .badKey)
        #expect(kind(429, ["message": "You exceeded your current quota", "code": "insufficient_quota"]) == .quota)
        #expect(kind(429, ["message": "Rate limit reached"]) == .rateLimited)
        #expect(kind(400, ["message": "This model's maximum context length is 8192 tokens", "code": "context_length_exceeded"]) == .tooLong)
        #expect(kind(404, ["message": "The model `gpt-9` does not exist", "code": "model_not_found"]) == .notFound)
        #expect(kind(529, ["type": "overloaded_error", "message": "Overloaded"]) == .unavailable)
        #expect(kind(400, ["message": "tools is not supported"]) == .badRequest)
        #expect(kind(nil, ["type": "authentication_error", "message": "invalid x-api-key"]) == .badKey)
    }

    @Test func keepsTheRawTextAsDetail() {
        let failure = AIFailure.gateway(status: 401, json: ["error": ["message": "Incorrect API key provided"]])
        #expect(failure.detail == "HTTP 401 · Incorrect API key provided")
        #expect(failure.opensSettings)
        #expect(failure.localizedDescription.hasPrefix(failure.title))
    }

    @Test func sortsNetworkErrors() {
        #expect(AIFailure.from(URLError(.notConnectedToInternet)).kind == .offline)
        #expect(AIFailure.from(URLError(.timedOut)).kind == .timeout)
        #expect(AIFailure.from(URLError(.cannotFindHost), host: "example.test").kind == .unreachable)
        let plain = AIFailure.from(AIError.message("网关地址无效"))
        #expect(plain.kind == .plain && plain.title == "网关地址无效" && !plain.hasDetail)
    }
}
