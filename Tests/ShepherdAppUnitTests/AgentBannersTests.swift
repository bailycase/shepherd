import ShepherdCore
import ShepherdSessions
import Testing
@testable import ShepherdApp

/// What the Mac's system notifications say: a finished turn, a failed one, and a question each
/// read as what happened, and none shows while you're watching the agent.
@Suite("Agent banners")
struct AgentBannersTests {
    private let space = Fixture.space("s")

    private func agent(_ status: AgentStatus) -> Agent {
        var agent = Fixture.agent("Fix login", in: space).agent
        agent.status = status
        return agent
    }

    @Test(arguments: [
        (AgentStatus.done, TurnFailure?.none, "Agent finished", false),
        (.done, TurnFailure(message: "529 overloaded"), "Turn failed\n529 overloaded", true),
        (.done, TurnFailure(message: nil), "Turn failed", true),
        (.done, TurnFailure(message: "  \n"), "Turn failed", true),
        (.blocked, nil, "Agent needs your input", true),
    ])
    func aTurnEndingOrAQuestionPostsWhatHappened(status: AgentStatus, failure: TurnFailure?, body: String, sound: Bool) throws {
        let agent = agent(status)
        let banner = try #require(AgentBanners.status(of: agent, from: .working, failure: failure, watching: false))
        #expect(banner.body == body)
        #expect(banner.sound == sound)
        #expect(banner.title == "Fix login")
        #expect(banner.agentID == agent.id)
        #expect(banner.identifier == "agent-status-\(agent.id.rawValue)")
    }

    /// Launch resets and session restarts are not moments that want you, and neither is anything
    /// while you're watching the agent.
    @Test(arguments: [
        (AgentStatus.idle, AgentStatus.done, false),
        (.done, .done, false),
        (.working, .idle, false),
        (.working, .working, false),
        (.blocked, .working, false),
        (.working, .done, true),
        (.working, .blocked, true),
    ])
    func onlyWorkingToDoneOrBlockedPosts(from old: AgentStatus, to status: AgentStatus, posts: Bool) {
        let failure = TurnFailure(message: "boom")
        #expect((AgentBanners.status(of: agent(status), from: old, failure: failure, watching: false) != nil) == posts)
        #expect(AgentBanners.status(of: agent(status), from: old, failure: failure, watching: true) == nil)
    }

    /// A long error shows its first line, cut short.
    @Test func aFailureQuotesTheFirstLineOfItsError() throws {
        let long = String(repeating: "x", count: 300)
        let banner = try #require(AgentBanners.status(of: agent(.done), from: .working,
                                                      failure: TurnFailure(message: "\(long)\nstack"), watching: false))
        let quoted = try #require(banner.body.split(separator: "\n").last)
        #expect(quoted.count == AgentBanners.quoteLimit)
        #expect(quoted.hasSuffix("…"))
    }
}
