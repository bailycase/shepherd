import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp
@testable import ShepherdSidebar

/// Signing in through the app for real: the sheet's store on the sign-in bridge (node, the fake pi
/// SDK) against a scratch Shepherd home, with the stub engine refusing to start an agent until the
/// home holds a login. An agent waiting on "not signed in" starts again, with no click, the moment
/// a sign-in lands, and the sheet counts it; signing out removes only Shepherd's credential.
@Suite("Signing in from the app", .mainActorExclusive, .enabled(if: TestNode.url != nil, "needs node 22.6 or later"))
@MainActor
struct PiSignInFlowTests {
    struct Setup {
        let dir: URL
        let pi: PiSetup
        let control: URL

        init() throws {
            dir = try makeScratchDirectory("flow")
            let user = dir.appendingPathComponent("user", isDirectory: true)
            control = dir.appendingPathComponent("control", isDirectory: true)
            try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            pi = PiSetup(engine: PiSetup.app.engine, home: dir.appendingPathComponent("support/pi", isDirectory: true),
                         yourPi: YourPiLocator(.fixed(nil)), userHome: user.path)
        }

        /// The store the app uses, on the fake SDK.
        @MainActor func store(sdk: String = FakePiSDK.path) throws -> PiAuthStore {
            let node = try #require(TestNode.url)
            let script = try PiSignInScript.install(in: dir)
            var environment = ProcessInfo.processInfo.environment
            environment["FAKE_PI_CONTROL"] = control.path
            let files = pi.files
            let store = PiAuthStore(pi: pi, bridge: { _ in
                PiSignInBridge(line: PiLaunch.signInBridge(node: .executable(node.path), script: script.path, sdk: sdk, home: files),
                               environment: environment)
            })
            store.openURL = { _ in }
            store.copy = { _ in }
            return store
        }

        func stored() throws -> [String: Any] {
            guard let data = try? Data(contentsOf: pi.home.appendingPathComponent("auth.json")) else { return [:] }
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    static func serves(_ id: AgentID, on server: SessionServer) async -> Bool {
        if case .snapshot(let snapshot)? = try? await server.nativeThread(agentID: id, request: .snapshot()) { return snapshot.startProblem == nil }
        return false
    }

    @Test func anAgentNotSignedInStartsAgainWhenASignInLands() async throws {
        try StubPi.installAsEngine()
        let setup = try Setup()
        defer { setup.remove() }
        let app = try AppHarness(pi: setup.pi)
        defer { app.stop() }
        let work = setup.dir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["requireAuth": true]).write(to: work.appendingPathComponent("stub-pi-startup.json"))
        let space = Fixture.space(path: work.path)
        var agent = Fixture.agent("worker", in: space, cwd: work.path, piSession: SessionID())
        agent.agent.model = "anthropic/claude-fixture-4"
        let id = agent.agent.id
        let auth = try setup.store()

        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]), restoringAgents: true, piAuth: auth)
        // Its thread asks for it, as the one on screen does: the host starts its pi.
        _ = try? await app.server.nativeThread(agentID: id, request: .snapshot())

        try await eventuallyOnMain("the agent to wait on a sign-in", timeout: .seconds(20)) { vm.notSignedIn[id] != nil }
        #expect(vm.notSignedIn[id]?.provider == "anthropic", "its model's provider")
        #expect(auth.needed == ["anthropic"] && vm.piSignInNeedsAttention)
        let needsYou: [SidebarListRow] = vm.sidebarLists.needsYou
        let row = needsYou.first { $0.id == .local(id) }
        #expect(row?.accessory == .reason("sign in"))

        // Sign in to Anthropic from the agent's card: the page opens there and the sheet starts;
        // a code pasted instead of the browser's callback finishes it.
        vm.openSignIn("anthropic", origin: .agentCard)
        #expect(vm.showSettings && vm.settingsSection == .models)
        let session = try #require(auth.session)
        try await eventuallyOnMain("the browser step") { session.phase == .browser }
        session.pasteInstead()
        try await eventuallyOnMain("pi to ask for the code") { session.phase == .paste(rejected: nil) }
        session.code = FakePiSDK.goodCode + "#state"
        try await eventuallyOnMain("pi to be waiting for the code") { session.submitReady }
        session.submitCode()
        try await eventuallyOnMain("the sign-in to land, picking the agent up", timeout: .seconds(20)) { session.phase == .done(pickedUp: 1) }

        let server = app.server
        try await eventuallyAsync("the agent to serve, signed in", timeout: .seconds(20)) { await Self.serves(id, on: server) }
        try await eventuallyOnMain("the agent to leave Needs you") { vm.notSignedIn[id] == nil }
        #expect(auth.needed.isEmpty)
        #expect((try setup.stored()["anthropic"] as? [String: Any])?["type"] as? String == "oauth")
    }

    /// Usage comes from provider extensions, through the bridge: the signed-in account's, and each
    /// saved account's with its own stored credential. A saved account's reading and email are kept
    /// with it; one the extension has nothing for keeps what it last read.
    @Test func everyAccountsUsageComesFromItsExtensionAndIsSaved() async throws {
        let f = try Setup()
        defer { f.remove() }
        let live = 4_000_000_000_000.0
        func oauth(_ token: String, expires: Double = live) -> [String: Any] { ["type": "oauth", "access": token, "refresh": "r", "expires": expires] }
        try FileManager.default.createDirectory(at: f.pi.home, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["anthropic": oauth("tok-a")]).write(to: f.pi.home.appendingPathComponent("auth.json"))
        try JSONSerialization.data(withJSONObject: ["anthropic": ["active": "a", "accounts": [
            ["id": "a", "name": "Account 1", "credential": oauth("old")],
            ["id": "b", "name": "Account 2", "credential": oauth("tok-b")],
            ["id": "c", "name": "Account 3", "credential": oauth("tok-c", expires: 1),
             "usage": [["name": "5-hour", "used": 7.0]], "usageAt": 1.0],
        ]]]).write(to: f.pi.home.appendingPathComponent(PiAccounts.fileName))
        try Data(#"{"tok-a":11,"tok-b":22}"#.utf8).write(to: f.control.appendingPathComponent("usage.json"))

        let store = try f.store()
        await store.refreshUsage()

        #expect(store.usage["anthropic"]?.first?.usedPercent == 11) // the signed-in token, tok-a
        let accounts = try #require(PiAccounts(home: f.pi.files).lists()["anthropic"]?.accounts)
        #expect(accounts.map { $0.usage.first?.usedPercent } == [11, 22, 7])
        #expect(accounts.map { $0.email } == ["tok-a@x.co", "tok-b@x.co", nil])
        #expect(accounts[2].usageAt == Date(timeIntervalSince1970: 1))
    }

    @Test func anOldSuccessfulKeyCheckNeverEnablesSaveWhileTheReplacementIsUnchecked() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let sdk = setup.dir.appendingPathComponent("gated-sdk.mjs")
        let imported = String(decoding: try JSONEncoder().encode(URL(fileURLWithPath: FakePiSDK.path).absoluteString), as: UTF8.self)
        try """
        import { ModelRuntime as Base } from \(imported);
        export { DefaultResourceLoader, SettingsManager } from \(imported);
        import * as fs from 'node:fs';
        import * as path from 'node:path';
        export class ModelRuntime extends Base {
          static async create(options) { return new ModelRuntime(options); }
          async completeSimple(model, context, options) {
            if (options.apiKey === 'sk-fake-good-key-0001') {
              fs.writeFileSync(path.join(process.env.FAKE_PI_CONTROL, 'checking'), '');
              while (!fs.existsSync(path.join(process.env.FAKE_PI_CONTROL, 'release'))) await new Promise(r => setTimeout(r, 10));
            }
            return super.completeSimple(model, context, options);
          }
        }
        """.write(to: sdk, atomically: true, encoding: .utf8)
        let auth = try setup.store(sdk: sdk.path)
        let session = PiSignInSession(provider: "deepseek", subscription: nil, origin: .settings, store: auth)
        defer { session.end() }
        session.checkDelay = .zero
        session.start()
        session.key = FakePiSDK.goodKey
        try await eventuallyOnMain("the old key check to reach the gated provider") {
            FileManager.default.fileExists(atPath: setup.control.appendingPathComponent("checking").path)
        }
        session.checkDelay = .milliseconds(600)
        session.key = "replacement-invalid-key"
        let allowed = Locked(false)
        Self.watchKeyChecks(session, allowed: allowed)
        try Data().write(to: setup.control.appendingPathComponent("release"))
        try await eventuallyOnMain("the replacement key's check to be refused") {
            if case .rejected = session.keyCheck { return true }; return false
        }
        #expect(!allowed.current, "the old success must never enable Save during the new key's debounce")
        session.saveKey()
        #expect(session.phase == .key)
        #expect(try setup.stored().isEmpty)
    }

    private static func watchKeyChecks(_ session: PiSignInSession, allowed: Locked<Bool>) {
        withObservationTracking { if session.keyCheck.allowsSave { allowed.withValue { $0 = true } } } onChange: {
            Task { @MainActor in watchKeyChecks(session, allowed: allowed) }
        }
    }

    @Test(arguments: [("fixture-login", PiSignInMethod.oauth), ("fixture-key", .apiKey)])
    func aDiscoveredProviderUsesAccountLoginAndNativeQuestionsWithoutACatalogEntry(provider: String, method: PiSignInMethod) async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let auth = try setup.store()
        await auth.refreshProviders()
        #expect(auth.providersProblem == nil)
        #expect(auth.providers?.contains { $0.id == provider } == true)
        auth.signIn(provider, key: method == .apiKey)
        let session = try #require(auth.session)
        defer { auth.closeSheet() }
        #expect(session.method == method && session.flow != .key)
        let questions: [(PiSignInPrompt.Kind, String)] = method == .oauth
            ? [(.select, "west"), (.text, "acme"), (.secret, " fixture-password ")]
            : [(.secret, " !fixture$password "), (.text, "acme"), (.select, "west")]
        for (kind, answer) in questions {
            try await eventuallyOnMain("the provider's \(kind) question") {
                if case .prompt(let prompt) = session.phase { return prompt.kind == kind }; return false
            }
            session.submitPrompt(answer)
            #expect(session.promptAnswer.isEmpty)
        }
        try await eventuallyOnMain("the unfamiliar account to land") { if case .done = session.phase { return true }; return false }
        await auth.landing?.value
        let credential = try #require(try setup.stored()[provider] as? [String: Any])
        #expect(credential["type"] as? String == (method == .oauth ? "oauth" : "api_key"))
        if method == .apiKey { #expect(credential["key"] as? String == " !fixture$password ") }
        await auth.signOut(provider)
        #expect(try setup.stored()[provider] == nil)
    }

    /// An extension added in Shepherd that registers a provider: Sign-in names it as the provider's
    /// source, and Tools learns what it registered and what Shepherd can't show of it.
    @Test func aProviderIsAttributedToTheExtensionThatRegisteredIt() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let source = setup.dir.appendingPathComponent("acme-login.ts")
        try Data("export default pi => { pi.on('session_start', () => ctx.ui.setFooter(undefined)); };\n".utf8).write(to: source)
        let copy = try setup.pi.importedState().addExtension(from: source)
        let loaded = setup.pi.home.appendingPathComponent(copy.destination).path
        let listed: [[String: Any]] = [["path": loaded, "providers": ["fixture-login"], "commands": ["acme-usage"],
                                        "events": ["session_start"], "shortcuts": ["ctrl+shift+x"]]]
        try JSONSerialization.data(withJSONObject: listed).write(to: setup.control.appendingPathComponent("extensions.json"))
        let auth = try setup.store()

        await auth.refreshProviders()

        #expect(auth.providerOwners["fixture-login"]?.destination == copy.destination)
        let survey = setup.pi.importedState().survey()
        let row = try #require(survey.extensions.first { $0.copy.destination == copy.destination })
        #expect(row.terminalOnly == ["footer or header"])
        let support = PiExtensionSupport.make(try #require(auth.extensionInventory[copy.destination]), scanned: row.terminalOnly)
        #expect(support.providers == ["fixture-login"])
        #expect(support.level == .partly)
        #expect(ExtensionsText.subtitle(row, support: support, names: auth.providerNames)
            == "Adds Acme account sign-in, /acme-usage, 1 event hook · Not shown in Shepherd: shortcut ctrl+shift+x, footer or header · Added from \((source.path as NSString).abbreviatingWithTildeInPath)")
        let page = PiSignInPage.make(survey: survey, providers: auth.providers, owners: auth.providerOwners)
        #expect(page.subscriptions.first { $0.id == "fixture-login" }?.source == "acme-login")
    }

    @Test func signingOutRemovesOnlyThatProvidersCredentialFromShepherdsPi() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        try FileManager.default.createDirectory(at: setup.pi.home, withIntermediateDirectories: true)
        try Data(#"{"anthropic":{"type":"oauth","access":"a","refresh":"r","expires":1},"openai":{"type":"api_key","key":"sk-x"}}"#.utf8)
            .write(to: setup.pi.home.appendingPathComponent("auth.json"))
        let auth = try setup.store()
        var changed = 0
        auth.onChanged = { changed += 1 }

        await auth.signOut("anthropic")

        #expect(Set(try setup.stored().keys) == ["openai"] && auth.problems.isEmpty && changed == 1)
    }

    /// `/login anthropic` opens Settings ▸ Pi ▸ Sign-in at Anthropic and starts its sign-in;
    /// `/logout kimi` only scrolls there; a name Shepherd doesn't know opens the page as it is.
    @Test func slashLoginOpensSignInAndStartsTheProviderItNames() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let app = try AppHarness(pi: setup.pi)
        defer { app.stop() }
        let auth = try setup.store()
        let vm = try await app.start(with: ShepherdState(), piAuth: auth)

        vm.openSlashLogin(try #require(SlashLogin.parse("/logout kimi")))
        #expect(vm.showSettings && vm.settingsSection == .models && auth.focus == "kimi-coding" && auth.session == nil)

        vm.showSettings = false
        vm.openSlashLogin(try #require(SlashLogin.parse("/login nosuchprovider")))
        #expect(vm.showSettings && auth.session == nil)

        vm.openSlashLogin(try #require(SlashLogin.parse("/login Anthropic")))
        let session = try #require(auth.session)
        #expect(session.provider == "anthropic" && session.origin == .slash && auth.focus == "anthropic")
        try await eventuallyOnMain("the browser step") { session.phase == .browser }
        auth.closeSheet()
        #expect(auth.session == nil)
    }
}
