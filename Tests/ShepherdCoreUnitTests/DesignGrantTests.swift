import Foundation
import Testing
@testable import ShepherdCore

/// What a design reference lets a thread's agent read (docs/designs.md › Design references): the
/// referenced board, or the element and its board whole, of that design alone, from its pinned
/// revision on.
@Suite("Design grants")
struct DesignGrantTests {
    static let design = DesignID(rawValue: "d1")
    static let other = DesignID(rawValue: "d2")
    static let board = DesignGrant(designID: design, board: "A.dc.html", revision: 4, boardSHA: "aa", grantedAt: 1)
    static let element = DesignGrant(designID: design, board: "A.dc.html", element: "A.dc.html#2:0/1", label: "Pay now",
                                     revision: 4, boardSHA: "aa", grantedAt: 1)

    @Test(arguments: [
        // A board's grant: the board whole and any element on it.
        (board, design, "A.dc.html", nil as String?, true),
        (board, design, "A.dc.html", "A.dc.html#7:1/0", true),
        (board, design, "B.dc.html", nil, false),
        (board, other, "A.dc.html", nil, false),
        // An element's grant: that element, and its board whole (its page and image came with it).
        (element, design, "A.dc.html", "A.dc.html#2:0/1", true),
        (element, design, "A.dc.html", nil, true),
        (element, design, "A.dc.html", "A.dc.html#7:1/0", false),
        (element, design, "flows/A.dc.html", "A.dc.html#2:0/1", false),
        (element, other, "A.dc.html", "A.dc.html#2:0/1", false),
    ])
    func aGrantCoversItsPieceAndNothingElse(_ grant: DesignGrant, _ design: DesignID, _ board: String, _ element: String?,
                                            _ covered: Bool) {
        #expect(grant.covers(designID: design, board: board, element: element) == covered)
    }

    @Test func anAgentFindsThePinAtTheRevisionAskedForElseTheLatest() {
        var agent = Agent(name: "t", spaceID: SpaceID(), tabID: TabID())
        var later = Self.element
        later.revision = 9
        later.grantedAt = 2
        agent.addDesignGrants([Self.element, later, Self.board])
        #expect(agent.designGrant(designID: Self.design, board: "A.dc.html", element: "A.dc.html#2:0/1", revision: 4)?.revision == 4)
        #expect(agent.designGrant(designID: Self.design, board: "A.dc.html", element: "A.dc.html#2:0/1")?.revision == 9)
        #expect(agent.designGrant(designID: Self.design, board: "A.dc.html", element: nil)?.element == nil,
                "the board's own grant answers for the board")
        #expect(agent.designGrant(designID: Self.other, board: "A.dc.html", element: nil) == nil)
    }

    @Test func thePiecePinnedTwiceAtOneRevisionIsKeptOnceAndTheOldestGoFirst() {
        var agent = Agent(name: "t", spaceID: SpaceID(), tabID: TabID())
        agent.addDesignGrants([Self.board, Self.board])
        #expect(agent.designGrants.count == 1)
        agent.addDesignGrants((0..<(DesignGrant.maxPerAgent + 5)).map {
            DesignGrant(designID: Self.design, board: "B\($0).dc.html", revision: 1, grantedAt: Double($0))
        })
        #expect(agent.designGrants.count == DesignGrant.maxPerAgent)
        #expect(agent.designGrants.first?.board == "B5.dc.html")
    }

    @Test func anAgentFromBeforeReferencesHasNoneAndWritesNone() throws {
        let agent = try Fixture.decode(Agent.self, #"{"id":"a1","name":"n","spaceID":"s","tabID":"t","status":"idle"}"#)
        #expect(agent.designGrants.isEmpty)
        #expect(try Fixture.encodeObject(agent)["designGrants"] == nil)
        var granted = agent
        granted.designGrants = [Self.element]
        #expect(try Fixture.roundTrip(granted) == granted)
    }

    /// A design no longer in the workspace takes its grants with it; a design's own agent holds
    /// none; a client with no designs gets none.
    @Test func grantsOnADesignThatIsGoneOrHeldByADesignsAgentAreDropped() {
        let space = SpaceID()
        let kept = Design(id: Self.design, name: "Checkout", createdAt: 1)
        var thread = Agent(name: "thread", spaceID: space, tabID: TabID())
        thread.designGrants = [Self.board, DesignGrant(designID: Self.other, board: "A.dc.html", revision: 1, grantedAt: 1)]
        var drawer = Agent(name: "drawer", spaceID: space, tabID: TabID(), designID: Self.design)
        drawer.designGrants = [Self.board]
        var state = ShepherdState(spaces: [], tabs: [], agents: [thread, drawer], designs: [kept])
        #expect(state.hasStaleDesignGrants)
        state.dropStaleDesignGrants()
        #expect(state.agents[0].designGrants == [Self.board])
        #expect(state.agents[1].designGrants.isEmpty)
        #expect(!state.hasStaleDesignGrants)
        #expect(state.withoutDesigns.agents.allSatisfy { $0.designGrants.isEmpty })
    }
}
