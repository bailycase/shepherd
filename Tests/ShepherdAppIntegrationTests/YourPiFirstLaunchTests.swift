import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The first launch of a build with Shepherd's own pi, through the real view model and the stub
/// engine: the user's pi (a fixture with fake logins of every kind) is copied into a scratch
/// Shepherd home once, and the welcome step says what came over. Restored agents wait for the
/// copy (never past its deadline), then start at once when a provider can start them, or when
/// the step closes when none can; a later launch copies nothing. The fixture "your pi" stays
/// byte-identical.
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

    /// Writes the stub's startup file into the agent's folder: like pi, it exits "No models
    /// available." unless Shepherd's home holds a login when it starts.
    static func requireSignIn(in space: Space) throws {
        try JSONSerialization.data(withJSONObject: ["requireAuth": true])
            .write(to: URL(fileURLWithPath: space.path).appendingPathComponent("stub-pi-startup.json"))
    }

    /// Whether `id`'s pi serves its thread.
    static func serves(_ id: AgentID, on server: SessionServer) async -> Bool {
        if case .snapshot? = try? await server.nativeThread(agentID: id, request: .snapshot()) { return true }
        return false
    }

    /// The start gate with logins to copy: nothing starts while the copy runs, not even the agent
    /// on screen; once it is over, restored agents start signed in (the stub exits "No models
    /// available" without a login in Shepherd's home) while the welcome step still shows, with no
    /// click. Subscription sign-ins came over, and your pi is byte-identical.
    @Test func restoredAgentsWaitForTheCopyThenStartSignedInWithoutAClick() async throws {
        try StubPi.installAsEngine()
        let setup = try Setup()
        defer { setup.remove() }
        let app = try AppHarness(pi: setup.pi)
        defer { app.stop() }
        let (space, agent) = try setup.agent()
        try Self.requireSignIn(in: space)
        let id = agent.agent.id
        let sessionID = agent.agent.effectivePiSessionID
        let before = try YourPiFixture.tree(setup.yours)
        let copying = Locked(false)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let model = YourPiModel(pi: setup.pi, firstCopy: { pi in
            copying.withValue { $0 = true }
            gate.wait()
            return pi.copyYourPiOnce()
        })

        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]), restoringAgents: true,
                                     welcomingYourPi: true, yourPi: model)

        try await eventuallyOnMain("the copy to run with the restored agent's start asked for") {
            copying.current && vm.sessions.startQueue.waiting.contains(id)
        }
        #expect(vm.holdsForWelcome && vm.sessions.startQueue.held && vm.sessions.startQueue.started.isEmpty)
        #expect(Self.launch(of: sessionID) == nil, "held while the copy runs")

        gate.signal()
        try await eventuallyOnMain("the welcome step") { vm.yourPi.welcome != nil }
        let server = app.server
        try await eventuallyAsync("the restored agent to serve, signed in", timeout: .seconds(20)) { await Self.serves(id, on: server) }
        #expect(vm.yourPi.welcome != nil, "it started with the step still showing: no click")
        #expect(!vm.holdsForWelcome && !vm.sessions.startQueue.held && !vm.cannotStart.contains(id))

        let welcome = try #require(vm.yourPi.welcome)
        #expect(welcome.report.first && welcome.survey.canStartAgents && !welcome.holdsAgents && !welcome.asksToSignIn)
        let rows = PiWelcomeSheet.sections(welcome).broughtOver
        #expect(rows.contains(.init(title: "Anthropic", detail: "Signed in")))
        #expect(rows.contains(.init(title: "Groq", detail: "API key that runs a command")))
        #expect(rows.contains(.init(title: "Custom providers", detail: "local-llm")))
        #expect(rows.contains(.init(title: "Instructions", detail: "AGENTS.md, read live")))
        for secret in YourPiFixture.secrets { #expect(!String(describing: welcome).contains(secret)) }
        // Copied into Shepherd's home, subscription sign-ins included; theirs untouched.
        let auth = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: setup.pi.home.appendingPathComponent("auth.json"))) as? [String: Any])
        #expect(Set(auth.keys) == ["anthropic", "openai-codex", "openai", "google", "groq"])
        let launch = try #require(Self.launch(of: sessionID))
        #expect(launch.env["SHEPHERD_YOUR_PI_INSTRUCTIONS"] == setup.yours.standardizedFileURL.path, "it reads your instructions live")
        #expect(launch.env["PI_CODING_AGENT_DIR"] == setup.pi.home.path)
        #expect(try YourPiFixture.tree(setup.yours) == before, "your pi is byte-identical")

        vm.finishWelcome()
        #expect(vm.yourPi.welcome == nil)
    }

    /// The gate never blocks forever: a copy that overruns its deadline lets restored agents
    /// start anyway, with no welcome step.
    @Test func aCopyPastItsDeadlineNeverHoldsAgentsForever() async throws {
        try StubPi.installAsEngine()
        let setup = try Setup()
        defer { setup.remove() }
        let app = try AppHarness(pi: setup.pi)
        defer { app.stop() }
        let (space, agent) = try setup.agent()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let model = YourPiModel(pi: setup.pi, copyDeadline: .milliseconds(200), firstCopy: { _ in
            gate.wait()
            return nil
        })

        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]), restoringAgents: true,
                                     welcomingYourPi: true, yourPi: model)

        try await eventuallyAsync("the restored agent's pi to start past the deadline") { Self.launch(of: agent.agent.effectivePiSessionID) != nil }
        #expect(!vm.holdsForWelcome && !vm.sessions.startQueue.held && vm.yourPi.welcome == nil)
    }

    /// Something still missing: the default model's provider has no login, key or custom
    /// provider in Shepherd's pi. The step asks to sign in to it, but other logins came over, so
    /// restored agents don't wait for it.
    @Test func theDefaultModelsMissingProviderIsAskedForWithoutHoldingAgents() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let model = YourPiModel(pi: setup.pi)
        let holds = await model.runFirstLaunch(defaultModel: "xai/grok-fixture")
        let welcome = try #require(model.welcome)
        #expect(!holds && !welcome.holdsAgents && welcome.asksToSignIn)
        #expect(welcome.missing == ["xai"])
        #expect(PiWelcomeSheet.sections(welcome).missing == [.init(title: "xAI", detail: "Not signed in")])

        let other = try Setup()
        defer { other.remove() }
        let covered = YourPiModel(pi: other.pi)
        _ = await covered.runFirstLaunch(defaultModel: nil)
        #expect(covered.welcome?.missing.isEmpty == true, "pi's default model came over with its provider's login")
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
        try Self.requireSignIn(in: space)

        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]), restoringAgents: true, welcomingYourPi: true)

        try await eventuallyOnMain("the welcome step") { vm.yourPi.welcome != nil }
        let welcome = try #require(vm.yourPi.welcome)
        #expect(welcome.report.first && welcome.report.from == nil && PiWelcomeSheet.sections(welcome) == .init())
        #expect(welcome.holdsAgents && welcome.asksToSignIn, "the step asks to sign in, holding restored agents")
        #expect(vm.holdsForWelcome && vm.sessions.startQueue.held && vm.sessions.startQueue.started.isEmpty)
        #expect(Self.launch(of: agent.agent.effectivePiSessionID) == nil)

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
        #expect(PiWelcomeSheet.sections(welcome) == .init(environment: [.init(title: "OPENAI_API_KEY", detail: "OpenAI")]))
        #expect(!welcome.holdsAgents && !welcome.asksToSignIn && !vm.holdsForWelcome)
        vm.finishWelcome()
    }
}
