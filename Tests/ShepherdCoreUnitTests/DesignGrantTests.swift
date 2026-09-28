import Foundation
import Testing
@testable import ShepherdCore

/// What a design reference lets a thread's agent read (docs/designs.md › Design references): the
/// copy of exactly the piece it was sent (a whole design, a board, or an element), at each
/// revision it was sent.
@Suite("Design grants")
struct DesignGrantTests {
    static let design = DesignID(rawValue: "d1")
    static let other = DesignID(rawValue: "d2")
    static let copy = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let board = DesignGrant(designID: design, board: "A.dc.html", revision: 4, boardSHA: "aa", grantedAt: 1, payload: copy)
    static let element = DesignGrant(designID: design, board: "A.dc.html", element: "A.dc.html#2:0/1", label: "Pay now",
                                     revision: 4, boardSHA: "aa", grantedAt: 1, payload: UUID())
    static let whole = DesignGrant(designID: design, board: nil, revision: 4, grantedAt: 1, payload: UUID())

    @Test(arguments: [
        (board, design, "A.dc.html" as String?, nil as String?, true),
        (board, design, "A.dc.html", "A.dc.html#7:1/0", false),
        (board, design, "B.dc.html", nil, false),
        (board, other, "A.dc.html", nil, false),
        (board, design, nil, nil, false),
        (element, design, "A.dc.html", "A.dc.html#2:0/1", true),
        (element, design, "A.dc.html", nil, false),
        (element, design, "A.dc.html", "A.dc.html#7:1/0", false),
        (element, design, "flows/A.dc.html", "A.dc.html#2:0/1", false),
        (whole, design, nil, nil, true),
        (whole, design, "A.dc.html", nil, false),
        (whole, other, nil, nil, false),
    ])
    func aGrantIsItsPieceAndNothingElse(_ grant: DesignGrant, _ design: DesignID, _ board: String?, _ element: String?, _ same: Bool) {
        #expect(grant.isPiece(designID: design, board: board, element: element) == same)
    }

    @Test func anAgentFindsTheCopyAtTheRevisionAskedForElseTheLatest() {
        var agent = Agent(name: "t", spaceID: SpaceID(), tabID: TabID())
        var later = Self.element
        later.revision = 9
        later.grantedAt = 2
        later.payload = UUID()
        agent.addDesignGrants([Self.element, later, Self.board])
        #expect(agent.designGrant(designID: Self.design, board: "A.dc.html", element: "A.dc.html#2:0/1", revision: 4)?.revision == 4)
        #expect(agent.designGrant(designID: Self.design, board: "A.dc.html", element: "A.dc.html#2:0/1")?.revision == 9)
        #expect(agent.designGrant(designID: Self.design, board: "A.dc.html", element: "A.dc.html#2:0/1", revision: 5) == nil,
                "never a version the thread wasn't sent")
        #expect(agent.designGrant(designID: Self.design, board: "A.dc.html", element: nil)?.payload == Self.copy)
        #expect(agent.designGrant(designID: Self.other, board: "A.dc.html", element: nil) == nil)
        #expect(agent.designGrants(forPieceOf: later).map(\.revision) == [4, 9])
    }

    /// A grant from before copies were kept answers nothing.
    @Test func aGrantWithoutACopyAnswersNothing() {
        var agent = Agent(name: "t", spaceID: SpaceID(), tabID: TabID())
        agent.designGrants = [DesignGrant(designID: Self.design, board: "A.dc.html", revision: 4, grantedAt: 1)]
        #expect(agent.designGrant(designID: Self.design, board: "A.dc.html", element: nil) == nil)
    }

    /// The same piece sent twice keeps both copies (each message's chip reads its own), the
    /// newer answering design_get; past the cap the oldest go, and the caller removes their copies.
    @Test func eachSendKeepsItsCopyAndTheOldestGoFirst() {
        var agent = Agent(name: "t", spaceID: SpaceID(), tabID: TabID())
        var again = Self.board
        again.payload = UUID()
        again.grantedAt = 2
        #expect(agent.addDesignGrants([Self.board, Self.board]).isEmpty)
        #expect(agent.designGrants.count == 1, "one copy once")
        #expect(agent.addDesignGrants([again]).isEmpty)
        #expect(agent.designGrants == [Self.board, again])
        #expect(agent.designGrant(designID: Self.design, board: "A.dc.html", element: nil)?.payload == again.payload)
        let many = (0..<(DesignGrant.maxPerAgent + 5)).map {
            DesignGrant(designID: Self.design, board: "B\($0).dc.html", revision: 1, grantedAt: Double($0), payload: UUID())
        }
        let gone = agent.addDesignGrants(many)
        #expect(agent.designGrants.count == DesignGrant.maxPerAgent)
        #expect(agent.designGrants.first?.board == "B5.dc.html")
        #expect(gone.count == 7 && gone.first == Self.board && gone[1] == again)
    }

    @Test func anAgentFromBeforeReferencesHasNoneAndWritesNone() throws {
        let agent = try Fixture.decode(Agent.self, #"{"id":"a1","name":"n","spaceID":"s","tabID":"t","status":"idle"}"#)
        #expect(agent.designGrants.isEmpty)
        #expect(try Fixture.encodeObject(agent)["designGrants"] == nil)
        var granted = agent
        granted.designGrants = [Self.element, Self.whole]
        #expect(try Fixture.roundTrip(granted) == granted)
    }

    /// A grant written before copies were kept (a board, no payload) still decodes.
    @Test func aGrantFromBeforeCopiesDecodes() throws {
        let grant = try Fixture.decode(DesignGrant.self, #"{"designID":"d1","board":"A.dc.html","revision":3,"grantedAt":1}"#)
        #expect(grant.board == "A.dc.html" && grant.payload == nil)
    }

    /// A design's own agent holds none, and a grant without a copy goes; a grant on a design that
    /// is gone stays (its copy still reaches the agent); a client with no designs gets none.
    @Test func startupDropsADesignAgentsGrantsAndOnesWithoutACopy() {
        let space = SpaceID()
        let kept = Design(id: Self.design, name: "Checkout", createdAt: 1)
        let gone = DesignGrant(designID: Self.other, board: "A.dc.html", revision: 1, grantedAt: 1, payload: UUID())
        let old = DesignGrant(designID: Self.design, board: "B.dc.html", revision: 1, grantedAt: 1)
        var thread = Agent(name: "thread", spaceID: space, tabID: TabID())
        thread.designGrants = [Self.board, gone, old]
        var drawer = Agent(name: "drawer", spaceID: space, tabID: TabID(), designID: Self.design)
        drawer.designGrants = [Self.board]
        var state = ShepherdState(spaces: [], tabs: [], agents: [thread, drawer], designs: [kept])
        #expect(state.hasStaleDesignGrants)
        state.dropStaleDesignGrants()
        #expect(state.agents[0].designGrants == [Self.board, gone])
        #expect(state.agents[1].designGrants.isEmpty)
        #expect(!state.hasStaleDesignGrants)
        #expect(state.withoutDesigns.agents.allSatisfy { $0.designGrants.isEmpty })
    }
}
