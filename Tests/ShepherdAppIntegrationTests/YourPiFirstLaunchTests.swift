import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The first launch of a build with Shepherd's own pi, through the real view model and the stub
/// engine: the user's pi (a fixture with fake logins of every kind) is copied into a scratch
/// Shepherd home once, and the first launch's sheet says what came over. Restored agents wait for the
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
    /// available" without a login in Shepherd's home) while the sheet still shows, with no
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
        let model = YourPiModel(pi: setup.pi, firstCopy: { pi, progress in
            copying.withValue { $0 = true }
            gate.wait()
            return pi.copyYourPiOnce(progress: progress)
        })

        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]), restoringAgents: true,
                                     welcomingYourPi: true, yourPi: model)

        try await eventuallyOnMain("the copy to run with the restored agent's start asked for") {
            copying.current && vm.sessions.startQueue.waiting.contains(id)
        }
        #expect(vm.holdsForWelcome && vm.sessions.startQueue.held && vm.sessions.startQueue.started.isEmpty)
        #expect(Self.launch(of: sessionID) == nil, "held while the copy runs")

        gate.signal()
        try await eventuallyOnMain("the sheet, done") { vm.yourPi.importSheet?.stage == .done }
        let server = app.server
        try await eventuallyAsync("the restored agent to serve, signed in", timeout: .seconds(20)) { await Self.serves(id, on: server) }
        #expect(vm.yourPi.importSheet != nil, "it started with the sheet still showing: no click")
        #expect(!vm.holdsForWelcome && !vm.sessions.startQueue.held && !vm.cannotStart.contains(id))

        let sheet = try #require(vm.yourPi.importSheet)
        #expect(sheet.report.first && sheet.survey.canStartAgents && sheet.missing.isEmpty && !sheet.stage.holdsAgents)
        let rows = sheet.rows
        #expect(rows.map(\.title) == ["Logins", "API keys", "Custom providers", "Default model", "Trusted folders",
                                       "Instructions, skills and prompts", "Extensions"])
        #expect(rows.allSatisfy { $0.state == .done })
        #expect(rows[0] == .init(id: "logins", title: "Logins", detail: "Anthropic, OpenAI Codex", count: "2 subscriptions", state: .done))
        #expect(rows[1] == .init(id: "apiKeys", title: "API keys", detail: "Google, Groq, OpenAI", count: "3 keys", state: .done))
        #expect(rows[2].count == "1 provider" && rows[3].count == "claude-fixture-4")
        #expect(rows[4].count == "1 folder", "the home folder's trust is never copied")
        #expect(rows[5].count == "AGENTS.md · 1 · 2" && rows[6].count == "1 found")
        for secret in YourPiFixture.secrets { #expect(!String(describing: sheet).contains(secret)) }
        // Copied into Shepherd's home, subscription sign-ins included; theirs untouched.
        let auth = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: setup.pi.home.appendingPathComponent("auth.json"))) as? [String: Any])
        #expect(Set(auth.keys) == ["anthropic", "openai-codex", "openai", "google", "groq"])
        let launch = try #require(Self.launch(of: sessionID))
        #expect(launch.env["SHEPHERD_YOUR_PI_INSTRUCTIONS"] == nil, "nothing points the agent at your pi")
        #expect(try String(contentsOf: setup.pi.home.appendingPathComponent("AGENTS.md"), encoding: .utf8).contains("FIXTURE-GLOBAL-INSTRUCTIONS"),
                "your instructions are copied into Shepherd's home, where pi reads them")
        #expect(launch.extensions.isEmpty, "your extension came over switched off")
        #expect(launch.env["PI_CODING_AGENT_DIR"] == setup.pi.home.path)
        #expect(try YourPiFixture.tree(setup.yours) == before, "your pi is byte-identical")

        vm.finishImport()
        #expect(vm.yourPi.importSheet == nil)
    }

    /// The gate never blocks forever: a copy that overruns its deadline lets restored agents
    /// start anyway, with no sheet.
    @Test func aCopyPastItsDeadlineNeverHoldsAgentsForever() async throws {
        try StubPi.installAsEngine()
        let setup = try Setup()
        defer { setup.remove() }
        let app = try AppHarness(pi: setup.pi)
        defer { app.stop() }
        let (space, agent) = try setup.agent()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let model = YourPiModel(pi: setup.pi, copyDeadline: .milliseconds(200), firstCopy: { _, _ in
            gate.wait()
            return nil
        })

        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]), restoringAgents: true,
                                     welcomingYourPi: true, yourPi: model)

        try await eventuallyAsync("the restored agent's pi to start past the deadline") { Self.launch(of: agent.agent.effectivePiSessionID) != nil }
        #expect(!vm.holdsForWelcome && !vm.sessions.startQueue.held && vm.yourPi.importSheet == nil)
    }

    /// Something still missing: a provider an agent (or the default model) uses has no login, key
    /// or custom provider in Shepherd's pi. The sheet asks for it, and only the agents that use
    /// it wait; the rest start at once.
    @Test func aMissingProviderIsAskedForAndHoldsOnlyTheAgentsThatUseIt() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let model = YourPiModel(pi: setup.pi)
        model.doneBeat = .zero
        let hold = await model.runFirstLaunch(models: ["xai/grok-fixture", "anthropic/claude-fixture-4"])
        let sheet = try #require(model.importSheet)
        #expect(sheet.stage == .missing && hold == .agents(using: ["xai"]))
        #expect(sheet.missing == [.init(id: "xai", detail: "Your pi isn’t signed in to it")])
        #expect(!sheet.allSignedIn)

        let other = try Setup()
        defer { other.remove() }
        let covered = YourPiModel(pi: other.pi)
        covered.doneBeat = .zero
        #expect(await covered.runFirstLaunch() == .none, "pi's default model came over with its provider's login")
        #expect(covered.importSheet?.stage == .done)
    }

    /// While the sheet asks for a missing provider, restored agents that use it wait (the sidebar
    /// says "waiting") and the others start; Done or Skip for now starts the rest.
    @Test func agentsWaitingOnAMissingProviderStartWhenTheSheetCloses() async throws {
        try StubPi.installAsEngine()
        let setup = try Setup()
        defer { setup.remove() }
        let app = try AppHarness(pi: setup.pi)
        defer { app.stop() }
        let (space, signedIn) = try setup.agent()
        var waiting = Fixture.agent("needs xai", in: space, cwd: space.path, piSession: SessionID())
        waiting.agent.model = "xai/grok-fixture"
        let model = YourPiModel(pi: setup.pi)
        model.doneBeat = .zero

        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [signedIn, waiting]), restoringAgents: true,
                                     welcomingYourPi: true, yourPi: model)

        try await eventuallyOnMain("the sheet to ask for xAI") { vm.yourPi.importSheet?.stage == .missing }
        try await eventuallyAsync("the signed-in agent to start") { Self.launch(of: signedIn.agent.effectivePiSessionID) != nil }
        #expect(Self.launch(of: waiting.agent.effectivePiSessionID) == nil)
        #expect(vm.sessions.startQueue.isHeld(waiting.agent.id) && !vm.sessions.startQueue.isHeld(signedIn.agent.id))
        #expect(vm.waitingForImport == [waiting.agent.id])

        vm.finishImport()
        try await eventuallyAsync("the held agent to start once the sheet closes") { Self.launch(of: waiting.agent.effectivePiSessionID) != nil }
        #expect(vm.waitingForImport.isEmpty)
    }

    /// Once the first copy has run, a launch copies nothing (a change in their pi stays there),
    /// shows no sheet, and starts restored agents at once.
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
        #expect(vm.yourPi.importSheet == nil && !vm.holdsForWelcome)
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

        try await eventuallyOnMain("the new user's sheet") { vm.yourPi.importSheet?.stage == .newUser }
        let sheet = try #require(vm.yourPi.importSheet)
        #expect(sheet.report.first && sheet.report.from == nil && sheet.stage.holdsAgents, "it asks to sign in, holding restored agents")
        #expect(vm.holdsForWelcome && vm.sessions.startQueue.held && vm.sessions.startQueue.started.isEmpty)
        #expect(vm.waitingForImport == [agent.agent.id])
        #expect(Self.launch(of: agent.agent.effectivePiSessionID) == nil)

        vm.finishImport()
        let id = agent.agent.id
        let store = vm.threadStores.store(for: id)
        let server = app.server
        let polling = Task { await store.run(request: { try await server.nativeThread(agentID: id, request: $0) }, preview: nil) }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the agent to wait on not signed in", timeout: .seconds(20)) { store.startProblem != nil }
        #expect(store.startProblem?.kind == .notSignedIn)
        #expect(vm.cannotStart.contains(id) && vm.state.agents.contains { $0.id == id }, "the agent stays, waiting")
    }

    /// A user with no pi whose Shepherd pi is already signed in (a sign-in made before this
    /// build) has nothing to be asked: no step shows, and restored agents aren't held.
    @Test func aUserWithNoPiAlreadySignedInSeesNoStep() async throws {
        let setup = try Setup(yourPi: false)
        defer { setup.remove() }
        try FileManager.default.createDirectory(at: setup.pi.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(#"{"openai": {"type": "api_key", "key": "sk-FAKE-literal-0001"}}"#.utf8)
            .write(to: setup.pi.home.appendingPathComponent("auth.json"))
        let model = YourPiModel(pi: setup.pi)

        let hold = await model.runFirstLaunch(models: ["openai/gpt-fixture"])

        #expect(hold == .none && model.importSheet == nil)
        #expect(model.survey?.canStartAgents == true && model.survey?.copied == true)
    }

    /// Keys the login shell sets count: with one, a new user has nothing to be asked, so no
    /// sheet shows and nothing waits.
    @Test func aKeyInTheEnvironmentMeansNoSheet() async throws {
        let setup = try Setup(yourPi: false, environmentKeys: ["OPENAI_API_KEY"])
        defer { setup.remove() }
        let model = YourPiModel(pi: setup.pi)
        #expect(await model.runFirstLaunch() == .none)
        #expect(model.importSheet == nil && model.survey?.canStartAgents == true)
    }

    /// The fail-closed path: an extension of the user's that they switched on and that throws as
    /// it loads is switched off for launches with pi's reason, and the agent starts again without
    /// it, with no click. The row keeps its switch on and says why it didn't load; Try again
    /// brings it back into the next launch.
    @Test func anExtensionThatThrowsAtLoadIsSwitchedOffAndTheAgentStartsWithoutIt() async throws {
        try StubPi.installAsEngine()
        let setup = try Setup()
        defer { setup.remove() }
        let report = try #require(setup.pi.copyYourPiOnce())
        let copy = try #require(report.copied(.extensions).first { $0.name == "yours" })
        try setup.pi.importedState().setExtension(copy.destination, on: true)
        let entry = setup.pi.home.appendingPathComponent(copy.destination).standardizedFileURL.path
        let before = try YourPiFixture.tree(setup.yours)
        let app = try AppHarness(pi: setup.pi)
        defer { app.stop() }
        let (space, agent) = try setup.agent()
        let id = agent.agent.id
        let sessionID = agent.agent.effectivePiSessionID

        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]), restoringAgents: true)

        let server = app.server
        try await eventuallyAsync("the agent to start again, and serve without the extension", timeout: .seconds(20)) {
            guard StubPi.launches().filter({ $0.argv.contains(sessionID) }).count == 2,
                  case .snapshot(let snapshot)? = try? await server.nativeThread(agentID: id, request: .snapshot()) else { return false }
            return snapshot.startProblem == nil
        }
        try await eventuallyOnMain("the agent to leave the can't-start list") { !vm.cannotStart.contains(id) }
        let launches = StubPi.launches().filter { $0.argv.contains(sessionID) }
        #expect(launches.count == 2, "one launch that failed, one without it: \(launches.map(\.extensions))")
        #expect(launches.first?.extensions == [entry], "it loaded while switched on")
        #expect(launches.last?.extensions == [], "and the agent started again without it")

        let state = try #require(setup.pi.importedState().state())
        #expect(state.extensionsOn == [copy.destination], "the user's choice stands")
        #expect(state.extensionFailures[copy.destination]?.reason == "your extension must never load")
        await vm.yourPi.refresh()
        let row = try #require(vm.yourPi.survey?.extensions.first { $0.copy.destination == copy.destination })
        #expect(row.on && row.failure == "your extension must never load")
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: setup.pi.files.settings)) as? [String: Any])
        #expect(settings["extensions"] == nil)

        // Try again: it is back in the next launch's settings.
        await vm.yourPi.setExtension(copy.destination, on: true)
        let again = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: setup.pi.files.settings)) as? [String: Any])
        #expect(again["extensions"] as? [String] == [entry])
        #expect(try YourPiFixture.tree(setup.yours) == before, "your pi is byte-identical")
    }
}
