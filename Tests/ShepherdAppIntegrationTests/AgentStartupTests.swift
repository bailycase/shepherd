import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A new agent's thread while its pi boots, through the real view model and the stub pi on
/// PATH (launched the way the app launches pi). The stub holds its startup until the test
/// creates its gate file, so the window a slow pi leaves is as wide as the test needs.
@Suite("Agent startup", .mainActorExclusive)
@MainActor
struct AgentStartupTests {
    private static let gate = "release-pi"

    /// Makes every stub pi started in `dir` from now on wait for the gate (then exit with
    /// `exit`, when given) before it reads anything.
    private static func holdPi(in dir: URL, exit: Int? = nil) throws {
        let config: [String: Any] = exit.map { ["gate": gate, "exit": $0] } ?? ["gate": gate]
        try JSONSerialization.data(withJSONObject: config).write(to: dir.appendingPathComponent("stub-pi-startup.json"))
    }

    private static func releasePi(in dir: URL) {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(gate).path, contents: nil)
    }

    /// ⌘N's agent, started in the background (⌘N itself would focus the window).
    private func quickCreate(_ vm: ShepherdViewModel, in space: Space, app: AppHarness) -> Task<AgentID, Error> {
        let config = ShepherdViewModel.quickAgentConfig(for: space, defaults: app.settings.agentDefaults)
        return Task { try await vm.startAgent(config, selectAfter: false) }
    }

    @Test func aNewAgentsThreadShowsStartingWithoutAnErrorAndSendsOnceReady() async throws {
        try StubPi.installOnPath()
        let app = try AppHarness()
        defer { app.stop() }
        try Self.holdPi(in: app.dir)
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))

        let creating = quickCreate(vm, in: space, app: app)
        // The thread polls from the moment the agent appears, as its view does: before its pi
        // is even bound to the pane.
        try await eventuallyOnMain("the new agent to appear") { vm.state.agents.count == 1 }
        let id = try #require(vm.state.agents.first?.id)
        let store = vm.threadStores.store(for: id)
        let recorder = ThreadRecorder(store)
        let server = app.server
        let polling = Task { await store.run(request: recorder.forward { try await server.nativeThread(agentID: id, request: $0) }) }
        defer { polling.cancel(); store.stop() }

        try await eventuallyOnMain("the thread to show pi starting") { store.starting }
        #expect(store.loadError == nil && !store.ready && store.snapshot == nil)
        #expect(store.pollInterval == .milliseconds(200))
        #expect(try await creating.value == id)

        store.draft = "hello while starting"
        #expect(store.acceptsSend)
        let sending = Task { await store.send() }
        try await eventuallyOnMain("the send to wait for pi") { store.busy }
        #expect(store.draft == "hello while starting" && store.sentCount == 0)

        Self.releasePi(in: app.dir)
        await sending.value

        #expect(store.sentCount == 1 && store.draft.isEmpty && store.notice == nil)
        #expect(store.ready && !store.starting && store.loadError == nil)
        try await eventuallyAsync("pi to receive the message sent while it started", timeout: .seconds(20)) {
            guard case .snapshot(let snapshot)? = try? await server.nativeThread(agentID: id, request: .snapshot()) else { return false }
            return snapshot.messages.contains { $0.role == "user" && $0.blocks.contains { $0.text == "hello while starting" } }
        }
        #expect(recorder.errorsShown.isEmpty, "no poll ever found the thread showing an error")
        #expect(recorder.answers.contains(NativeThreadCode.starting))
        #expect(!recorder.answers.contains(NativeThreadCode.unavailable))
        let firstSnapshot = try #require(recorder.answers.firstIndex(of: "snapshot"))
        let send = try #require(recorder.requests.firstIndex { if case .send = $0 { true } else { false } })
        #expect(send > firstSnapshot, "nothing is dispatched before pi serves the thread")
    }

    /// pi not installed, or a broken config: the launch ends in the real error (the pane's
    /// exit, then the agent retired as always), never an endless start.
    @Test func aPiThatExitsWhileStartingEndsInItsErrorNotAnEndlessStart() async throws {
        try StubPi.installOnPath()
        let app = try AppHarness()
        defer { app.stop() }
        try Self.holdPi(in: app.dir, exit: 127)
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))

        let creating = quickCreate(vm, in: space, app: app)
        try await eventuallyOnMain("the new agent to appear") { vm.state.agents.count == 1 }
        let agent = try #require(vm.state.agents.first)
        let tab = try #require(vm.state.tabs.first { $0.id == agent.tabID })
        let leaf = try #require(agent.paneID.flatMap { tab.layout.leaf(withID: $0) })
        let pane = vm.sessions.session(for: leaf, in: tab)
        let store = vm.threadStores.store(for: agent.id)
        let server = app.server, id = agent.id
        let polling = Task { await store.run { try await server.nativeThread(agentID: id, request: $0) } }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to show pi starting") { store.starting }
        _ = try await creating.value

        Self.releasePi(in: app.dir)

        try await eventuallyOnMain("the pane to show pi's exit", timeout: .seconds(20)) { pane.phase == .exited(127) }
        try await eventuallyOnMain("the agent to be retired") { server.state.agents.isEmpty && vm.state.agents.isEmpty }
        // The retirement reaches the thread with the server's broadcast (its store is pruned) or
        // the next poll, whichever lands first.
        try await eventuallyOnMain("the retired agent's thread to stop starting") { !store.starting }
        let error = await #expect(throws: RemoteHostClientError.self) { _ = try await server.nativeThread(agentID: id, request: .snapshot()) }
        guard case .rejected(NativeThreadCode.unavailable, _)? = error else { Issue.record("got \(String(describing: error))"); return }
    }

    /// Only a pi that was serving and went away is a lost connection.
    @Test func aLiveThreadWhosePiDiesShowsTheLostConnection() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = try await app.liveAgent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let store = vm.threadStores.store(for: agent.agent.id)
        let server = app.server, id = agent.agent.id
        let polling = Task { await store.run { try await server.nativeThread(agentID: id, request: $0) } }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to connect") { store.ready }

        await store.send(text: "die")

        try await eventuallyAsync("the lost connection to show", timeout: .seconds(20)) {
            await store.refresh()
            return store.loadError != nil
        }
        #expect(!store.starting)
    }

    /// A remote client watching a host's agent start sees the same quiet start, and its send
    /// waits for the host's pi.
    @Test func aRemoteAgentStartingOnItsHostIsStartingOnTheClient() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        try Self.holdPi(in: remote.host.dir)
        let space = Fixture.space(path: remote.host.dir.path)
        let agent = try await remote.host.liveAgent(in: space)
        try await remote.host.server.putState(Fixture.state(spaces: [space], agents: [agent]))
        let vm = try await local.start()
        let connection = try await remote.connect(local.remoteHosts)
        let ref = RemoteAgentRef(hostID: connection.id, agentID: agent.agent.id)
        let store = vm.remoteThreadStores.store(for: ref)
        let hosts = local.remoteHosts
        let polling = Task { await store.run { try await hosts.nativeThread(ref, request: $0) } }
        defer { polling.cancel(); store.stop() }

        try await eventuallyOnMain("the remote thread to show pi starting") { store.starting }
        #expect(store.loadError == nil && !store.ready)
        store.draft = "hello from the client"
        let sending = Task { await store.send() }
        try await eventuallyOnMain("the send to wait for the host's pi") { store.busy }

        Self.releasePi(in: remote.host.dir)
        await sending.value

        #expect(store.sentCount == 1 && store.draft.isEmpty && store.loadError == nil)
        let host = remote.host.server, id = agent.agent.id
        try await eventuallyAsync("the host's pi to receive the message", timeout: .seconds(20)) {
            guard case .snapshot(let snapshot)? = try? await host.nativeThread(agentID: id, request: .snapshot()) else { return false }
            return snapshot.messages.contains { $0.role == "user" && $0.blocks.contains { $0.text == "hello from the client" } }
        }
    }
}

/// Stands between a thread store and its host: records every request, every answer (the
/// failure code, or the result's kind), and whether the store showed an error when it polled
/// (which is the state its previous answer left).
@MainActor
final class ThreadRecorder {
    private weak var store: NativeThreadStore?
    private(set) var requests: [NativeThreadRequest] = []
    private(set) var answers: [String] = []
    private(set) var errorsShown: [String] = []

    init(_ store: NativeThreadStore) { self.store = store }

    func forward(_ request: @escaping NativeThreadStore.Request) -> NativeThreadStore.Request {
        { [self] value in
            if let error = store?.loadError { errorsShown.append(error) }
            requests.append(value)
            do {
                let result = try await request(value)
                switch result {
                case .failure(let code, _): answers.append(code)
                case .snapshot: answers.append("snapshot")
                case .unchanged: answers.append("unchanged")
                case .accepted: answers.append("accepted")
                case .transcript: answers.append("transcript")
                }
                return result
            } catch {
                if case RemoteHostClientError.rejected(let code, _) = error { answers.append(code) } else { answers.append("\(error)") }
                throw error
            }
        }
    }
}
