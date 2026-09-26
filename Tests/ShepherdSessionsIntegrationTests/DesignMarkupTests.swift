import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Pencil markup against a real server: checked against the design's boards, handed to the design
/// agent fenced as data as a turn of its own, and the agent's proposals from it checked and kept
/// as comments at once, then settled once each, and sent on only when the viewer applies them.
@Suite("Design markup", .integrationTimeLimit)
struct DesignMarkupIntegrationTests {
    static let board = DesignPath("A.dc.html")!
    /// `helmet` (0), its `style` (1), then the card (2, `1`) holding a title (3, `1/0`) and a
    /// total (4, `1/1`).
    static let card = DesignCommentIntegrationTests.card
    static let cardID = DesignElementID(board: "A.dc.html", tid: 2, path: [1])!
    static let totalID = DesignElementID(board: "A.dc.html", tid: 4, path: [1, 1])!

    private func design(_ h: ScratchServer, agentID: AgentID?) async throws -> DesignID {
        let id = DesignID()
        _ = try await h.server.createDesign(Design(id: id, name: "Checkout funnel", agentID: agentID, createdAt: 1_000))
        _ = try await h.server.writeDesignBoard(id, path: Self.board, source: DesignTests.board(root: Self.card))
        _ = try await h.server.updateDesignIndex(id, patch: .object(["boards": .object([Self.board.rawValue: .object([
            "x": .number(0), "y": .number(0), "w": .number(390), "h": .number(844), "title": .string("A · Funnel first"),
        ])])]))
        return id
    }

    private func prompts(_ pi: PiAgent) -> [String] {
        pi.stdin("prompt").compactMap { $0["message"] as? String }
    }

    static let markup = DesignMarkup(strokes: [
        DesignMarkupStroke(kind: .circle, board: "A.dc.html", element: cardID, label: "whatever the iPad says", note: "thicker bars on phone"),
        DesignMarkupStroke(kind: .mark, board: "A.dc.html"),
    ])

    // MARK: Markup

    @Test func markupGoesToTheDesignAgentFencedAsATurnOfItsOwn() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let designID = try await design(h, agentID: pi.agent.id)
        _ = try await pi.ready()

        // "tools:0" has the stub answer the turn the way pi's agent loop does.
        var markup = Self.markup
        markup.strokes[0].note = "tools:0 thicker bars on phone"
        #expect(try await h.server.sendDesignMarkup(designID, markup: markup) == nil)
        let done = try await pi.snapshot("the markup's turn to settle") { s in
            !s.running && s.messages.contains { $0.origin == .designMarkup(strokes: 2, notes: 1) } && s.messages.last?.role == "assistant"
        }
        let prompt = try #require(prompts(pi).last)
        let parsed = try #require(DesignMarkupFence.parse(prompt))
        #expect(parsed.text == "Pencil markup · 2 strokes · 1 note")
        #expect(parsed.markup.strokes.map(\.kind) == [.circle, .mark])
        #expect(parsed.markup.strokes[0].note == "tools:0 thicker bars on phone")
        #expect(parsed.markup.strokes[0].label == "Checkout funnel 48,210 people", "the words are the host's reading of the board")
        #expect(parsed.markup.strokes[1].label == nil)
        let message = try #require(done.messages.first { $0.origin?.designMarkup != nil })
        #expect(message.role == "user" && message.blocks.map(\.text) == ["Pencil markup · 2 strokes · 1 note"],
                "the thread shows the line, never the fence")
        #expect(try await h.server.designComments(designID).comments.isEmpty, "markup keeps nothing on its own")
    }

    @Test func markupWithoutAnAgentToTakeItSaysWhy() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        try await h.seed(Fixture.workspace([], space: space))
        let designID = try await design(h, agentID: nil)
        #expect(try await h.server.sendDesignMarkup(designID, markup: Self.markup) == "The design has no agent.")
    }

    static let refused: [(String, DesignMarkup)] = [
        ("no marks", DesignMarkup(strokes: [])),
        ("a board the canvas doesn't have", DesignMarkup(strokes: [DesignMarkupStroke(kind: .mark, board: "B.dc.html")])),
        ("an element the board doesn't have", DesignMarkup(strokes: [
            DesignMarkupStroke(kind: .circle, board: "A.dc.html", element: DesignElementID(board: "A.dc.html", tid: 40, path: [1, 9])!),
        ])),
        ("a tid and path that disagree", DesignMarkup(strokes: [
            DesignMarkupStroke(kind: .underline, board: "A.dc.html", element: DesignElementID(board: "A.dc.html", tid: 4, path: [1, 0])!),
        ])),
        ("a note on two lines", DesignMarkup(strokes: [DesignMarkupStroke(kind: .mark, board: "A.dc.html", note: "a\nb")])),
    ]

    @Test(arguments: refused)
    func markupNamingNothingTheDesignHasIsRefusedWhole(_ name: String, _ markup: DesignMarkup) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let designID = try await design(h, agentID: pi.agent.id)
        _ = try await pi.ready()
        let before = prompts(pi).count
        do {
            _ = try await h.server.sendDesignMarkup(designID, markup: markup)
            Issue.record("\(name) was sent")
        } catch let error as DesignStoreError {
            #expect(error.code == "invalid_markup", "\(name)")
        }
        #expect(prompts(pi).count == before)
    }

    // MARK: Proposals

    @Test func theAgentsProposalsAreCheckedAgainstTheBoards() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let designID = DesignID()
        var drawer = Fixture.agent(in: space, name: "Checkout funnel")
        drawer.agent.designID = designID
        let stranger = Fixture.agent(in: space, name: "worker")
        try await h.seed(Fixture.workspace([drawer, stranger], space: space))
        _ = try await h.server.createDesign(Design(id: designID, name: "Checkout funnel", createdAt: 1_000))
        _ = try await h.server.writeDesignBoard(designID, path: Self.board, source: DesignTests.board(root: Self.card))
        _ = try await h.server.updateDesignIndex(designID, patch: .object(["boards": .object([Self.board.rawValue: .object([
            "x": .number(0), "y": .number(0), "w": .number(390), "h": .number(844)])])]))
        let agent = try ExtensionClient(path: h.socketPath)

        try agent.send(.designProposeComments(id: 1, agentID: drawer.agent.id, designID: designID, call: "call-7", proposals: [
            DesignMarkupProposal(element: Self.cardID.description, text: "Thicker bars on phone."),
            DesignMarkupProposal(element: Self.totalID.description, text: " Show counts here too. "),
        ]))
        guard case .designProposals(1, let proposals) = try await agent.reply() else { Issue.record("no proposals"); return }
        #expect(proposals.map(\.proposal) == ["call-7#0", "call-7#1"])
        #expect(proposals.map(\.tid) == [2, 4] && proposals.map(\.path) == [[1], [1, 1]])
        #expect(proposals.map(\.target) == ["Checkout funnel", "48,210 people"], "a data-el name, else the element's words")
        #expect(proposals.map(\.text) == ["Thicker bars on phone.", "Show counts here too."])

        try agent.send(.designProposeComments(id: 2, agentID: drawer.agent.id, designID: designID, call: "c",
                                              proposals: [DesignMarkupProposal(element: "A.dc.html#40:1/9", text: "x")]))
        guard case .error(2, "invalid_markup", _) = try await agent.reply() else { Issue.record("a missing element answered"); return }
        try agent.send(.designProposeComments(id: 3, agentID: drawer.agent.id, designID: designID, call: "c",
                                              proposals: [DesignMarkupProposal(element: "not an id", text: "x")]))
        guard case .error(3, "invalid_markup", _) = try await agent.reply() else { Issue.record("a bad id answered"); return }
        try agent.send(.designProposeComments(id: 4, agentID: stranger.agent.id, designID: designID, call: "c",
                                              proposals: [DesignMarkupProposal(element: Self.cardID.description, text: "x")]))
        guard case .error(4, "not_your_design", _) = try await agent.reply() else { Issue.record("a stranger proposed"); return }

        // The first call's proposals are comments 1 and 2 at once (iPadDesign: "Comments 3" beside
        // the cards), waiting for the viewer; the refused calls kept none.
        let kept = try await h.server.designComments(designID)
        #expect(kept.revision == 1, "both kept as one change")
        #expect(kept.comments.map(\.number) == [1, 2] && kept.comments.map(\.proposal) == ["call-7#0", "call-7#1"])
        #expect(kept.comments.map(\.label) == ["Checkout funnel 48,210 people", "48,210 people"])
        #expect(kept.comments.allSatisfy { $0.proposalSettledAt == nil && $0.author == .user && $0.isOpen })
    }

    /// The design agent's `markup_propose`, as the host serves it: `texts` kept as comments on
    /// the card and its total, named `<call>#0` and `<call>#1`.
    private func propose(_ h: ScratchServer, _ designID: DesignID, call: String,
                         texts: [String] = ["Thicker bars on phone.", "Show counts here too."]) async throws -> [DesignComment] {
        let drafts = try await h.server.proposeDesignComments(designID, call: call, proposals: [
            DesignMarkupProposal(element: Self.cardID.description, text: texts[0]),
            DesignMarkupProposal(element: Self.totalID.description, text: texts[1]),
        ])
        let ids = drafts.compactMap(\.proposal)
        return try await h.server.designComments(designID).comments.filter { $0.proposal.map(ids.contains) == true }
    }

    @Test func keptProposalsStayOnTheCanvasAndSettleOnce() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let designID = try await design(h, agentID: pi.agent.id)
        _ = try await pi.ready()
        let before = prompts(pi).count
        let proposed = try await propose(h, designID, call: "c1")
        #expect(prompts(pi).count == before, "proposing sends the agent nothing")

        let kept = try await h.server.settleDesignProposals(designID, proposals: ["c1#0", "c1#1"], deliver: false, baseRevision: 1)
        #expect(kept.undelivered == nil)
        #expect(kept.comments.map(\.id) == proposed.map(\.id))
        #expect(kept.comments.allSatisfy { $0.proposalSettledAt != nil })
        #expect(try await h.server.designComments(designID).revision == 2, "both settled as one change")
        #expect(prompts(pi).count == before, "keeping sends the agent nothing")

        // Applied after all, or kept again from another device: nothing changes or is sent.
        let again = try await h.server.settleDesignProposals(designID, proposals: ["c1#0", "c1#1"], deliver: true)
        #expect(again.comments == kept.comments)
        let all = try await h.server.designComments(designID)
        #expect(all.comments.count == 2 && all.revision == 2)
        #expect(prompts(pi).count == before)
    }

    @Test func appliedProposalsGoToTheAgentAsCommentsDo() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let designID = try await design(h, agentID: pi.agent.id)
        _ = try await pi.ready()

        _ = try await propose(h, designID, call: "c2", texts: ["tools:0 Thicker bars on phone.", "tools:0 Show counts here too."])
        let applied = try await h.server.settleDesignProposals(designID, proposals: ["c2#0", "c2#1"], deliver: true)
        #expect(applied.undelivered == nil)
        let ids = applied.comments.map(\.id)
        _ = try await pi.snapshot("both comments' turns to settle") { s in
            !s.running && ids.allSatisfy { id in s.messages.contains { $0.origin?.designComment == id } } && s.messages.last?.role == "assistant"
        }
        let fences = prompts(pi).compactMap { DesignCommentFence.parse($0) }
        #expect(fences.map(\.fence.comment) == ids)
        #expect(fences.map { String($0.text) } == ["tools:0 Thicker bars on phone.", "tools:0 Show counts here too."])
    }

    /// Each list after the first ends with a name no kept proposal has.
    static let refusedSettles: [(String, [String])] = [
        ("no proposals", []),
        ("a proposal the design keeps no comment for", ["ok#0", "ok#1", "other#0"]),
        ("a proposal id on two lines", ["ok#0", "ok\n#1"]),
        ("a comment the viewer wrote", ["ok#0", ""]),
    ]

    @Test(arguments: refusedSettles)
    func settlingAProposalTheDesignLacksSettlesNoneOfThem(_ name: String, _ proposals: [String]) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        try await h.seed(Fixture.workspace([], space: space))
        let designID = try await design(h, agentID: nil)
        _ = try await propose(h, designID, call: "ok")
        do {
            _ = try await h.server.settleDesignProposals(designID, proposals: proposals, deliver: false)
            Issue.record("\(name) was settled")
        } catch let error as DesignStoreError {
            #expect(error.code == "invalid_markup", "\(name)")
        }
        let comments = try await h.server.designComments(designID)
        #expect(comments.revision == 1 && comments.comments.allSatisfy { $0.proposalSettledAt == nil }, "all or none")
    }

    /// The agent's proposals are kept all or none: one the design can't hold keeps none.
    @Test func aProposalThatCantBeACommentKeepsNoneOfThem() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        try await h.seed(Fixture.workspace([], space: space))
        let designID = try await design(h, agentID: nil)
        do {
            _ = try await h.server.proposeDesignComments(designID, call: "c", proposals: [
                DesignMarkupProposal(element: Self.cardID.description, text: "Thicker bars."),
                DesignMarkupProposal(element: Self.totalID.description, text: " "),
            ])
            Issue.record("blank words were proposed")
        } catch let error as DesignStoreError {
            #expect(error.code == "invalid_markup")
        }
        #expect(try await h.server.designComments(designID).comments.isEmpty)
    }
}
