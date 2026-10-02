import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Starting a thread from the New thread page with a design attached (docs/designs.md › Design
/// references): the @ picker's pick (`DesignReferenceChips.io.attach`) pins the piece, the chip
/// waits beside the prompt, and Send starts the agent and sends its opening message through the
/// host, the way a send in an existing thread does: the record fenced for pi, the copy kept, the
/// chip in the thread, the name settling as usual. A design alone is enough to send. A real server,
/// a stub pi and boards drawn off screen by the renderer.
@Suite("New thread from a design", .mainActorExclusive)
@MainActor
struct NewThreadDesignTests {
    static let hero = """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Hero</title><script src="./support.js"></script></head>
        <body>
        <x-dc>
        <helmet><style>body{margin:0}</style></helmet>
        <div style="width: 400px; height: 300px; box-sizing: border-box; padding: 24px">
        <h1 style="margin: 0; font-size: 20px">Checkout</h1>
        <button style="width: 120px; height: 40px; border-radius: 8px; background: #4f46e5" onclick="alert(1)">Pay now</button>
        </div>
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":400,"height":300}}'>
        class Component extends DCLogic { renderVals() { return {}; } }
        </script>
        </body>
        </html>
        """
    /// helmet (0), style (1), the card (2, `1`), its title (3, `1/0`) and button (4, `1/1`).
    static let button = DesignElementID("Hero.dc.html#4:1/1")!
    static let heroPath = DesignPath("Hero.dc.html")!
    static let otherPath = DesignPath("Other.dc.html")!

    enum Piece: String, CaseIterable, Sendable {
        case design, board, element
    }

    struct Workspace {
        let app: AppHarness
        let vm: ShepherdViewModel
        let design: Design
        let space: Space
    }

    /// The Design tool on, a project, and Hero drawn in a design of its own.
    static func workspace() async throws -> Workspace {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        app.settings.designToolEnabled = true
        let space = Fixture.space(path: app.dir.path)
        var drawer = Fixture.agent("Checkout", in: space, order: 1)
        let design = Design(name: "Checkout ☕️", agentID: drawer.agent.id, createdAt: 1_000)
        drawer.agent.designID = design.id
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [drawer]))
        vm.designNetwork = .none
        vm.designAttachDirectory = try makeScratchDirectory("drops")
        try await Self.draw(design, on: app.server)
        return Workspace(app: app, vm: vm, design: design, space: space)
    }

    /// Hero and a second board, drawn in `design`.
    static func draw(_ design: Design, on server: SessionServer) async throws {
        _ = try await server.createDesign(design)
        for (path, title) in [(heroPath, "Hero"), (otherPath, "Other")] {
            _ = try await server.writeDesignBoard(design.id, path: path, source: hero)
            _ = try await server.updateDesignIndex(design.id, patch: .object(["boards": .object([
                path.rawValue: .object(["x": .number(0), "y": .number(0), "w": .number(400), "h": .number(300), "title": .string(title)]),
            ])]))
        }
    }

    private func reference(_ piece: Piece, in w: Workspace) throws -> DesignReference {
        let board = piece == .design ? nil : Self.heroPath
        let element = piece == .element ? Self.button : nil
        return try #require(w.vm.designReference(w.design.id, board: board, element: element))
    }

    /// The opening message as the host's snapshot holds it: the user message that carries the
    /// design, its record, and its words. When the thread draws the piece as a chip
    /// (`designReferences`) the fence is off the text; else the text still opens with the fence
    /// pi was sent. (The stub answers by keywords, so its reply says nothing.)
    private struct Opening {
        var user: NativeThreadMessage
        var record: DesignReferenceRecord
        var words: String
        var drawnAsChip: Bool
    }

    private func opening(_ w: Workspace, agentID: AgentID) async throws -> Opening {
        var found: Opening?
        let server = w.app.server
        try await eventuallyAsync("pi to be sent the opening message", timeout: .seconds(60)) {
            guard case .snapshot(let snapshot)? = try? await server.nativeThread(agentID: agentID, request: .snapshot()) else { return false }
            for user in snapshot.messages where user.role == "user" {
                if let record = user.designReferences?.first {
                    found = Opening(user: user, record: record, words: user.blocks.first?.text ?? "", drawnAsChip: true)
                    return true
                }
                if let text = user.blocks.first(where: { DesignReferenceFence.opens($0.text) })?.text,
                   let fence = DesignReferenceFence.parse(text), let record = fence.records.first {
                    found = Opening(user: user, record: record, words: String(fence.text), drawnAsChip: false)
                    return true
                }
            }
            return false
        }
        return try #require(found)
    }

    // MARK: Starting

    /// ("tools:0" makes the stub run a turn as pi does, streaming the user's message first, which
    /// is what binds the message to the pieces the host kept and so draws its chip; a message of a
    /// design alone has no word for it, and the stub streams nothing.)
    @Test(arguments: [(Piece.board, "tools:0 Build the pay button"), (.design, ""), (.element, "tools:0 Match this button")])
    func aDesignAttachedOnTheNewThreadPageStartsTheThreadWithItsFence(piece: Piece, typed: String) async throws {
        let w = try await Self.workspace()
        defer { w.app.stop() }
        w.vm.openNewThread()
        let draft = w.vm.newThread
        try await eventuallyOnMain("the model capabilities to load") { !draft.loadingDefaults }
        let chips = try #require(draft.referenceChips, "the Design tool is on: the page has its picker")

        // The picker's pick: the piece pinned at its revision, its chip beside the prompt.
        let reference = try reference(piece, in: w)
        try await chips.io.attach(reference)
        #expect(draft.references.count == 1 && draft.references[0].reference.revision != nil)
        #expect(draft.references[0].reference.unpinned == reference)
        draft.prompt = typed
        #expect(draft.blocker(w.vm) == nil, "a design alone is a message, as it is in a thread's composer")
        #expect(draft.notice(w.vm) == nil)

        draft.send(w.vm)
        try await eventuallyOnMain("the new agent to be selected") { w.vm.selectedAgentID != nil && !draft.starting }
        let id = try #require(w.vm.selectedAgentID)
        #expect(draft.prompt.isEmpty && draft.references.isEmpty, "the draft went with the thread")

        // The agent's name is provisional, so pi's namer settles it on its first turn as usual.
        let agent = try #require(w.vm.state.agents.first { $0.id == id })
        let expectedName = typed.isEmpty ? (piece == .design ? "Checkout ☕️" : piece == .board ? "Hero" : "button “Pay now”") : typed
        #expect(agent.name == expectedName && !agent.nameIsFinal && agent.spaceID == w.space.id)

        // pi's first message holds the fenced record, then the words, as a send in an existing thread's does.
        let opening = try await opening(w, agentID: id)
        let record = opening.record
        #expect(DesignReference(string: record.ref)?.unpinned == reference)
        #expect(record.payloadID != nil, "the host kept the piece's copy")
        switch piece {
        case .design: #expect(record.board == nil && record.element == nil)
        case .board: #expect(record.board != nil && record.element == nil)
        case .element: #expect(record.elementLabel == "Pay now")
        }
        let words = opening.words.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(words == (typed.isEmpty ? "1 design reference attached." : typed + "\n\n1 design reference attached."))

        // The thread draws the chip, not the string, and the agent may read the copy.
        #expect(opening.drawnAsChip == !typed.isEmpty)
        if opening.drawnAsChip {
            let bubble = try #require(nativeUserBubbles(opening.user).first)
            #expect(bubble.references.map(\.ref) == [record.ref] && !bubble.text.contains(DesignReference.scheme))
        }
        #expect(w.app.server.state.agents.first { $0.id == id }?.designGrants.count == 1)
    }

    @Test func imagesAndADesignGoInOneOpeningMessage() async throws {
        let w = try await Self.workspace()
        defer { w.app.stop() }
        w.vm.openNewThread()
        let draft = w.vm.newThread
        try await eventuallyOnMain("the model capabilities to load") { !draft.loadingDefaults }
        try await #require(draft.referenceChips).io.attach(try reference(.board, in: w))
        let png = NativeImage(mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        draft.attachments.add([("screen.png", ImageAttachment(name: "screen.png", image: png))])
        draft.prompt = "tools:0 Match this layout"
        #expect(draft.blocker(w.vm) == nil)

        draft.send(w.vm)
        try await eventuallyOnMain("the new agent to be selected") { w.vm.selectedAgentID != nil && !draft.starting }
        let id = try #require(w.vm.selectedAgentID)
        #expect(draft.attachments.isEmpty && draft.references.isEmpty)
        let opening = try await opening(w, agentID: id)
        #expect(opening.record.board != nil && opening.words.hasPrefix("tools:0 Match this layout"))
        #expect(opening.user.blocks.filter { $0.kind == .unsupportedImage }.count == 1, "pi received the image in the same message")
    }

    // MARK: What blocks it

    @Test func withNeitherWordsNorADesignSendSaysWhatItNeeds() async throws {
        let w = try await Self.workspace()
        defer { w.app.stop() }
        w.vm.openNewThread()
        let draft = w.vm.newThread
        try await eventuallyOnMain("the model capabilities to load") { !draft.loadingDefaults }
        #expect(draft.blocker(w.vm) == "Describe the task first.")
        try await draft.referenceChips?.io.attach(try reference(.design, in: w))
        #expect(draft.blocker(w.vm) == nil)
        draft.detach(reference: try #require(draft.references.first).id)
        #expect(draft.blocker(w.vm) == "Describe the task first.", "taking the chip back leaves nothing to send")
    }

    @Test func aPieceIsAttachedOnceAndAtMostFiveGo() async throws {
        let w = try await Self.workspace()
        defer { w.app.stop() }
        w.vm.openNewThread()
        let draft = w.vm.newThread
        try await draft.attach(reference: try reference(.board, in: w), vm: w.vm)
        try await draft.attach(reference: try reference(.board, in: w), vm: w.vm)
        #expect(draft.references.count == 1, "the same piece again takes the first one's place")
        // The design, an element, and two more: five pieces; a sixth is refused with its reason.
        try await draft.attach(reference: try reference(.design, in: w), vm: w.vm)
        try await draft.attach(reference: try reference(.element, in: w), vm: w.vm)
        try await draft.attach(reference: try #require(w.vm.designReference(w.design.id, board: Self.heroPath,
                                                                            element: DesignElementID("Hero.dc.html#3:1/0"))), vm: w.vm)
        try await draft.attach(reference: try #require(w.vm.designReference(w.design.id, board: Self.heroPath,
                                                                            element: DesignElementID("Hero.dc.html#2:1"))), vm: w.vm)
        #expect(draft.references.count == 5)
        let error = await #expect(throws: DesignReferenceFailure.self) {
            try await draft.attach(reference: try #require(w.vm.designReference(w.design.id, board: Self.otherPath)), vm: w.vm)
        }
        #expect(error?.message == "A message carries at most 5 design references.")
        #expect(draft.references.count == 5)
    }

    @Test func aDesignThatIsGoneIsRefusedWithItsReason() async throws {
        let w = try await Self.workspace()
        defer { w.app.stop() }
        w.vm.openNewThread()
        let draft = w.vm.newThread
        _ = try await w.app.server.deleteDesign(w.design.id)
        let error = await #expect(throws: DesignReferenceFailure.self) {
            try await draft.attach(reference: DesignReference(designID: w.design.id, board: Self.heroPath)!, vm: w.vm)
        }
        #expect(error?.message.isEmpty == false)
        #expect(draft.references.isEmpty)
    }

    @Test func aDesignThatWentBeforeItsSendLeavesTheThreadWithItsWordsAndAnError() async throws {
        let w = try await Self.workspace()
        defer { w.app.stop() }
        w.vm.openNewThread()
        let draft = w.vm.newThread
        try await eventuallyOnMain("the model capabilities to load") { !draft.loadingDefaults }
        try await #require(draft.referenceChips).io.attach(try reference(.board, in: w))
        draft.prompt = "Build the pay button"
        _ = try await w.app.server.deleteDesign(w.design.id)

        draft.send(w.vm)
        try await eventuallyOnMain("the new agent to be selected") { w.vm.selectedAgentID != nil && !draft.starting }
        let id = try #require(w.vm.selectedAgentID)
        try await eventuallyOnMain("the failure to be said", timeout: .seconds(60)) { w.vm.remoteActionError != nil }
        #expect(w.vm.remoteActionError?.hasPrefix("The thread started, but its design didn't go: ") == true)
        #expect(w.vm.threadStores.store(for: id).draft == "Build the pay button", "what was typed is not lost")
    }

    // MARK: Another host

    @Test func aProjectOnAnotherHostTakesNoDesignAndSaysSo() async throws {
        try StubPi.installAsEngine()
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        local.settings.designToolEnabled = true
        let hostSpace = Fixture.space("remote", path: remote.host.dir.path)
        try await remote.host.start(with: ShepherdState(spaces: [hostSpace]))
        let space = Fixture.space(path: local.dir.path)
        var drawer = Fixture.agent("Checkout", in: space, order: 1)
        let design = Design(name: "Checkout", agentID: drawer.agent.id, createdAt: 1_000)
        drawer.agent.designID = design.id
        let vm = try await local.start(with: Fixture.state(spaces: [space], agents: [drawer]))
        try await Self.draw(design, on: local.server)
        let connection = try await remote.connect(local.remoteHosts)

        vm.openNewThread(in: hostSpace.id, hostID: connection.id)
        let draft = vm.newThread
        try await eventuallyOnMain("the host's defaults to load") { !draft.loadingDefaults }
        #expect(draft.referencesUnavailable == NewThreadPlaces.referencesNote, "the @ picker opens on a note, with nothing to choose")
        draft.prompt = "Build it"
        try await draft.attach(reference: try #require(vm.designReference(design.id, board: Self.heroPath)), vm: vm)
        let refusal = try #require(draft.referencesRefusal())
        #expect(refusal.hasPrefix(NewThreadPlaces.referencesNote))
        #expect(draft.blocker(vm) == refusal && draft.notice(vm) == refusal, "Send says why and nothing is created")
        #expect(remote.host.server.state.agents.isEmpty)

        // On this Mac's project the same draft goes.
        draft.choose(host: nil, space: space.id, vm: vm)
        #expect(draft.referencesUnavailable == nil)
        try await eventuallyOnMain("this Mac's defaults to load") { !draft.loadingDefaults }
        #expect(draft.blocker(vm) == nil)
    }
}
