import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A client changing this Mac's provider sign-ins over the listener: the real sign-in bridge
/// (node, the fake pi SDK) against a scratch Shepherd home, through the view model's handler. A
/// key is checked before it is saved, a second key is added beside the first as the Mac's own
/// Add account does, the saved accounts are switched, renamed, rotated and removed, and signing
/// out removes Shepherd's credential. No reply carries a key.
@Suite("Remote provider sign-in", .mainActorExclusive, .enabled(if: TestNode.url != nil, "needs node 22.6 or later"))
@MainActor
struct RemoteProviderConfigFlowTests {
    @Test(arguments: [("fixture-login", HostProviderSignInMethod.oauth), ("fixture-key", .apiKey)])
    func aClientDiscoversAndAnswersAnUnfamiliarProvidersAccountFlow(provider: String, method: HostProviderSignInMethod) async throws {
        let setup = try PiSignInFlowTests.Setup()
        defer { setup.remove() }
        let auth = try setup.store()
        let app = try AppHarness(pi: setup.pi)
        defer { app.stop() }
        try await app.start(piAuth: auth)
        let tokenURL = app.dir.appendingPathComponent("provider-token")
        let port = try app.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "phone")
        defer { client.disconnect() }

        guard case .providers(let rows) = try await client.hostInventory(.providers) else { Issue.record("expected providers"); return }
        let row = try #require(rows.first { $0.id == provider })
        #expect(row.badge == (method == .oauth ? "Subscription" : "API key"))
        #expect(row.signIn?.keyForm == false)
        await #expect(throws: RemoteHostClientError.self) {
            try await client.hostConfig(.providerKey(provider: provider, key: "not-an-api-key"))
        }

        for adding in [false, true] {
            let request: RemoteHostConfigRequest = adding && method == .oauth ? .providerAccount(provider: provider, action: .add)
                : .providerSignIn(provider: provider, method: method, adding: adding)
            guard case .signIn(let started) = try await client.hostConfig(request) else { Issue.record("expected sign-in"); return }
            let questions: [(HostSignInPrompt.Kind, String)] = method == .oauth
                ? [(.select, "west"), (.text, "acme"), (.secret, " fixture-password ")]
                : [(.secret, " !fixture$password "), (.text, "acme"), (.select, "west")]
            for (kind, answer) in questions {
                var progress: HostSignInProgress?
                try await eventuallyAsync("the remote provider's \(kind) question") {
                    if case .signIn(let value) = try await client.hostConfig(.signIn(id: started.id, action: .poll)) {
                        progress = value
                        return value.prompt?.kind == kind
                    }
                    return false
                }
                let waiting = try #require(progress)
                #expect(waiting.wantsCode == (kind == .text))
                let wire = String(decoding: try JSONEncoder().encode(waiting), as: UTF8.self)
                #expect(!wire.contains("fixture-password"))
                await #expect(throws: RemoteHostClientError.self) {
                    try await client.hostConfig(.signIn(id: started.id, action: .complete(answer, promptID: "stale-question")))
                }
                _ = try await client.hostConfig(.signIn(id: started.id, action: .complete(answer, promptID: waiting.prompt?.id)))
            }
            try await eventuallyAsync("the remote account to land") {
                if case .signIn(let value) = try await client.hostConfig(.signIn(id: started.id, action: .poll)) { return value.phase == .done }
                return false
            }
        }
        await auth.landing?.value
        #expect(auth.accounts[provider]?.accounts.count == 2)
        #expect((try setup.stored()[provider] as? [String: Any])?["type"] as? String == (method == .oauth ? "oauth" : "api_key"))
        _ = try await client.hostConfig(.providerSignOut(provider: provider))
        #expect(try setup.stored()[provider] == nil)
    }

    @Test func aClientSavesAddsSwitchesAndSignsOutOfKeys() async throws {
        let dir = try makeScratchDirectory("rpsign")
        defer { try? FileManager.default.removeItem(at: dir) }
        let user = dir.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        let pi = PiSetup(engine: PiSetup.app.engine, home: dir.appendingPathComponent("support/pi", isDirectory: true),
                         yourPi: YourPiLocator(.fixed(nil)), userHome: user.path)
        let node = try #require(TestNode.url)
        let script = try PiSignInScript.install(in: dir)
        var environment = ProcessInfo.processInfo.environment
        environment["FAKE_PI_CONTROL"] = dir.path
        // The second key: a variable the login shell sets, as Settings' key form allows.
        environment["REMOTE_TEST_DEEPSEEK_KEY"] = FakePiSDK.goodKey
        let files = pi.files
        let auth = PiAuthStore(pi: pi, bridge: {
            PiSignInBridge(line: PiLaunch.signInBridge(node: .executable(node.path), script: script.path, sdk: FakePiSDK.path, home: files),
                           environment: environment)
        })
        auth.openURL = { _ in }
        auth.copy = { _ in }
        let app = try AppHarness(pi: pi)
        defer { app.stop() }
        try await app.start(piAuth: auth)
        let tokenURL = app.dir.appendingPathComponent("remote-token")
        let port = try app.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "phone")
        defer { client.disconnect() }

        func stored() throws -> [String: Any] {
            guard let data = try? Data(contentsOf: pi.home.appendingPathComponent("auth.json")) else { return [:] }
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func deepseek(_ result: RemoteHostConfigResult) throws -> HostProviderStatus {
            guard case .providers(let providers) = result else { throw CommandFailure("providers", "\(result)") }
            return try #require(providers.first { $0.id == "deepseek" })
        }
        func carriesNoKey(_ result: RemoteHostConfigResult) throws {
            let wire = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            #expect(!wire.contains(FakePiSDK.goodKey) && !wire.contains("sk-fake-bad"))
        }

        // A key the provider refuses is not saved.
        await #expect(throws: RemoteHostClientError.self) {
            try await client.hostConfig(.providerKey(provider: "deepseek", key: "sk-fake-bad-key"))
        }
        #expect(try stored()["deepseek"] == nil)

        let saved = try await client.hostConfig(.providerKey(provider: "deepseek", key: FakePiSDK.goodKey))
        try carriesNoKey(saved)
        #expect(try deepseek(saved).auth == .apiKey)
        #expect((try stored()["deepseek"] as? [String: Any])?["key"] as? String == FakePiSDK.goodKey)

        // Add key: the first is saved as an account, the second lands beside it and is in use.
        let added = try await client.hostConfig(.providerAccount(provider: "deepseek", action: .addKey("$REMOTE_TEST_DEEPSEEK_KEY")))
        try carriesNoKey(added)
        let accounts = try #require(try deepseek(added).accountList)
        #expect(accounts.count == 2 && accounts.filter(\.active).count == 1)
        #expect((try stored()["deepseek"] as? [String: Any])?["key"] as? String == "$REMOTE_TEST_DEEPSEEK_KEY")

        let first = try #require(accounts.first { !$0.active })
        let used = try deepseek(try await client.hostConfig(.providerAccount(provider: "deepseek", action: .use(id: first.id))))
        #expect(used.accountList?.first { $0.active }?.id == first.id)
        #expect((try stored()["deepseek"] as? [String: Any])?["key"] as? String == FakePiSDK.goodKey)
        let renamed = try deepseek(try await client.hostConfig(.providerAccount(provider: "deepseek", action: .rename(id: first.id, name: "work"))))
        #expect(renamed.accountList?.first { $0.id == first.id }?.name == "work")
        let rotating = try deepseek(try await client.hostConfig(.providerAccount(provider: "deepseek", action: .rotate(true))))
        #expect(rotating.rotate == true)
        let other = try #require(accounts.first { $0.active })
        let removed = try deepseek(try await client.hostConfig(.providerAccount(provider: "deepseek", action: .remove(id: other.id))))
        #expect(removed.accountList == nil, "one account left lists none")

        guard case .providers(let out) = try await client.hostConfig(.providerSignOut(provider: "deepseek")) else {
            Issue.record("expected the providers"); return
        }
        #expect(!out.contains { $0.id == "deepseek" && $0.auth == .apiKey }, "a key signed out is no longer listed as saved")
        #expect(try stored()["deepseek"] == nil)
    }
}
