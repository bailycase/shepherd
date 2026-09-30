import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The Speed control through the real view model, server and launch path (the stub pi stands in
/// for the engine, launched the way the app launches pi; the real extension runs in
/// `ServiceTierEngineTests` and `Tests/Extensions/service-tier.test.mjs`): a new thread takes
/// Settings' speed, its pi is told where its tier file is, the thread offers Speed on an OpenAI
/// model, and ⌘K's Toggle fast mode flips it on the host.
@Suite("Service tier in the app", .serialized, .mainActorExclusive)
@MainActor
struct ServiceTierFlowTests {
    /// A workspace whose stub pi reports an OpenAI model (`stub-pi-startup.json`, read from its cwd).
    private func workspace(_ model: String = #"{"provider":"openai","id":"gpt-6-luna","api":"openai-responses"}"#) async throws
        -> (app: AppHarness, vm: ShepherdViewModel, space: Space) {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        try Data(#"{"model":\#(model)}"#.utf8).write(to: app.dir.appendingPathComponent("stub-pi-startup.json"))
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))
        return (app, vm, space)
    }

    private func config(_ space: Space, in app: AppHarness, tier: ServiceTier? = nil) -> NewAgentConfig {
        var config = NewAgentConfig(spaceID: space.id, workingDirectory: app.dir.path, model: nil, thinking: .medium, initialPrompt: nil)
        config.serviceTier = tier
        return config
    }

    @Test func aNewThreadTakesSettingsSpeedAndItsPiIsToldWhereItsTierFileIs() async throws {
        let (app, vm, space) = try await workspace()
        defer { app.stop() }
        app.settings.defaultServiceTier = .fast
        let id = try await vm.startAgent(config(space, in: app), selectAfter: false)
        let agent = try #require(vm.state.agents.first { $0.id == id })
        #expect(agent.serviceTier == .fast, "a new thread starts on Settings' speed")
        #expect(ServiceTierFile.read(for: id, in: app.server.pi.files) == .fast, "written before its pi started")

        let sessionID = agent.effectivePiSessionID
        try await eventuallyAsync("the stub engine to record the launch") {
            StubPi.launches().contains { $0.argv.contains(sessionID) }
        }
        let launch = try #require(StubPi.launches().first { $0.argv.contains(sessionID) })
        let file = try #require(ServiceTierFile.url(for: id, in: app.server.pi.files))
        #expect(launch.env["SHEPHERD_EXT_SERVICE_TIER"] == file.path)
        #expect(launch.argv.contains(ServiceTierExtension.path(in: app.server.pi.files)), "an agent's own pi loads the extension")

        // The next thread is another choice: Settings back to Standard, and a thread's own override wins.
        app.settings.defaultServiceTier = .standard
        let plain = try await vm.startAgent(config(space, in: app), selectAfter: false)
        #expect(vm.state.agents.first { $0.id == plain }?.serviceTier == .standard)
        app.settings.defaultServiceTier = .fast
        let pinned = try await vm.startAgent(config(space, in: app, tier: .standard), selectAfter: false)
        #expect(vm.state.agents.first { $0.id == pinned }?.serviceTier == .standard, "the caller's tier beats the setting")
        #expect(vm.state.agents.first { $0.id == id }?.serviceTier == .fast, "and a thread keeps its own")
    }

    @Test func theToggleFastModeCommandFlipsTheThreadOnScreenAndTheHost() async throws {
        let (app, vm, space) = try await workspace()
        defer { app.stop() }
        let id = try await vm.startAgent(config(space, in: app), selectAfter: false)
        vm.selectAgent(id)
        let store = vm.threadStores.store(for: id)
        let server = app.server
        let polling = Task { await store.run(request: { try await server.nativeThread(agentID: id, request: $0) }) }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to offer a speed", timeout: .seconds(30)) { store.ready && store.offersServiceTier }
        #expect(store.serviceTiers == [.standard, .fast] && store.serviceTier == .standard)

        func toggle() throws -> PaletteItem {
            let item = try #require(vm.paletteItems.first { $0.id == "action.fastMode" }, "the palette lists Toggle fast mode")
            vm.runPaletteItem(item)
            return item
        }
        let item = try toggle()
        #expect(item.title == "Toggle fast mode" && item.section == .thisThread)
        try await eventuallyOnMain("the thread to say Fast") { store.serviceTier == .fast }
        #expect(app.server.state.agents.first?.serviceTier == .fast)
        #expect(ServiceTierFile.read(for: id, in: server.pi.files) == .fast)

        _ = try toggle()
        try await eventuallyOnMain("the thread to say Standard") { store.serviceTier == .standard }
        #expect(app.server.state.agents.first?.serviceTier == .standard)
        #expect(ServiceTierFile.read(for: id, in: server.pi.files) == .standard)
    }

    @Test func aModelThatOffersNoTierHasNoToggleCommand() async throws {
        let (app, vm, space) = try await workspace()
        defer { app.stop() }
        let id = try await vm.startAgent(config(space, in: app, tier: .fast), selectAfter: false)
        vm.selectAgent(id)
        let store = vm.threadStores.store(for: id)
        let server = app.server
        let polling = Task { await store.run(request: { try await server.nativeThread(agentID: id, request: $0) }) }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to offer a speed", timeout: .seconds(30)) { store.ready && store.offersServiceTier }
        #expect(vm.paletteItems.contains { $0.id == "action.fastMode" })

        // An Anthropic model (the stub takes that one): no tier, no command, and Fast stays the
        // thread's own for when it comes back to a model that takes one.
        await store.setModel("anthropic/claude-opus-4-5")
        try await eventuallyOnMain("the model to change and the control to go") { store.model == "anthropic/claude-opus-4-5" && !store.offersServiceTier }
        #expect(!vm.paletteItems.contains { $0.id == "action.fastMode" })
        #expect(store.serviceTier == .fast && app.server.state.agents.first?.serviceTier == .fast)
    }
}
