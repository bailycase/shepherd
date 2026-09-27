import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The first launch of a build with Shepherd's own pi, through the real view model and the stub
/// engine: the user's pi (a fixture with fake logins of every kind) is copied into a scratch
/// Shepherd home once, the welcome step says what came over, and restored agents wait for it to
/// close; a later launch copies nothing. The fixture "your pi" stays byte-identical.
@Suite("Your pi at the first launch", .mainActorExclusive)
@MainActor
struct YourPiFirstLaunchTests {
    /// A scratch Shepherd pi home and a scratch "your pi" (the fixture, unless `yourPi` is false),
    /// on the stub engine; the user's home folder is scratch too.
    struct Setup {
        let dir: URL
        let yours: URL
        let pi: PiSetup

        init(yourPi: Bool = true, environmentKeys: Set<String> = []) throws {
            dir = try makeScratchDirectory("first")
            let user = dir.appendingPathComponent("user", isDirectory: true)
            yours = user.appendingPathComponent(".pi/agent", isDirectory: true)
            if yourPi { try YourPiFixture.make(at: yours, home: user.path) }
            pi = PiSetup(engine: PiSetup.app.engine, home: dir.appendingPathComponent("support/pi", isDirectory: true),
                         yourPi: YourPiLocator(.fixed(yourPi ? yours : nil, environmentKeys: environmentKeys)), userHome: user.path)
        }

        /// A restored agent in its own folder.
        func agent() throws -> (Space, AgentFixture) {
            let work = dir.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let space = Fixture.space(path: work.path)
            var agent = Fixture.agent("worker", in: space, cwd: work.path, piSession: SessionID())
            agent.agent.model = "anthropic/claude-fixture-4"
            return (space, agent)
        }

        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    static func launch(of sessionID: String) -> StubPi.Launch? {
        StubPi.launches().last { $0.argv.contains("--session-id") && $0.argv.contains(sessionID) }
    }

    @Test func theFirstLaunchCopiesYourPiAndHoldsRestoredAgentsUntilTheWelcomeCloses() async throws {
        try StubPi.installAsEngine()
        let setup = try Setup()
        defer { setup.remove() }
        let app = try AppHarness(pi: setup.pi)
        defer { app.stop() }
        let (space, agent) = try setup.agent()
        let sessionID = agent.agent.effectivePiSessionID
        let before = try YourPiFixture.tree(setup.yours)

        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]), restoringAgents: true, welcomingYourPi: true)

        try await eventuallyOnMain("the welcome step") { vm.yourPi.welcome != nil }
        let welcome = try #require(vm.yourPi.welcome)
        #expect(welcome.report.first && welcome.survey.canStartAgents)
        let rows = PiWelcomeSheet.rows(welcome)
        #expect(rows.contains(.init(title: "Anthropic", detail: "Signed in")))
        #expect(rows.contains(.init(title: "Groq", detail: "API key that runs a command")))
        #expect(rows.contains(.init(title: "Custom providers", detail: "local-llm")))
        #expect(rows.contains(.init(title: "Instructions", detail: "AGENTS.md, read live")))
        for secret in YourPiFixture.secrets { #expect(!String(describing: welcome).contains(secret)) }
        // Copied into Shepherd's home, subscription sign-ins included; theirs untouched.
        let auth = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: setup.pi.home.appendingPathComponent("auth.json"))) as? [String: Any])
        #expect(Set(auth.keys) == ["anthropic", "openai-codex", "openai", "google", "groq"])
        #expect(try YourPiFixture.tree(setup.yours) == before, "your pi is byte-identical")

        // Held: the restored agent's pi hasn't started, not even as the agent on screen.
        #expect(vm.holdsForWelcome && vm.sessions.startQueue.held && vm.sessions.startQueue.started.isEmpty)
        #expect(Self.launch(of: sessionID) == nil)

        vm.finishWelcome()
        #expect(vm.yourPi.welcome == nil && !vm.sessions.startQueue.held)
        try await eventuallyAsync("the restored agent's pi to start") { Self.launch(of: sessionID) != nil }
        let launch = try #require(Self.launch(of: sessionID))
        #expect(launch.env["SHEPHERD_YOUR_PI_INSTRUCTIONS"] == setup.yours.standardizedFileURL.path, "it reads your instructions live")
        #expect(launch.env["PI_CODING_AGENT_DIR"] == setup.pi.home.path)
        #expect(try YourPiFixture.tree(setup.yours) == before)
    }

    /// Once the first copy has run, a launch copies nothing (a change in their pi stays there),
    /// shows no welcome, and starts restored agents at once.
    @Test func aLaterLaunchCopiesNothingAndStartsAgentsAtOnce() async throws {
        try StubPi.installAsEngine()
        let setup = try Setup()
        defer { setup.remove() }
        #expect(setup.pi.copyYourPiOnce()?.first == true)
        try Data(#"{"xai": {"type": "api_key", "key": "$XAI_API_KEY"}}"#.utf8).write(to: setup.yours.appendingPathComponent("auth.json"))
        let app = try AppHarness(pi: setup.pi)
        defer { app.stop() }
        let (space, agent) = try setup.agent()

        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]), restoringAgents: true, welcomingYourPi: true)

        try await eventuallyAsync("the restored agent's pi to start") { Self.launch(of: agent.agent.effectivePiSessionID) != nil }
        #expect(vm.yourPi.welcome == nil && !vm.holdsForWelcome)
        let auth = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: setup.pi.home.appendingPathComponent("auth.json"))) as? [String: Any])
        #expect(auth["xai"] == nil && auth["anthropic"] != nil)
    }

    /// A new user with no pi and no key in the environment sees only sign-in; skipping it is safe:
    /// every restored agent then waits on "not signed in".
    @Test func skippingSignInWithNoKeysLeavesEveryRestoredAgentWaitingNotSignedIn() async throws {
        try StubPi.installAsEngine()
        let setup = try Setup(yourPi: false)
        defer { setup.remove() }
        let app = try AppHarness(pi: setup.pi)
        defer { app.stop() }
        let (space, agent) = try setup.agent()
        try JSONSerialization.data(withJSONObject: ["exit": "1", "stderr": "No models available."])
            .write(to: URL(fileURLWithPath: space.path).appendingPathComponent("stub-pi-startup.json"))

        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]), restoringAgents: true, welcomingYourPi: true)

        try await eventuallyOnMain("the welcome step") { vm.yourPi.welcome != nil }
        let welcome = try #require(vm.yourPi.welcome)
        #expect(welcome.report.first && welcome.report.from == nil && PiWelcomeSheet.rows(welcome).isEmpty)
        #expect(!welcome.survey.canStartAgents, "the step asks to sign in")
        #expect(vm.sessions.startQueue.started.isEmpty)

        vm.finishWelcome()
        let id = agent.agent.id
        let store = vm.threadStores.store(for: id)
        let server = app.server
        let polling = Task { await store.run(request: { try await server.nativeThread(agentID: id, request: $0) }, preview: nil) }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the agent to wait on not signed in", timeout: .seconds(20)) { store.startProblem != nil }
        #expect(store.startProblem?.kind == .notSignedIn)
        #expect(vm.cannotStart.contains(id) && vm.state.agents.contains { $0.id == id }, "the agent stays, waiting")
    }

    /// Keys the login shell sets count: with one, the welcome step asks for no sign-in.
    @Test func aKeyInTheEnvironmentIsShownAsFound() async throws {
        let setup = try Setup(yourPi: false, environmentKeys: ["OPENAI_API_KEY"])
        defer { setup.remove() }
        let app = try AppHarness(pi: setup.pi)
        defer { app.stop() }
        let vm = try await app.start(with: ShepherdState(), welcomingYourPi: true)
        try await eventuallyOnMain("the welcome step") { vm.yourPi.welcome != nil }
        let welcome = try #require(vm.yourPi.welcome)
        #expect(welcome.survey.canStartAgents)
        #expect(PiWelcomeSheet.rows(welcome) == [.init(title: "OPENAI_API_KEY", detail: "In your environment")])
        vm.finishWelcome()
    }
}
