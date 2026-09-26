import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// A failed request read into the error card (TurnErrors): the title from the status and type,
/// the provider's words cleaned, the chips, the facts, the raw body and Copy.
@Suite("Turn errors")
struct TurnErrorTests {
    typealias F = Fixture
    static let utc = TimeZone(identifier: "UTC")!

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let text: String
        var provider: String? = "openai"
        var model: String? = "gpt-5"
        var host: String? = "build-01"
        let kind: NativeTurnError.Kind
        let title: String
        let chips: [String]
        let message: String
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "OpenAI refusing a key",
             text: #"401: {"message":"Incorrect API key provided: sk-svcac*****************************fvMA. You can find your API key at https://platform.openai.com/account/api-keys.","type":"authentication_error","code":"auth_unavailable"}"#,
             kind: .auth, title: "OpenAI rejected the API key", chips: ["401", "authentication_error"],
             message: "Incorrect API key provided: sk-svcac…fvMA. You can find your API key at https://platform.openai.com/account/api-keys."),
        Case(name: "pi's own prefix, a key in the clear",
             text: "OpenAI API error (401): Incorrect API key provided: sk-proj-abcdefghijklmnopqrstuvwxyz0123",
             kind: .auth, title: "OpenAI rejected the API key", chips: ["401"],
             message: "Incorrect API key provided: sk-proj-…0123"),
        Case(name: "DeepSeek refusing a role",
             text: #"422: {"error":{"message":"Failed to deserialize the JSON body into the target type: messages[0].role: unknown variant `developer`, expected one of `system`, `user`, `assistant`, `tool`","type":"invalid_request_error","param":null,"code":"invalid_request_error"}}"#,
             provider: "deepseek", model: "deepseek-chat",
             kind: .other, title: "The request to DeepSeek failed", chips: ["422", "invalid_request_error"],
             message: "Failed to deserialize the JSON body into the target type: messages[0].role: unknown variant developer, expected one of system, user, assistant, tool"),
        Case(name: "Anthropic overloaded",
             text: #"529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"},"request_id":"req_011CSHp"}"#,
             provider: "anthropic", model: "claude-sonnet-4-5",
             kind: .overloaded, title: "Anthropic is overloaded", chips: ["529", "overloaded_error"], message: "Overloaded"),
        Case(name: "a server error",
             text: #"500: {"message":"The server had an error while processing your request. Sorry about that!","type":"server_error"}"#,
             kind: .server, title: "OpenAI had a server error", chips: ["500", "server_error"],
             message: "The server had an error while processing your request. Sorry about that!"),
        Case(name: "rate limited",
             text: "429 Rate limit reached for gpt-5 on tokens per min (TPM): limit 2,000,000, used 1,998,412. Please try again in 1.2s.",
             kind: .rateLimit, title: "Rate limited by OpenAI", chips: ["429"],
             message: "Rate limit reached for gpt-5 on tokens per min (TPM): limit 2,000,000, used 1,998,412. Please try again in 1.2s."),
        Case(name: "Google's quota",
             text: #"{"error":{"code":429,"message":"Resource has been exhausted (e.g. check quota).","status":"RESOURCE_EXHAUSTED"}}"#,
             provider: "google", model: "gemini-2.5-pro",
             kind: .rateLimit, title: "Rate limited by Google", chips: ["429", "RESOURCE_EXHAUSTED"],
             message: "Resource has been exhausted (e.g. check quota)."),
        Case(name: "a thread too long",
             text: #"400: {"message":"This model's maximum context length is 400,000 tokens. Your messages resulted in 412,380 tokens.","type":"invalid_request_error","code":"context_length_exceeded"}"#,
             kind: .contextTooLong, title: "The thread is too long for gpt-5", chips: ["400", "context_length_exceeded"],
             message: "This model's maximum context length is 400,000 tokens. Your messages resulted in 412,380 tokens."),
        Case(name: "a connection reset",
             text: "request to https://api.openai.com/v1/responses failed, reason: read ECONNRESET",
             kind: .network, title: "Couldn’t reach OpenAI", chips: ["ECONNRESET", "build-01"],
             message: "api.openai.com didn’t answer from build-01: connection reset."),
        Case(name: "the SDK's connection error",
             text: "Connection error.", host: nil,
             kind: .network, title: "Couldn’t reach OpenAI", chips: [],
             message: "OpenAI didn’t answer: connection error."),
        Case(name: "a timeout",
             text: "Request timed out.",
             kind: .timeout, title: "OpenAI didn’t respond in time", chips: ["timeout"], message: "Request timed out."),
        Case(name: "anything else",
             text: "502 Unexpected end of JSON input",
             kind: .other, title: "The request to OpenAI failed", chips: ["502"], message: "Unexpected end of JSON input"),
        Case(name: "no provider known",
             text: "Something broke", provider: nil, model: nil,
             kind: .other, title: "The model request failed", chips: [], message: "Something broke"),
    ]

    @Test(arguments: cases)
    func providerErrorsReadAsTheBoardsDrawThem(_ c: Case) {
        let error = NativeTurnError(text: c.text, provider: c.provider, model: c.model, host: c.host, timeZone: Self.utc)
        #expect(error.kind == c.kind)
        #expect(error.title == c.title)
        #expect(error.chips == c.chips)
        #expect(error.messageText == c.message)
    }

    @Test func keysAreCutLinksMarkedAndQuotedNamesSetAsCode() {
        let key = NativeTurnError(text: Self.cases[0].text, provider: "openai", model: "gpt-5", timeZone: Self.utc)
        #expect(key.message == [
            .text("Incorrect API key provided: "), .code("sk-svcac…fvMA"), .text(". You can find your API key at "),
            .link(display: "platform.openai.com/account/api-keys", url: "https://platform.openai.com/account/api-keys"), .text("."),
        ])
        let quoted = NativeTurnError(text: Self.cases[2].text, provider: "deepseek", timeZone: Self.utc)
        #expect(quoted.message.contains(.code("developer")) && quoted.message.contains(.code("tool")))
    }

    @Test func factsNameWhoFailedWhereAndWhen() {
        let error = NativeTurnError(text: Self.cases[3].text, provider: "anthropic", model: "claude-sonnet-4-5", host: "build-01",
                                    at: 1_790_281_471_000, timeZone: Self.utc)
        #expect(error.source == "claude-sonnet-4-5 · Anthropic")
        #expect(error.time == "8:24 PM")
        #expect(error.foldedMeta == "529 · 8:24 PM")
        #expect(error.facts == [
            .init("Provider", "Anthropic", mono: false), .init("Model", "claude-sonnet-4-5"), .init("Host", "build-01"),
            .init("Status", "529"), .init("Type", "overloaded_error"), .init("Request", "req_011CSHp"), .init("At", "8:24:31 PM"),
        ])
    }

    @Test(arguments: [
        (1, 0.0, 0.0, nil),
        (3, 0.0, 45_000.0, "Tried 3 times over 45s"),
        (3, 0.0, 100_000.0, "Tried 3 times over 1m 40s"),
        (3, 0.0, 120_000.0, "Tried 3 times over 2m"),
        (3, 0.0, 1_860_000.0, "Tried 3 times over 31m"),
        (2, 0.0, 400.0, "Tried 2 times"),
    ] as [(Int, Double, Double, String?)])
    func retriesSayHowManyAndOverHowLong(_ attempts: Int, _ first: Double, _ last: Double, _ expected: String?) {
        let error = NativeTurnError(text: "529 overloaded", provider: "anthropic", attempts: attempts, firstAt: first, at: last, timeZone: Self.utc)
        #expect(error.tries == expected)
    }

    /// The raw body keeps the provider's key order, pretty-printed, with the key cut there too.
    @Test func theBodyIsPrettyPrintedInTheProvidersOrder() {
        let error = NativeTurnError(text: Self.cases[0].text, provider: "openai", timeZone: Self.utc)
        let text = error.body.map(\.text).joined()
        #expect(text == """
        {
          "message": "Incorrect API key provided: sk-svcac…fvMA. You can find your API key at https://platform.openai.com/account/api-keys.",
          "type": "authentication_error",
          "code": "auth_unavailable"
        }
        """)
        #expect(error.body.contains(.key("\"type\"")) && error.body.contains(.redacted("sk-svcac…fvMA")))
        #expect(error.body.contains(.link("https://platform.openai.com/account/api-keys")))
        let nested = NativeTurnError(text: #"529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"},"list":[1,[]],"empty":{}}"#)
        #expect(nested.body.map(\.text).joined() == """
        {
          "type": "error",
          "error": {
            "type": "overloaded_error",
            "message": "Overloaded"
          },
          "list": [
            1,
            []
          ],
          "empty": {}
        }
        """)
        #expect(NativeTurnError(text: "Request timed out.").body == [.plain("Request timed out.")])
    }

    /// Copy is the whole error as text, keys cut the same way.
    @Test func copyIsTheWholeErrorRedacted() {
        let error = NativeTurnError(text: Self.cases[1].text, provider: "openai", model: "gpt-5", host: "build-01", at: 0, timeZone: Self.utc)
        #expect(error.copyText.hasPrefix("OpenAI rejected the API key\nIncorrect API key provided: sk-proj-…0123\n401 · gpt-5 · OpenAI\n"))
        #expect(error.copyText.contains("Host: build-01") && error.copyText.contains("At: 12:00:00 AM"))
        #expect(!error.copyText.contains("abcdefghijklmnopqrstuvwxyz"))
    }

    @Test func oneSignatureMeansFailedTheSameWay() {
        let first = NativeTurnError(text: "429 Rate limit reached: used 10", provider: "openai", at: 0)
        let again = NativeTurnError(text: "429 Rate limit reached: used 12", provider: "openai", at: 60_000)
        let other = NativeTurnError(text: "500 server error", provider: "openai")
        #expect(first.signature == again.signature && first.signature != other.signature)
    }

    @Test func theRetryLineCountsDownThenSaysItIsRetrying() {
        let line = NativeRetryLine(title: "OpenAI is overloaded", glyph: "arrow.clockwise", attempt: 2, maxAttempts: 3, retryAt: 10_000)
        #expect(line.text(now: 2_000) == "OpenAI is overloaded · retrying in 8s")
        #expect(line.text(now: 9_500) == "OpenAI is overloaded · retrying in 1s")
        #expect(line.text(now: 10_000) == "OpenAI is overloaded · retrying")
        #expect(line.count == "2 of 3")
        #expect(NativeRetryLine(title: "x", glyph: "g", attempt: 1, maxAttempts: 0, retryAt: 0).count == nil)
    }
}
