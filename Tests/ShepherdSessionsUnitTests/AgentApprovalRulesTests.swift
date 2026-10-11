import Testing
import ShepherdCore
@testable import ShepherdSessions

/// Access policy, independent of UI. Integration tests exercise these decisions over a socket.
@Suite("Agent approval rules")
struct AgentApprovalRulesTests {
    @Test func theDefaultAllowsInteractiveThreadsAndStoredChoicesRemainCompatible() {
        #expect(AgentMessagePolicy.default == .ask)
        #expect(AgentMessagePolicy.allCases == [.ask, .always, .never])
        #expect(AgentMessagePolicy.allCases.map(\.rawValue) == ["ask", "always", "never"], "stored by these names")
    }

    /// Every combination of the setting, a run nobody watches, and an allowance for the thread.
    @Test(arguments: [
        (AgentMessagePolicy.ask, false, false, AgentMessageGate.Verdict.perform),
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

    /// Deletion follows the access policy without opening a dialog.
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

    @Test func refusedCallsExplainTheAccessSetting() {
        #expect(AgentMessageGate.offMessage.contains("turned agent-to-agent messages off"))
        #expect(AgentMessageGate.unattendedMessage.contains("Always allow") && AgentMessageGate.unattendedMessage.contains("notify"))
    }

}
