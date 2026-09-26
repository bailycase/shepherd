import ShepherdCore
import Testing
@testable import ShepherdApp

/// The header's branch chip reads `git status --porcelain=v2 --branch -z`: its branch, and one
/// file per changed, unmerged or untracked entry.
@Suite("Checkout status")
struct CheckoutStatusTests {
    @Test(arguments: [
        ("# branch.oid 1a2b3c4d5e\0# branch.head pi/swiftui-previews\0", AgentCheckout(branch: "pi/swiftui-previews", changedFiles: 0)),
        ("# branch.oid 1a2b3c4d5e\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +1 -0\0"
            + "1 .M N... 100644 100644 100644 aaa bbb Sources/App.swift\0"
            + "1 A. N... 000000 100644 100644 000 ccc Sources/New.swift\0"
            + "? notes.md\0? docs/draft.md\0", AgentCheckout(branch: "main", changedFiles: 4)),
        ("# branch.oid 1a2b3c4d5e\0# branch.head feat/rename\0"
            + "2 R. N... 100644 100644 100644 aaa aaa R100 Sources/Renamed.swift\0Sources/Old.swift\0"
            + "u UU N... 100644 100644 100644 100644 a b c Package.swift\0", AgentCheckout(branch: "feat/rename", changedFiles: 2)),
        ("# branch.oid 1a2b3c4d5e6f7a8b\0# branch.head (detached)\0? x\0", AgentCheckout(branch: "1a2b3c4", changedFiles: 1)),
        ("# branch.oid (initial)\0# branch.head main\0? README.md\0", AgentCheckout(branch: "main", changedFiles: 1)),
    ] as [(String, AgentCheckout)])
    func statusReadsTheBranchAndCountsChangedFiles(output: String, expected: AgentCheckout) {
        #expect(CheckoutStatus.parse(output) == expected)
    }

    @Test(arguments: ["", "? stray.txt\0", "# branch.oid (initial)\0# branch.head (detached)\0"])
    func statusWithoutABranchReadsAsNoCheckout(output: String) {
        #expect(CheckoutStatus.parse(output) == nil)
    }

    @Test(arguments: [("read", false), ("grep", false), ("find", false), ("ls", false),
                      ("edit", true), ("write", true), ("bash", true), ("subagent", true)])
    func onlyCallsThatMayWriteFilesReadTheCheckoutAgain(tool: String, touches: Bool) {
        #expect(CheckoutMonitor.touchesFiles(tool: tool) == touches)
    }
}
