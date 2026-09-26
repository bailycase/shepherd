import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Images attached on the New thread page go to pi with the opening prompt, on this Mac and on
/// a host, and a host from before `agent.create.images.v1` is refused before anything is made.
@Suite("New thread attachments", .mainActorExclusive)
@MainActor
struct NewThreadAttachTests {
    private static let png = NativeImage(mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    private static let jpeg = NativeImage(mimeType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF, 0xE0]))

    /// Attaches as a drop does once `AppImageDrop` has resized the files (the drop directory is
    /// the user's, so the files are not written).
    private static func attach(_ draft: NewThreadState) {
        draft.attachments.add([("screen.png", ImageAttachment(name: "screen.png", image: png)),
                               ("photo.jpg", ImageAttachment(name: "photo.jpg", image: jpeg))])
    }

    /// Waits until pi has answered the opening prompt and returns it as pi's own user message,
    /// not the pending row. (The stub's session opens with a history of its own.)
    private static func firstMessage(_ server: SessionServer, agentID: AgentID, prompt: String) async throws -> NativeThreadMessage {
        var found: NativeThreadMessage?
        try await eventuallyAsync("pi to answer the opening prompt", timeout: .seconds(20)) {
            guard case .snapshot(let snapshot)? = try? await server.nativeThread(agentID: agentID, request: .snapshot()),
                  snapshot.messages.contains(where: { $0.role == "assistant" && $0.blocks.contains { $0.text == "Reply to \(prompt)" } })
            else { return false }
            found = snapshot.messages.first { $0.role == "user" && $0.blocks.first?.text == prompt }
            return found != nil
        }
        return try #require(found)
    }

    @Test func aNewThreadOnThisMacSendsItsImagesWithTheOpeningPrompt() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))

        vm.openNewThread()
        let draft = vm.newThread
        #expect(draft.place == NewThreadPlace(host: nil, space: space.id))
        draft.prompt = "tools:0 Match this layout"
        Self.attach(draft)
        #expect(draft.attachments.items.map(\.name) == ["screen.png", "photo.jpg"])
        #expect(draft.blocker(vm) == nil && draft.notice(vm) == nil)
        draft.send(vm)

        try await eventuallyOnMain("the new agent to be selected") { vm.selectedAgentID != nil && !draft.starting }
        let id = try #require(vm.selectedAgentID)
        #expect(draft.prompt.isEmpty && draft.attachments.isEmpty, "the draft and its images went with the thread")
        let preview = vm.threadStores.store(for: id).rows.flatMap { $0.turn.messages }.first { $0.role == "user" }
        #expect(preview?.blocks.filter { $0.kind == .unsupportedImage }.count == 2, "the row shows the images while pi starts")

        let message = try await Self.firstMessage(app.server, agentID: id, prompt: "tools:0 Match this layout")
        #expect(message.blocks.filter { $0.kind == .unsupportedImage }.count == 2, "pi received both images in its first message")
    }

    @Test func aNewThreadOnAHostSendsItsImagesWithTheOpeningPrompt() async throws {
        try StubPi.installAsEngine()
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let space = Fixture.space("remote", path: remote.host.dir.path)
        try await remote.host.start(with: ShepherdState(spaces: [space]))
        let vm = try await local.start()
        let connection = try await remote.connect(local.remoteHosts)
        #expect(connection.supportsCreateAgentImages)

        vm.openNewThread(in: space.id, hostID: connection.id)
        let draft = vm.newThread
        draft.prompt = "tools:0 Match this layout"
        Self.attach(draft)
        try await eventuallyOnMain("the host's defaults to load") { draft.blocker(vm) == nil }
        draft.send(vm)

        try await eventuallyOnMain("the new remote agent to be selected") { vm.selectedRemoteAgent != nil && !draft.starting }
        let target = try #require(vm.selectedRemoteAgent)
        #expect(draft.error == nil && draft.attachments.isEmpty)
        #expect(local.server.state.agents.isEmpty)

        let message = try await Self.firstMessage(remote.host.server, agentID: target.agentID, prompt: "tools:0 Match this layout")
        #expect(message.blocks.filter { $0.kind == .unsupportedImage }.count == 2, "the host's pi received both images")
    }

    /// An older host would take the prompt and drop the images, so neither the page nor the
    /// client sends it: Send says why, and nothing reaches the host.
    @Test func anOlderHostIsRefusedImagesBeforeAnythingIsCreated() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        remote.host.server.advertisedCapabilities = RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.createAgentImagesCapability }
        let space = Fixture.space("remote", path: remote.host.dir.path)
        // Its view model answers the page's defaults, so nothing else stands in Send's way.
        try await remote.host.start(with: ShepherdState(spaces: [space]))
        let requests = RecordedCreates()
        remote.host.server.onRemoteCreateAgent = { request, completion in
            requests.append(request)
            completion(.success(AgentID()))
        }
        let vm = try await local.start()
        let connection = try await remote.connect(local.remoteHosts)
        #expect(!connection.supportsCreateAgentImages)

        vm.openNewThread(in: space.id, hostID: connection.id)
        let draft = vm.newThread
        draft.prompt = "Match this layout"
        try await eventuallyOnMain("the host's defaults to settle") { draft.blocker(vm) == nil }
        Self.attach(draft)
        let refusal = "Update Shepherd on \(connection.config.name) to start a thread with images."
        #expect(draft.blocker(vm) == refusal && draft.notice(vm) == refusal)

        let error = await #expect(throws: RemoteHostClientError.self) {
            try await local.remoteHosts.createAgent(hostID: connection.id, spaceID: space.id, cwd: space.path, model: nil,
                                                    thinking: nil, initialPrompt: draft.prompt, initialImages: draft.attachments.images)
        }
        #expect(error?.rejectionCode == "update_required")
        #expect(requests.all.isEmpty && remote.host.server.state.agents.isEmpty)

        // Without the images the same thread starts there.
        draft.attachments.removeAll()
        #expect(draft.blocker(vm) == nil && draft.notice(vm) == nil)
    }
}
