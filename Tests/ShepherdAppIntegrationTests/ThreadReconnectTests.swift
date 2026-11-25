import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A thread open on the background host while the host goes away (an update's relaunch) and comes back: the banner says what
/// happened, clears on its own when the host returns, and Reconnect brings the host's connection back instead of asking a dead one.
@Suite("A thread across a host restart", .mainActorExclusive)
@MainActor
struct ThreadReconnectTests {
    @MainActor private struct Open {
        let setup: LocalHostRoutingTests.Setup
        let id: AgentID
        let store: NativeThreadStore
        let polling: Task<Void, Never>
        var socket: String { setup.host.dir.appendingPathComponent("h.sock").path }

        func stop() {
            polling.cancel()
            store.stop()
            setup.stop()
        }
    }

    /// A thread of the host's, polling through the app's own request path (`ShepherdViewModel.nativeThread`), loaded.
    private func openThread() async throws -> Open {
        try StubPi.installAsEngine()
        let setup = try await LocalHostRoutingTests.setUp(agents: ["Fix the login redirect"])
        let id = try #require(setup.host.server.state.agents.first?.id)
        let vm = setup.vm
        let store = vm.threadStores.store(for: id)
        let polling = Task { await store.run(request: { try await vm.nativeThread(id, request: $0) }) }
        let open = Open(setup: setup, id: id, store: store, polling: polling)
        do {
            try await eventuallyOnMain("the thread to load", timeout: .seconds(30)) { store.ready }
        } catch {
            open.stop()
            throw error
        }
        return open
    }

    @Test func theBannerClearsByItselfWhenTheHostComesBack() async throws {
        let open = try await openThread()
        defer { open.stop() }
        open.setup.host.server.stopLocalListener()
        try await eventuallyOnMain("the thread to lose the host") { open.store.loadError != nil }
        #expect(open.store.loadErrorKind == .connection)
        #expect(open.store.loadErrorTitle == NativeThreadStore.lostConnectionTitle)

        try open.setup.host.server.startLocalListener(path: open.socket)
        try await eventuallyOnMain("the banner to clear with no click") { open.store.loadError == nil && open.store.ready }
    }

    @Test func reconnectBringsTheHostBackAndThePullAnswers() async throws {
        let open = try await openThread()
        defer { open.stop() }
        open.setup.host.server.stopLocalListener()
        try await eventuallyOnMain("the thread to lose the host") { open.store.loadError != nil }
        // While the host is away every try fails the same way: nothing to ask.
        await open.store.reconnect()
        #expect(open.store.loadErrorKind == .connection && !open.store.ready)

        try open.setup.host.server.startLocalListener(path: open.socket)
        // No waiting for the app's own retry: Reconnect ends with the host connected and the thread pulled.
        await open.store.reconnect()
        #expect(open.setup.hosts.localHost?.phase == .connected)
        #expect(open.store.ready && open.store.loadError == nil)
    }

    @Test func theHostsOwnRefusalIsNamedByItsCode() async throws {
        let open = try await openThread()
        defer { open.stop() }
        // A thread the host no longer has: it answers, so the connection is fine.
        let gone = AgentID(rawValue: "gone")
        let vm = open.setup.vm
        let store = vm.threadStores.store(for: gone)
        let polling = Task { await store.run(request: { try await vm.nativeThread(gone, request: $0) }) }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to show the host's refusal") { store.loadError != nil }
        #expect(store.loadErrorKind == .host(code: NativeThreadCode.unavailable))
        #expect(store.loadErrorTitle == "The agent process isn't running.")
        #expect(open.setup.hosts.localHost?.phase == .connected, "the connection was never lost")
    }

    @Test func aDraftWithItsImageSurvivesTheOutageAndGoesOnceTheHostIsBack() async throws {
        let open = try await openThread()
        defer { open.stop() }
        let input = ThreadInput()
        let image = ImageAttachment(name: "shot.png", image: NativeImage(mimeType: "image/png", data: Data([1, 2, 3]), name: "shot.png"))
        input.attachments.add([(image.name, image)])
        open.store.draft = "look at this"
        open.setup.host.server.stopLocalListener()
        try await eventuallyOnMain("the thread to lose the host") { open.store.loadError != nil }

        #expect(await ComposerImageCapture.send(store: open.store, input: input, delivery: .followUp) == false)
        #expect(open.store.draft == "look at this" && input.attachments.items.map(\.name) == ["shot.png"])
        #expect(open.store.submissions.isEmpty)

        try open.setup.host.server.startLocalListener(path: open.socket)
        await open.store.reconnect()
        try await eventuallyOnMain("the thread to be ready to send") { open.store.supports("sendImages") }
        #expect(await ComposerImageCapture.send(store: open.store, input: input, delivery: .followUp))
        #expect(open.store.draft.isEmpty && input.attachments.isEmpty)
    }
}
