import Foundation
import Testing
@testable import ShepherdSessions

/// Answers Anthropic's usage and profile requests by the token: tok-a used 11%, tok-b 22%.
final class StubUsage: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        let body = request.url?.path == "/api/oauth/profile"
            ? #"{"account":{"email":"\#(token)@x.co"}}"#
            : #"{"five_hour":{"utilization":\#(token == "tok-a" ? 11 : 22),"resets_at":null}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Subscription usage: which credentials make a request, and the windows each provider's answer holds.
@Suite("Subscription usage")
struct PiUsageTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func onlyALiveOAuthCredentialMakesARequest() throws {
        let live: [String: Any] = ["type": "oauth", "access": "tok", "refresh": "r", "expires": 2_000_000_000.0]
        let anthropic = try #require(PiUsage.request("anthropic", credential: live, now: now))
        #expect(anthropic.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(anthropic.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(anthropic.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")

        var codex = live
        #expect(PiUsage.request("openai-codex", credential: codex, now: now) == nil) // no account id
        codex["accountId"] = "acct"
        #expect(PiUsage.request("openai-codex", credential: codex, now: now)?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct")

        var expired = live
        expired["expires"] = 999_000.0 // ms, before now
        #expect(PiUsage.request("anthropic", credential: expired, now: now) == nil)
        #expect(PiUsage.request("anthropic", credential: ["type": "api_key", "key": "sk"], now: now) == nil)
        #expect(PiUsage.request("xai", credential: live, now: now) == nil)
    }

    @Test func anthropicWindowsSkipNullsAndParseResets() {
        let body = """
        {"five_hour":{"utilization":23.0,"resets_at":"2025-10-13T19:00:00.123456+00:00"},
         "seven_day":{"utilization":61,"resets_at":"2025-10-16T07:00:00+00:00"},
         "seven_day_opus":null,"seven_day_sonnet":{"utilization":null,"resets_at":null}}
        """
        let windows = PiUsage.parse("anthropic", Data(body.utf8))
        #expect(windows.map(\.name) == ["5-hour", "Week"])
        #expect(windows.map(\.usedPercent) == [23, 61])
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_760_382_000))
        #expect(windows[1].resetsAt != nil)
    }

    @Test func accountsShowTheirEmailInPlaceOfAnAutomaticName() {
        let claims = Data(#"{"https://api.openai.com/profile":{"email":"me@example.com"}}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        #expect(PiAccounts.tokenEmail(["access": "h.\(claims).s"]) == "me@example.com")
        #expect(PiAccounts.tokenEmail(["access": "sk-ant-oat-opaque"]) == nil)
        #expect(PiUsage.profileEmail(Data(#"{"account":{"email":"a@b.co"}}"#.utf8)) == "a@b.co")
        #expect(PiUsage.profileEmail(Data(#"{"account":{"email_address":"a@b.co"}}"#.utf8)) == "a@b.co")

        let automatic = PiAccount(id: "1", name: "Account 2", email: "a@b.co")
        #expect(automatic.title == "a@b.co" && automatic.detail == nil)
        let named = PiAccount(id: "2", name: "Work", email: "a@b.co")
        #expect(named.title == "Work" && named.detail == "a@b.co")
        #expect(PiAccount(id: "3", name: "Account 1").title == "Account 1")
    }

    /// Each saved account is asked with its own token and keeps what it said; an expired one keeps
    /// its last reading.
    @Test func everyAccountsUsageIsReadWithItsOwnToken() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = 4_000_000_000_000.0
        func oauth(_ token: String, expires: Double = live) -> [String: Any] { ["type": "oauth", "access": token, "refresh": "r", "expires": expires] }
        try JSONSerialization.data(withJSONObject: ["anthropic": oauth("tok-a")]).write(to: dir.appendingPathComponent("auth.json"))
        try JSONSerialization.data(withJSONObject: ["anthropic": ["active": "a", "accounts": [
            ["id": "a", "name": "Account 1", "credential": oauth("old")],
            ["id": "b", "name": "Account 2", "credential": oauth("tok-b")],
            ["id": "c", "name": "Account 3", "credential": oauth("tok-c", expires: 1),
             "usage": [["name": "5-hour", "used": 7.0]], "usageAt": 1.0],
        ]]]).write(to: dir.appendingPathComponent(PiAccounts.fileName))

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubUsage.self]
        let home = PiHome(directory: dir, engine: PiHomeTests.engine)
        let active = await PiUsage.read(home: home, session: URLSession(configuration: config))

        #expect(active["anthropic"]?.first?.usedPercent == 11) // tok-a
        let accounts = try #require(PiAccounts(home: home).lists()["anthropic"]?.accounts)
        #expect(accounts.map { $0.usage.first?.usedPercent } == [11, 22, 7])
        #expect(accounts.map(\.email) == ["tok-a@x.co", "tok-b@x.co", nil])
        #expect(accounts[2].usageAt == Date(timeIntervalSince1970: 1))
    }

    @Test func codexWindowsAreNamedByTheirLength() {
        let body = """
        {"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_at":1760382000},
         "secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":1760900000}}}
        """
        let windows = PiUsage.parse("openai-codex", Data(body.utf8))
        #expect(windows == [PiUsageWindow(name: "5-hour", usedPercent: 12, resetsAt: Date(timeIntervalSince1970: 1_760_382_000)),
                            PiUsageWindow(name: "Week", usedPercent: 40, resetsAt: Date(timeIntervalSince1970: 1_760_900_000))])
        #expect(PiUsage.parse("openai-codex", Data("{}".utf8)).isEmpty)
    }
}
