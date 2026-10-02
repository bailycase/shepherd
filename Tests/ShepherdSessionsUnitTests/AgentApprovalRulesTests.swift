import Testing
import ShepherdCore
@testable import ShepherdSessions

/// What Settings ▸ Pi ▸ Agent-to-agent messages decides about one call, and how long "Allow for
/// this thread" lasts. The server's integration tests (`AgentApprovalTests`) run it over a socket.
@Suite("Agent approval rules")
struct AgentApprovalRulesTests {
    @Test func theDefaultIsToAskAndThereAreThreeChoices() {
        #expect(AgentMessagePolicy.default == .ask)
        #expect(AgentMessagePolicy.allCases == [.ask, .always, .never])
        #expect(AgentMessagePolicy.allCases.map(\.rawValue) == ["ask", "always", "never"], "stored by these names")
    }

    /// Every combination of the setting, a run nobody watches, and an allowance for the thread.
    @Test(arguments: [
        (AgentMessagePolicy.ask, false, false, AgentMessageGate.Verdict.ask),
        (.ask, false, true, .perform),
        (.ask, true, false, .refuse(code: "not_allowed", message: AgentMessageGate.unattendedMessage)),
        (.ask, true, true, .refuse(code: "not_allowed", message: AgentMessageGate.unattendedMessage)),
        (.always, false, false, .perform),
        (.always, true, false, .perform),
        (.always, true, true, .perform),
        (.never, false, false, .refuse(code: "not_allowed", message: AgentMessageGate.offMessage)),
        (.never, false, true, .refuse(code: "not_allowed", message: AgentMessageGate.offMessage)),
        (.never, true, false, .refuse(code: "not_allowed", message: AgentMessageGate.offMessage)),
    ])
    func theSettingDecidesEachGatedCall(policy: AgentMessagePolicy, automation: Bool, granted: Bool, verdict: AgentMessageGate.Verdict) {
        #expect(AgentMessageGate.verdict(policy: policy, senderIsAutomation: automation, hasThreadGrant: granted) == verdict)
    }

    /// Deleting keeps its own dialog under Ask and Always; the setting only switches it off.
    @Test(arguments: [
        (AgentMessagePolicy.ask, false, AgentMessageGate.Verdict.perform),
        (.ask, true, .refuse(code: "not_allowed", message: AgentMessageGate.unattendedMessage)),
        (.always, false, .perform),
        (.always, true, .perform),
        (.never, false, .refuse(code: "not_allowed", message: AgentMessageGate.offMessage)),
        (.never, true, .refuse(code: "not_allowed", message: AgentMessageGate.offMessage)),
    ])
    func deletingIsOnlyEverSwitchedOff(policy: AgentMessagePolicy, automation: Bool, verdict: AgentMessageGate.Verdict) {
        #expect(AgentMessageGate.deleteVerdict(policy: policy, senderIsAutomation: automation) == verdict)
    }

    @Test func theWordsAnAgentReadsTellItToStop() {
        #expect(AgentMessageGate.deniedMessage == "The user did not approve. Don't message other agents unless the user asks you to.")
        for message in [AgentMessageGate.deniedMessage, AgentMessageGate.timedOutMessage, AgentMessageGate.busyMessage] {
            #expect(message.hasSuffix("Don't message other agents unless the user asks you to."))
        }
        #expect(AgentMessageGate.offMessage.contains("turned agent-to-agent messages off"))
        #expect(AgentMessageGate.unattendedMessage.contains("Always allow") && AgentMessageGate.unattendedMessage.contains("notify"))
    }

    @Test func anApprovalWaitsTwoMinutesAndAnAgentMayHaveEightWaitingOfTwentyFour() {
        #expect(AgentMessageGate.approvalTimeout == 120)
        #expect(AgentMessageGate.pendingLimitPerAgent == 8)
        #expect(AgentMessageGate.pendingLimit == 24)
    }

    // MARK: - Allow for this thread

    private let lead = AgentID(rawValue: "lead")
    private let worker = AgentID(rawValue: "worker")
    private let first = SessionID(rawValue: "pi-1")
    private let second = SessionID(rawValue: "pi-2")

    @Test func anAllowanceLastsWhileTheSamePiRunsAndOnlyForThatAgent() {
        var grants = AgentThreadGrants()
        let before = grants.allows(lead, session: first)

        grants.grant(lead, session: first)
        let allowed = grants.allows(lead, session: first)
        let again = grants.allows(lead, session: first)
        let other = grants.allows(worker, session: first)

        #expect(!before)
        #expect(allowed)
        #expect(again, "asking does not use it up")
        #expect(!other, "another agent was not allowed")
    }

    @Test func aRestartedPiAsksAgainAndTheOldAllowanceIsGone() {
        var grants = AgentThreadGrants()
        grants.grant(lead, session: first)

        let restarted = grants.allows(lead, session: second)
        let old = grants.allows(lead, session: first)

        #expect(!restarted, "a new session is a restarted pi")
        #expect(!old, "and the old allowance does not come back")
        #expect(grants.agents.isEmpty)
    }

    @Test func aPiNotYetBoundIsAllowedOnlyWhileNoneIsBound() {
        var grants = AgentThreadGrants()
        grants.grant(lead, session: nil)
        let unbound = grants.allows(lead, session: nil)
        let bound = grants.allows(lead, session: first)
        #expect(unbound)
        #expect(!bound)
    }

    @Test func forgettingOneAgentOrEveryAgentEndsTheirAllowances() {
        var grants = AgentThreadGrants()
        grants.grant(lead, session: first)
        grants.grant(worker, session: first)

        grants.forget(lead)
        let forgotten = grants.allows(lead, session: first)
        let kept = grants.allows(worker, session: first)
        grants.removeAll()
        let none = grants.allows(worker, session: first)

        #expect(!forgotten && kept && !none)
    }
}
