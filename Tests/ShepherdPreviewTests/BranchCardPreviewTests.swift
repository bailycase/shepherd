import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The thread's branch card (BranchCard board) over a real thread's top right, wide and folded, light
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

        let store = BranchCardStore(handle: BranchCardHandle(agentID: me.id, card: { card }, load: { _ in status }, perform: { _ in }))
        let fixture = ThreadFixture(Threads.idle)
        defer { fixture.store.stop() }
        // Wide: the card docked in its column, the transcript centered in the rest. Narrow (the
        // side pane open, a small window): one folded row.
        for (name, width) in [("wide", 1500.0), ("medium", 1100.0), ("narrow", 900.0)] {
            try await Preview.render("branch-card-\(name)", size: CGSize(width: width, height: 640),
                                     ready: { fixture.store.ready && !fixture.store.rows.isEmpty && store.status != nil }) {
                fixture.thread(title: "Add refund events")
                    .modifier(BranchCardDock(store: store, branch: card.branch, active: true))
            }
        }
    }

    /// A clone on agent/refund-events that is behind origin, with other branches local, remote and
    /// in another worktree, for the pickers and sheets.
    private func clone() throws -> (origin: URL, clone: URL) {
        let origin = try makeScratchRepo(files: ["ledger/outbox.go": "a\nb\n", "ledger/refund_test.go": "t\n"])
        let clone = try makeScratchDirectory("clone")
        try git(["clone", "-q", origin.path, clone.path], in: clone.deletingLastPathComponent())
        for args in [["config", "user.name", "T"], ["config", "user.email", "t@example.com"], ["branch", "baily/ledger-refactor"],
                     ["switch", "-qc", "agent/refund-events"]] {
            try git(args, in: clone)
        }
        try git(["branch", "sam/payout-ui"], in: origin)
        try git(["fetch", "-q"], in: clone)
        return (origin, clone)
    }

    /// The card's › and Switch branch: the picker in the card's place, from the clone's real branches.
    @Test func theSwitchBranchPicker() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let (origin, clone) = try clone()
        defer { for url in [origin, clone] { try? FileManager.default.removeItem(at: url) } }
        try await Preview.render("branch-picker-switch", size: CGSize(width: 380, height: 360)) {
            BranchPickerMenu(title: "Switch branch", selected: "agent/refund-events", load: { try await workspace.vm.branchPickerList(cwd: clone.path) },
                             choose: { _ in }, newBranch: {}, fetch: {}, close: {})
                .padding(SH.Space.xl)
                .frame(width: 380, height: 360, alignment: .top)
                .background(Color.sh.bgWindow)
        }
    }

    /// Switch branch from a worktree: main (in the main checkout) and another thread's worktree
    /// branch move the thread there; while it runs, the rows say why they can't.
    @Test func theSwitchBranchPickerMovesToAnotherCheckout() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let (origin, clone) = try clone()
        let worktree = clone.deletingLastPathComponent().appendingPathComponent(clone.lastPathComponent + "-webhooks")
        let payout = clone.deletingLastPathComponent().appendingPathComponent(clone.lastPathComponent + "-payout")
        defer { for url in [origin, clone, worktree, payout] { try? FileManager.default.removeItem(at: url) } }
        try git(["switch", "-q", "main"], in: clone)
        try git(["worktree", "add", "-q", "-b", "agent/webhook-retries", worktree.path], in: clone)
        try git(["worktree", "add", "-q", "--no-track", "-b", "sam/payout-ui", payout.path, "origin/sam/payout-ui"], in: clone)
        var list = try await workspace.vm.branchPickerList(cwd: worktree.path)
        list.threads[ShepherdViewModel.standard(PiSessionFolder.realPath(payout.path))] = "Payout screen"
        for busy in [nil, "running"] as [String?] {
            list.busy = busy
            let shown = list
            try await Preview.render(busy == nil ? "branch-picker-move" : "branch-picker-move-running", size: CGSize(width: 420, height: 360)) {
                BranchPickerMenu(title: "Switch branch", selected: "agent/webhook-retries", load: { shown },
                                 choose: { _ in }, move: { _, _ in }, newBranch: {}, fetch: {}, close: {})
                    .padding(SH.Space.xl)
                    .frame(width: 420, height: 360, alignment: .top)
                    .background(Color.sh.bgWindow)
            }
        }
    }

    /// The new thread's ⚙ (BranchWhereItRuns) and its Branch picker (BranchPicker).
    @Test func theNewThreadWhereItRunsAndBranchPicker() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let (origin, clone) = try clone()
        defer { for url in [origin, clone] { try? FileManager.default.removeItem(at: url) } }
        try await Preview.render("where-it-runs", size: CGSize(width: 760, height: 380)) {
            HStack(alignment: .top, spacing: SH.Space.xxl) {
                WhereItRunsMenu(worktree: true, branch: "new from main", base: "origin/main", host: "This Mac", local: true,
                                setWorktree: { _ in }, chooseBranch: {}, chooseBase: {})
                BranchPickerMenu(first: "New branch from main", selected: nil, load: { try await workspace.vm.branchPickerList(cwd: clone.path) },
                                 choose: { _ in }, newBranch: {}, fetch: {}, close: {})
            }
            .padding(SH.Space.xl)
            .frame(width: 760, height: 380, alignment: .topLeading)
            .background(Color.sh.bgWindow)
        }
    }

    /// Update from main: ready, then stopped on a real rebase conflict.
    @Test func theUpdateSheet() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let (origin, clone) = try clone()
        defer { for url in [origin, clone] { try? FileManager.default.removeItem(at: url) } }
        for (file, ours, theirs) in [("ledger/outbox.go", "a\nours\n", "a\ntheirs\n"), ("ledger/refund_test.go", "ours\n", "theirs\n")] {
            try ours.write(to: clone.appendingPathComponent(file), atomically: true, encoding: .utf8)
            try git(["commit", "-qam", "ours \(file)"], in: clone)
            try theirs.write(to: origin.appendingPathComponent(file), atomically: true, encoding: .utf8)
            try git(["commit", "-qam", "theirs \(file)"], in: origin)
        }
        for n in 1...2 { try git(["commit", "-q", "--allow-empty", "-m", "ours \(n)"], in: clone) }
        guard case .conflict(let conflict) = try BranchGit.update(cwd: clone.path, base: "main", rebase: true) else {
            Issue.record("no conflict"); return
        }
        let id = AgentID()
        for (name, stage) in [("ready", BranchUpdateSheet.Stage.ready(behind: 3)), ("conflict", .conflict(conflict))] {
            try await Preview.render("branch-update-\(name)", size: CGSize(width: AppLayout.branchSheetWidth, height: 360)) {
                BranchUpdateSheet(vm: workspace.vm, agentID: id, branch: "agent/refund-events", recordedBase: "main", cwd: clone.path, staged: stage)
            }
        }
        try BranchGit.abort(cwd: clone.path, .rebase)
    }

    /// Commit… (BranchCommit): four of five changed files ticked, a generated message, and an
    /// unpushed last commit Amend could replace; then Amend ticked on a pushed commit, Commit &
    /// push off with the line saying why.
    @Test func theCommitSheet() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let (origin, clone) = try clone()
        defer { for url in [origin, clone] { try? FileManager.default.removeItem(at: url) } }
        try BranchGit.push(cwd: clone.path, branch: "agent/refund-events")
        let outbox = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try git(["commit", "-q", "--allow-empty", "-m", "Emit refund events from the ledger outbox"], in: clone)
        for (file, text) in [("ledger/outbox.go", outbox), ("ledger/codec.go", "codec\n"), ("ledger/refund.go", "refund\n"),
                             ("ledger/refund_test.go", "test\n"), ("scratch/notes.md", "")] {
            let url = clone.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let info = try await ReviewCommitGit.info(cwd: clone.path, agentWorking: false, draftsMessage: false) { await LoginShell.run($0, cwd: $1) }
        let form = BranchCommitSheet.Form(info: info, selected: Set(info.files.map(\.id).filter { !$0.hasPrefix("scratch/") }),
                                          title: "Emit refund events from the ledger outbox",
                                          details: "Adds RefundEvent with a JSON codec and covers encode and decode in refund_test.go.",
                                          amendBlocked: BranchGit.amendBlocked(cwd: clone.path))
        try await Preview.render("branch-commit", size: CGSize(width: AppLayout.branchCommitSheetWidth, height: 500)) {
            BranchCommitSheet(vm: workspace.vm, agentID: AgentID(), cwd: clone.path, staged: form)
        }
        try BranchGit.push(cwd: clone.path, branch: "agent/refund-events")
        var pushed = form
        pushed.pushedTo = BranchGit.pushedTo(cwd: clone.path)
        #expect(pushed.pushedTo == "origin/agent/refund-events")
        try await Preview.render("branch-commit-amend-pushed", size: CGSize(width: AppLayout.branchCommitSheetWidth, height: 520)) {
            BranchCommitSheet(vm: workspace.vm, agentID: AgentID(), cwd: clone.path, staged: pushed, amend: true)
        }
    }

    @Test func theNameSheets() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let (origin, clone) = try clone()
        defer { for url in [origin, clone] { try? FileManager.default.removeItem(at: url) } }
        for rename in [false, true] {
            try await Preview.render(rename ? "branch-rename" : "branch-new", size: CGSize(width: AppLayout.branchSheetWidth, height: 220)) {
                BranchNameSheet(vm: workspace.vm, agentID: AgentID(), branch: "agent/refund-events", cwd: clone.path, rename: rename)
            }
        }
    }
}
