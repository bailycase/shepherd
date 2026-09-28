import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Signing in through the app for real: the sheet's store on the sign-in bridge (node, the fake pi
/// SDK) against a scratch Shepherd home, with the stub engine refusing to start an agent until the
/// home holds a login. An agent waiting on "not signed in" starts again, with no click, the moment
/// a sign-in lands, and the sheet counts it; signing out removes only Shepherd's credential.
@Suite("Signing in from the app", .mainActorExclusive, .enabled(if: MCPAgentHarness.node != nil, "needs node 22.6 or later"))
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
            let node = try #require(MCPAgentHarness.node)
            let script = try PiSignInScript.install(in: dir)
            var environment = ProcessInfo.processInfo.environment
            environment["FAKE_PI_CONTROL"] = control.path
            let files = pi.files
            let store = PiAuthStore(pi: pi, bridge: {
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

        try await eventuallyOnMain("the agent to wait on a sign-in", timeout: .seconds(20)) { vm.notSignedIn[id] != nil }
        #expect(vm.notSignedIn[id]?.provider == "anthropic", "its model's provider")
        #expect(auth.needed == ["anthropic"] && vm.piSignInNeedsAttention)
        let needsYou: [SidebarListRow] = vm.sidebarLists.needsYou
        let row = needsYou.first { $0.id == .local(id) }
        #expect(row?.accessory == .reason("sign in"))

        // Sign in to Anthropic from the agent's card: the page opens there and the sheet starts;
        // a code pasted instead of the browser's callback finishes it.
        vm.openSignIn("anthropic", origin: .agentCard)
        #expect(vm.showSettings && vm.settingsSection == .piSignIn)
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

    @Test func anOldSuccessfulKeyCheckNeverEnablesSaveWhileTheReplacementIsUnchecked() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let sdk = setup.dir.appendingPathComponent("gated-sdk.mjs")
        let imported = String(decoding: try JSONEncoder().encode(URL(fileURLWithPath: FakePiSDK.path).absoluteString), as: UTF8.self)
        try """
        import { ModelRuntime as Base } from \(imported);
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
        #expect(vm.showSettings && vm.settingsSection == .piSignIn && auth.focus == "kimi-coding" && auth.session == nil)

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
