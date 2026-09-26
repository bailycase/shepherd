import ShepherdCore
import ShepherdRemote
import Testing

/// The header's branch chip: a worktree or your checkout, its branch, the files changed there,
/// and the host when it is another one.
@Suite("Agent branch label")
struct AgentBranchPresentationTests {
    private static func agent(worktree: String? = nil, checkout: AgentCheckout? = nil) -> Agent {
        Agent(name: "a", spaceID: SpaceID(), tabID: TabID(), worktreeBranch: worktree, checkout: checkout)
    }

    @Test(arguments: [
        (agent(worktree: "pi/swiftui-previews", checkout: AgentCheckout(branch: "pi/swiftui-previews", changedFiles: 3)), nil,
         AgentBranchLabel(kind: .worktree, branch: "pi/swiftui-previews", changedFiles: 3)),
        // Before the host has read it, a worktree still names the branch Shepherd made.
        (agent(worktree: "pi/refund-events"), "build-01", AgentBranchLabel(kind: .worktree, branch: "pi/refund-events", host: "build-01")),
        // pi switched the worktree's branch: the checkout wins.
        (agent(worktree: "pi/old", checkout: AgentCheckout(branch: "pi/new", changedFiles: 0)), nil,
         AgentBranchLabel(kind: .worktree, branch: "pi/new")),
        (agent(checkout: AgentCheckout(branch: "chore/remove-homarr", changedFiles: 11)), "horizon",
         AgentBranchLabel(kind: .checkout, branch: "chore/remove-homarr", changedFiles: 11, host: "horizon")),
    ] as [(Agent, String?, AgentBranchLabel)])
    func theChipNamesWhereTheAgentWorks(agent: Agent, host: String?, expected: AgentBranchLabel) {
        #expect(AgentBranchLabel(agent: agent, host: host) == expected)
    }

    @Test func anAgentOutsideARepositoryHasNoChip() {
        #expect(AgentBranchLabel(agent: Self.agent(), host: "horizon") == nil)
    }

    @Test(arguments: [
        (AgentBranchLabel(kind: .worktree, branch: "pi/x", changedFiles: 1), "~/code/x", "Worktree · pi/x · 1 file changed\n~/code/x"),
        (AgentBranchLabel(kind: .checkout, branch: "main", changedFiles: 0, host: "horizon"), nil, "Your checkout · main · no changes · on horizon"),
    ] as [(AgentBranchLabel, String?, String)])
    func itsTooltipSaysTheBranchAndTheDirectory(label: AgentBranchLabel, directory: String?, help: String) {
        #expect(label.help(directory: directory) == help)
    }
}
