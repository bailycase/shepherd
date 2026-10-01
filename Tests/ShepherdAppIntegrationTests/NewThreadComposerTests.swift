import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A creation choice must reach the first turn, not become available only after creation.
@Suite("New thread composer", .mainActorExclusive)
@MainActor
struct NewThreadComposerTests {
    nonisolated static let models = ModelListing(models: ["openai/gpt-5", "fixture/plain"], defaultModel: "openai/gpt-5",
                                     withoutThinking: ["fixture/plain"],
                                     thinkingLevels: ["openai/gpt-5": ["off", "low", "medium", "high", "xhigh", "max"]],
                                     serviceTiers: ["openai/gpt-5": ["standard", "fast"]], contexts: ["openai/gpt-5": "400K"])

    @Test func creationKeepsTheModelsFullThinkingSetAndTheChosenSpeed() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness(modelCatalog: { Self.models })
        defer { app.stop() }
        app.settings.defaultThinking = .max
        app.settings.defaultServiceTier = .fast
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))
        vm.openNewThread()
        let draft = vm.newThread
        try await eventuallyOnMain("creation capabilities to load") { !draft.loadingDefaults }
        #expect(draft.thinkingLevels(vm) == [.off, .low, .medium, .high, .xhigh, .max])
        #expect(draft.serviceTiers(vm) == [.standard, .fast] && draft.serviceTier == .fast)
        #expect(draft.catalog?.model("openai/gpt-5")?.thinking == "Off · Low · Medium · High · Extra high · Max")
        #expect(draft.catalog?.model("openai/gpt-5")?.context == "400K")
        draft.setModel("fixture/plain")
        #expect(draft.thinkingLevels(vm).isEmpty && draft.serviceTiers(vm).isEmpty)
        #expect(draft.thinkingLevel(vm) == .off && draft.thinking == .max,
                "a non-reasoning model starts with Off without erasing the choice for a later reasoning model")
        draft.setModel("openai/gpt-5")
        draft.setThinking(.minimal)
        #expect(draft.thinkingLevel(vm) == .low, "a null mapping clamps to the nearest supported level")
        draft.setThinking(.xhigh)
        draft.setServiceTier(.standard)
        vm.openNewThread()
        try await eventuallyOnMain("the reopened draft to load") { !draft.loadingDefaults }
        #expect(draft.thinking == .xhigh && draft.serviceTier == .standard, "explicit picks survive reopening")
        draft.prompt = "tools:0 First task"
        draft.send(vm)
        try await eventuallyOnMain("creation to finish") { vm.selectedAgentID != nil && !draft.starting }
        let agent = try #require(vm.state.agents.first)
        #expect(agent.thinkingLevel == .xhigh && agent.serviceTier == .standard)
        #expect(ServiceTierFile.read(for: agent.id, in: app.server.pi.files) == .standard)
    }

    @Test func anUnavailableCatalogDoesNotGuessAwayTheRequestedThinkingLevel() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness(modelCatalog: { ModelListing(models: [], defaultModel: nil) })
        defer { app.stop() }
        app.settings.defaultThinking = .max
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))
        vm.openNewThread()
        let draft = vm.newThread
        try await eventuallyOnMain("the empty catalog to finish loading") { !draft.loadingDefaults }
        #expect(draft.thinkingLevel(vm) == .max, "the chip agrees with the level creation sends")
        draft.prompt = "tools:0 First task"
        draft.send(vm)
        try await eventuallyOnMain("creation to finish without capabilities") { vm.selectedAgentID != nil && !draft.starting }
        #expect(vm.state.agents.first?.thinkingLevel == .max, "pi, not a guessed Off–High set, resolves an unavailable model")
    }

    @Test func aRemoteCreationUsesHostDefaultsAndSendsItsSpeedBeforeTheFirstTurn() async throws {
        try StubPi.installAsEngine()
        let local = try AppHarness(), remote = try RemoteHostHarness(modelCatalog: { Self.models })
        defer { local.stop(); remote.stop() }
        remote.host.settings.defaultThinking = .max
        remote.host.settings.defaultServiceTier = .fast
        let space = Fixture.space("remote", path: remote.host.dir.path)
        try await remote.host.start(with: ShepherdState(spaces: [space]))
        let vm = try await local.start()
        let connection = try await remote.connect(local.remoteHosts)
        vm.openNewThread(in: space.id, hostID: connection.id)
        let draft = vm.newThread
        try await eventuallyOnMain("host capabilities to load") { !draft.loadingDefaults }
        #expect(draft.thinking == .max && draft.serviceTier == .fast)
        #expect(draft.thinkingLevels(vm) == [.off, .low, .medium, .high, .xhigh, .max])
        #expect(draft.serviceTiers(vm) == [.standard, .fast])
        draft.setServiceTier(.standard)
        draft.prompt = "tools:0 First remote task"
        draft.send(vm)
        try await eventuallyOnMain("remote creation to finish") { vm.selectedRemoteAgent != nil && !draft.starting }
        let agent = try #require(remote.host.server.state.agents.first)
        #expect(agent.thinkingLevel == .max && agent.serviceTier == .standard, "the page overrides the host's Fast default before launch")
        #expect(ServiceTierFile.read(for: agent.id, in: remote.host.server.pi.files) == .standard)
    }

    @Test func anOlderHostHidesCreationSpeedAndRefusesAnExplicitOverride() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness(modelCatalog: { Self.models })
        defer { local.stop(); remote.stop() }
        remote.host.server.advertisedCapabilities = RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.createAgentServiceTierCapability }
        let space = Fixture.space("remote", path: remote.host.dir.path)
        try await remote.host.start(with: ShepherdState(spaces: [space]))
        let vm = try await local.start()
        let connection = try await remote.connect(local.remoteHosts)
        vm.openNewThread(in: space.id, hostID: connection.id)
        try await eventuallyOnMain("older host defaults to load") { !vm.newThread.loadingDefaults }
        #expect(vm.newThread.serviceTiers(vm).isEmpty)
        let error = await #expect(throws: RemoteHostClientError.self) {
            try await local.remoteHosts.createAgent(hostID: connection.id, spaceID: space.id, cwd: nil, model: nil,
                                                    thinking: nil, initialPrompt: "task", serviceTier: .fast)
        }
        #expect(error?.rejectionCode == "update_required")
        #expect(remote.host.server.state.agents.isEmpty)
    }
}
