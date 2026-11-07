import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The thread's branch card (BranchCard board) under the toolbar's pressed branch button, light
/// and dark: git's numbers read from a scratch clone that is behind its origin, a pull request
/// with passing checks, and the space's other threads as the card lists them.
@Suite("Branch card previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct BranchCardPreviewTests {
    @Test func theCardUnderTheToolbar() async throws {
        let origin = try makeScratchRepo(files: ["ledger/outbox.go": (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"])
        let clone = try makeScratchDirectory("clone")
        defer { for url in [origin, clone] { try? FileManager.default.removeItem(at: url) } }
        try git(["clone", "-q", origin.path, clone.path], in: clone.deletingLastPathComponent())
        for args in [["config", "user.name", "T"], ["config", "user.email", "t@example.com"], ["switch", "-qc", "agent/refund-events"]] {
            try git(args, in: clone)
        }
        for n in 1...3 {
            try "\(n)\n".write(to: origin.appendingPathComponent("main\(n).txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], in: origin)
            try git(["commit", "-qm", "main \(n)"], in: origin)
        }
        try git(["fetch", "-q"], in: clone)
        let lines = (1...12).map { "line \($0)" } + (1...71).map { "refund \($0)" }
        try (lines.joined(separator: "\n") + "\n").write(to: clone.appendingPathComponent("ledger/outbox.go"), atomically: true, encoding: .utf8)

        let space = SpaceID(), tab = TabID(), now = Date()
        func agent(_ branch: String, _ status: AgentStatus, daysAgo: Double = 0) -> Agent {
            Agent(name: branch, spaceID: space, tabID: tab, status: status, worktreeBranch: branch,
                  lastActiveAt: (now.timeIntervalSince1970 - daysAgo * 86_400) * 1000)
        }
        let me = agent("agent/refund-events", .done)
        let others = BranchCardModel.others(of: me, in: [me, agent("baily/ledger-refactor", .idle, daysAgo: 3), agent("agent/webhook-retries", .blocked)], now: now)
        let card = BranchCardModel(space: "payments", branch: "agent/refund-events", worktree: true, directory: clone.path, others: others)
        let pull = PullRequestSummary(ref: ForgeItemRef(kind: .pullRequest, repo: "acme/payments", number: 31), title: "Add refund events",
                                      author: "baily", updatedAt: now, state: .open, checks: .passed, headRef: card.branch, baseRef: "main")
        let status = BranchCardStatus(git: BranchCardGitReader.read(cwd: clone.path, base: "main"), pull: pull)
        #expect(status.git.behind == 3 && status.git.additions == 71 && status.git.deletions == 8)

        try await Preview.render("branch-card", size: CGSize(width: 1000, height: 360)) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    SHThreadToolbar("Add refund events", project: "payments") {} trailing: {
                        SHOptionsMenu("Thread options") { Button("Refresh Thread") {} }
                        Button {} label: { Image(systemName: SHGlyph.gitBranch.symbolName) }.buttonStyle(.shIcon(isOn: true))
                    }
                    Spacer()
                }
                BranchCardView(card: card, status: status) { _ in }
                    .shPopover()
                    .padding(.top, 52).padding(.trailing, 12)
            }
            .frame(width: 1000, height: 360)
            .background(Color.sh.bgWindow)
        }
    }
}
