import Foundation
import Testing
@testable import ShepherdSessions

/// Sign-in's words and rules that need no process: the providers it offers, how a key shows, and
/// how a copy stands against the user's pi.
@Suite("Sign-in catalog")
struct PiSignInCatalogTests {
    @Test func theSubscriptionsAreTheBoardsInOrderWithoutGoogle() {
        #expect(PiSignInCatalog.subscriptions.map(\.id) == ["anthropic", "openai-codex", "github-copilot", "xai", "kimi-coding", "radius"])
        #expect(PiSignInCatalog.subscriptions.filter(\.sharedLogin).map(\.id) == ["anthropic", "openai-codex", "kimi-coding", "radius"])
        #expect(PiSignInCatalog.subscriptions.filter { $0.flow == .device }.map(\.id) == ["github-copilot", "xai", "kimi-coding"])
    }

    @Test(arguments: [("anthropic", "An"), ("openai-codex", "Cx"), ("xai", "xA"), ("kimi-coding", "Ki"), ("northwind-gateway", "No"),
                      ("ollama", "Ol"), ("", "?")])
    func eachProviderHasTwoLettersForItsBadge(provider: String, badge: String) {
        #expect(PiSignInCatalog.badge(provider) == badge)
    }

    @Test func keyProvidersLeaveOutCloudCredentialsAndAccountOnlySignIns() {
        let providers = PiSignInCatalog.keyProviders
        #expect(!providers.contains("amazon-bedrock") && !providers.contains("google-vertex") && !providers.contains("openai-codex"))
        #expect(providers.contains("deepseek") && providers.contains("openai") && providers.contains("anthropic"))
    }

    @Test(arguments: [
        ("sk-proj-abcdefghijklmnop3kQz", "sk-proj-••••3kQz"),
        ("sk-abcdefghijkl91c2", "sk-••••91c2"),
        ("sk-ant-api03-abcdefghijkl-wxyz", "sk-ant-••••wxyz"),
        ("gsk_abcdefghijklmn1234", "gsk_••••1234"),
        ("AIzaSyAbcdefghijklmnop", "••••mnop"),
        ("short-key", "••••"),
        ("  sk-abcdefghijkl91c2\n", "sk-••••91c2"),
    ])
    func aKeyShowsItsPrefixAndLastFourOnly(key: String, masked: String) {
        #expect(PiKeyMask.mask(key) == masked)
    }

    @Test(arguments: [
        ("sk-abcdefghijkl91c2", PiKeyDisplay(masked: "sk-••••91c2")),
        ("$DEEPSEEK_API_KEY", PiKeyDisplay(variables: ["DEEPSEEK_API_KEY"])),
        ("!op read op://Dev/northwind/api-key", PiKeyDisplay(runsCommand: true)),
        ("sk-abc$$defghijk91c2", PiKeyDisplay(masked: "sk-••••91c2")),
    ])
    func aStoredKeyShowsAsAMaskAVariableOrACommand(key: String, display: PiKeyDisplay) {
        #expect(PiKeyDisplay.of(key) == display)
    }

    /// A command in auth.json may carry a secret inline, so only a custom provider's (models.json,
    /// configuration) shows its text.
    @Test func onlyACustomProvidersCommandIsShown() {
        #expect(PiKeyDisplay.of("!echo sk-secret-inline").command == nil)
        #expect(PiKeyDisplay.of("!op read op://Dev/x", showingCommand: true) == PiKeyDisplay(command: "op read op://Dev/x"))
    }

    @Test func customProvidersReadTheirKeyAndAddress() throws {
        let data = Data(#"""
            {"providers": {"ollama": {"baseUrl": "http://localhost:11434"},
                           "northwind-gateway": {"apiKey": "!op read op://Dev/northwind/api-key", "baseUrl": "https://gw"}}}
            """#.utf8)
        #expect(try PiCustomProvider.parse(data) == [
            PiCustomProvider(id: "northwind-gateway", key: PiKeyDisplay(command: "op read op://Dev/northwind/api-key"), baseURL: "https://gw"),
            PiCustomProvider(id: "ollama", baseURL: "http://localhost:11434"),
        ])
    }

    struct Freshness: CustomTestStringConvertible, Sendable {
        let ours: String?, theirs: String?, copied: String?, theirsNewer: Bool
        let expected: PiFreshness?
        var testDescription: String { "ours \(ours ?? "-") theirs \(theirs ?? "-") copied \(copied ?? "-") → \(expected.map(\.rawValue) ?? "nil")" }
    }

    @Test(arguments: [
        Freshness(ours: "a", theirs: "a", copied: "a", theirsNewer: false, expected: .sameAsYourPi),
        Freshness(ours: "a", theirs: "b", copied: "a", theirsNewer: false, expected: .newerInYourPi),
        Freshness(ours: "b", theirs: "a", copied: "a", theirsNewer: false, expected: .changedHere),
        Freshness(ours: "b", theirs: "c", copied: "a", theirsNewer: false, expected: .changedHere),
        Freshness(ours: "b", theirs: "c", copied: "a", theirsNewer: true, expected: .newerInYourPi),
        Freshness(ours: nil, theirs: "a", copied: nil, theirsNewer: false, expected: .newerInYourPi),
        Freshness(ours: "a", theirs: nil, copied: "a", theirsNewer: false, expected: nil),
    ])
    func aCopyIsComparedByDigestsNeverValues(row: Freshness) {
        #expect(PiFreshness.compare(ours: row.ours, theirs: row.theirs, copied: row.copied, theirsNewer: row.theirsNewer) == row.expected)
    }

    @Test func aDigestIsShortStableAndNotTheValue() throws {
        let credential: [String: Any] = ["type": "api_key", "key": "sk-secret-value"]
        let digest = try #require(PiDigest.of(credential))
        #expect(digest.count == 24 && !digest.contains("secret"))
        #expect(PiDigest.of(["key": "sk-secret-value", "type": "api_key"]) == digest, "key order doesn't matter")
    }
}
