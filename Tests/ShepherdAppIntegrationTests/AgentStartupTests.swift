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
        #expect(store.loadError == nil && !store.ready)
        #expect(store.pollInterval == .milliseconds(200))
        #expect(try await creating.value == id)
        // Known to be empty from the start: the new agent's thread draws before pi answers.
        #expect(store.previewing && store.messages.isEmpty && store.snapshot?.thinking == app.settings.agentDefaults.thinking.rawValue)

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

    /// A relaunch: every restored pane still names the previous run's pi, and every agent's pi
    /// respawns at once as its layout mounts. Each thread starts quietly, a thread switched
    /// away from and back to meanwhile starts again, and all come up with their history.
    @Test func restoredAgentsStartTogetherQuietlyAfterARelaunch() async throws {
        try StubPi.installOnPath()
        let app = try AppHarness()
        defer { app.stop() }
        try Self.holdPi(in: app.dir)
        let space = Fixture.space(path: app.dir.path)
        let agents = (0..<3).map { Fixture.agent("worker \($0)", in: space, order: $0, piSession: SessionID()) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        let server = app.server

        let stores = agents.map { vm.threadStores.store(for: $0.agent.id) }
        let recorders = stores.map(ThreadRecorder.init)
        func poll(_ index: Int) -> Task<Void, Never> {
            let id = agents[index].agent.id
            return Task { await stores[index].run(request: recorders[index].forward { try await server.nativeThread(agentID: id, request: $0) }) }
        }
        var polls = agents.indices.map(poll)
        defer { polls.forEach { $0.cancel() } }
        try await eventuallyOnMain("every restored thread to show pi starting, before its pi respawns") { stores.allSatisfy(\.starting) }

        let panes = agents.map { vm.sessions.session(for: $0.piPane, in: $0.tab) }
        try await eventuallyOnMain("every restored pane to bind its new pi") { panes.allSatisfy { $0.phase == .live } }
        try await eventuallyOnMain("every thread to poll its new pi") { stores.allSatisfy(\.starting) }

        // Switching away stops a thread; switching back polls it again.
        polls[0].cancel()
        stores[0].stop()
        #expect(!stores[0].starting && stores[0].loadError == nil)
        polls[0] = poll(0)
        try await eventuallyOnMain("the thread switched back to to show pi starting") { stores[0].starting }

        Self.releasePi(in: app.dir)
        try await eventuallyOnMain("every restored thread to come up", timeout: .seconds(20)) { stores.allSatisfy(\.ready) }
        for (store, recorder) in zip(stores, recorders) {
            #expect(!store.starting && store.loadError == nil && !store.messages.isEmpty)
            #expect(recorder.errorsShown.isEmpty, "no poll ever found the thread showing an error")
            #expect(!recorder.answers.contains(NativeThreadCode.unavailable))
        }
    }

    /// A thread on screen comes up the moment the server says its pi serves: this store never
    /// polls on its own, so only that signal can bring it up.
    @Test func aThreadComesUpTheMomentItsPiServesWithoutWaitingForAPoll() async throws {
        try StubPi.installOnPath()
        let app = try AppHarness()
        defer { app.stop() }
        try Self.holdPi(in: app.dir)
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("worker", in: space, piSession: SessionID())
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let store = NativeThreadStore { _ in
            let (cancelled, continuation) = AsyncStream<Void>.makeStream()
            for await _ in cancelled {}
            continuation.finish()
            throw CancellationError()
        }
        vm.threadStores.install(store, for: agent.agent.id)
        let server = app.server, id = agent.agent.id
        let polling = Task { await store.run { try await server.nativeThread(agentID: id, request: $0) } }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to show pi starting") { store.starting }
        let pane = vm.sessions.session(for: agent.piPane, in: agent.tab)
        try await eventuallyOnMain("the pane to bind its pi") { pane.phase == .live }

        Self.releasePi(in: app.dir)

        try await eventuallyOnMain("the thread to come up", timeout: .seconds(20)) { store.ready }
        #expect(!store.starting && store.loadError == nil && !store.messages.isEmpty)
    }

    /// The stub pi's history, as pi would have written it into the agent's session file.
    private static func writeStubHistory(sessionID: String, cwd: String) throws {
        let directory = PiSessionFile.projectDirectory(forCwd: cwd)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"session","version":3,"id":"\#(sessionID)","timestamp":"2026-09-24T00:00:00.000Z","cwd":"\#(PiSessionFile.realPath(cwd))"}"#,
            #"{"type":"message","id":"e0","parentId":null,"timestamp":"2026-09-24T00:00:01.000Z","message":{"role":"user","content":"Hello!","timestamp":1733234567890}}"#,
            #"{"type":"message","id":"e1","parentId":"e0","timestamp":"2026-09-24T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Hello! How can I help?"}],"provider":"anthropic","model":"claude-sonnet-4-20250514","stopReason":"stop","timestamp":1733234567891}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: directory.appendingPathComponent("2026-09-24T00-00-00-000Z_\(sessionID).jsonl"))
    }

    /// A relaunched agent's thread shows its history from pi's session file while pi boots,
    /// not live, and pi's first snapshot then lands on the same rows: the thread never empties.
    @Test func aRestoredThreadShowsItsHistoryFromDiskUntilPiServesTheSameRows() async throws {
        try StubPi.installOnPath()
        let app = try AppHarness()
        defer { app.stop() }
        try Self.holdPi(in: app.dir)
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("worker", in: space, piSession: SessionID())
        try Self.writeStubHistory(sessionID: agent.agent.effectivePiSessionID, cwd: space.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let store = vm.threadStores.store(for: agent.agent.id)
        let server = app.server, id = agent.agent.id
        let preview = PiSessionFile.previewLoader(sessionID: agent.agent.effectivePiSessionID, cwd: space.path)
        let polling = Task { await store.run(request: { try await server.nativeThread(agentID: id, request: $0) }, preview: preview) }
        defer { polling.cancel(); store.stop() }

        try await eventuallyOnMain("the thread to show its history from disk") { store.previewing && !store.rows.isEmpty }
        #expect(!store.ready && !store.supports("send") && store.loadError == nil)
        #expect(store.snapshot?.model == "anthropic/claude-sonnet-4-20250514")
        let fromDisk = store.rows.map(\.id)
        @MainActor final class Shown { var rows: [[String]] = [] }
        let shown = Shown()
        let watching = Task { @MainActor in
            while !Task.isCancelled {
                shown.rows.append(store.rows.map(\.id))
                await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
                    withObservationTracking { _ = store.rows } onChange: { Task { @MainActor in changed.resume() } }
                }
            }
        }
        defer { watching.cancel() }
        let pane = vm.sessions.session(for: agent.piPane, in: agent.tab)
        try await eventuallyOnMain("the pane to bind its pi") { pane.phase == .live }

        Self.releasePi(in: app.dir)

        try await eventuallyOnMain("pi's snapshot to replace the disk's", timeout: .seconds(20)) { store.ready }
        #expect(!store.previewing && store.rows.map(\.id) == fromDisk)
        #expect(store.messages.map(\.entryID) == ["user:1733234567890", "assistant:1733234567891"])
        #expect(shown.rows.allSatisfy { $0 == fromDisk }, "the rows never changed on the way: \(shown.rows)")
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
