import CoreServices
import ShepherdCore
import ShepherdUI
import Testing
@testable import ShepherdApp

/// Quitting while agents are busy: whether a quit asks, and what the dialog says.
@Suite("Quit confirmation")
struct QuitConfirmationTests {
    private static func agents(_ statuses: [AgentStatus]) -> [Agent] {
        let space = Fixture.space("app")
        return statuses.enumerated().map { index, status in
            var agent = Fixture.agent("agent \(index + 1)", in: space, order: index).agent
            agent.status = status
            return agent
        }
    }

    @Test(arguments: [
        ([AgentStatus](), false),
        ([.idle, .done], false),
        ([.idle, .working], true),
        ([.blocked], true),
    ])
    func onlyAgentsMidTurnOrWaitingOnAnAnswerMakeAQuitAsk(statuses: [AgentStatus], asks: Bool) throws {
        let agents = Self.agents(statuses)
        let decision = QuitPolicy.decide(agents: agents, systemPoweringOff: false, asking: false)
        #expect(decision == (asks ? .ask(try #require(QuitPrompt(agents: agents))) : .quit))
    }

    enum Outcome { case quit, ask, keepAsking }

    /// A log out or shut down quits at once, even with the dialog already up; a second ⌘Q while
    /// it asks leaves the first quit waiting on its answer.
    @Test(arguments: [(false, false, Outcome.ask), (true, false, .quit), (false, true, .keepAsking), (true, true, .quit)])
    func powerOffNeverWaitsAndASecondQuitKeepsAsking(poweringOff: Bool, asking: Bool, expected: Outcome) {
        let outcome: Outcome = switch QuitPolicy.decide(agents: Self.agents([.working]), systemPoweringOff: poweringOff, asking: asking) {
        case .quit: .quit
        case .ask: .ask
        case .keepAsking: .keepAsking
        }
        #expect(outcome == expected)
    }

    @Test(arguments: [
        (OSType(kAELogOut), true), (OSType(kAEReallyLogOut), true), (OSType(kAERestart), true), (OSType(kAEShutDown), true),
        (OSType(kAEQuitAll), false), (nil as OSType?, false),
    ])
    func loginwindowsQuitReasonsMeanPowerOff(reason: OSType?, poweringOff: Bool) {
        #expect(QuitPolicy.isPowerOff(quitReason: reason) == poweringOff)
    }

    @Test func oneWorkingAgentIsNamedInTheSingular() throws {
        let prompt = try #require(QuitPrompt(agents: Self.agents([.idle, .working])))
        #expect(prompt.title == "Quit and stop the working agent?")
        #expect(prompt.subtitle == "1 agent is still working. Its conversation stays on disk and reopens on next launch.")
        #expect(prompt.rows.map(\.name) == ["agent 2"])
        #expect(prompt.more == nil)
    }

    /// Five agents are listed; the rest are counted. An agent waiting on an answer reads as the
    /// sidebar reads it.
    @Test func aLongListNamesFiveAndCountsTheRest() throws {
        let prompt = try #require(QuitPrompt(agents: Self.agents([.blocked, .working, .done, .working, .working, .working, .working, .working])))
        #expect(prompt.count == 7)
        #expect(prompt.title == "Quit and stop every working agent?")
        #expect(prompt.subtitle.hasPrefix("7 agents are still working."))
        #expect(prompt.rows.map(\.name) == ["agent 1", "agent 2", "agent 4", "agent 5", "agent 6"])
        #expect(prompt.rows.map(\.word) == ["needs you", "working", "working", "working", "working"])
        #expect(prompt.rows.first?.state == .attention)
        #expect(prompt.more == "and 2 more")
    }
}
