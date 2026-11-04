import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestKit
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Issues & PRs (PRReview*, IssueReview, IssueStarted, PRSidebarPinned) in the boards' window,
/// read from a real server whose gh is the recorded fake (`ForgeFixtures`): the store, the
/// server's parsing and linking, and the views all run as in the app.
extension PreviewTests {
    private static let forgeWindow = CGSize(width: 1440, height: 900)
    /// The boards' sidebar (the user can resize it there).
    private static let forgeSidebar: CGFloat = 280
    /// Two hours after the fixtures' last update.
    private static let forgeNow = ISO8601DateFormatter().date(from: "2026-11-03T14:00:00Z")!

    /// The fake gh, with `edit` rewriting an answer (a draft, merged or closed #31; an empty list).
    private static func forgeRunner(_ edit: @escaping @Sendable (String, String) -> String = { $1 }) -> ForgeService.Runner {
        { command in
            let (output, status, errors) = ForgeFixtures.answer(command.arguments)
            return ForgeOutput(output: Data(edit(command.arguments.joined(separator: " "), output).utf8), errors: errors, status: status)
        }
    }

    /// A space on the fixture checkout and its threads: #31's on agent/refund-events (with a
    /// worktree), and with `issueThread`, one started from #34.
    private func forgeWorkspace(_ runner: @escaping ForgeService.Runner = PreviewTests.forgeRunner(),
                                issueThread: Bool = false) async throws -> PreviewWorkspace {
        _ = NSApplication.shared
        let workspace = try PreviewWorkspace(forgeRunner: runner)
        let space = Space(name: "payments", path: workspace.dir.path)
        var (agent, tab) = try await workspace.agent("Add refund events", in: space, order: 0, status: .working)
        agent.worktreeBranch = "agent/refund-events"
        agent.worktreePath = workspace.dir.path + "-refund"
        var agents = [agent], tabs = [tab]
        if issueThread {
            var (started, startedTab) = try await workspace.agent("Fix partial refund rounding", in: space, order: 1, status: .working)
            started.worktreeBranch = ForgeLinks.issueBranch(number: 34, title: "Partial refunds round down by a cent")
            agents.append(started); tabs.append(startedTab)
        }
        try await workspace.seed(ShepherdState(spaces: [space], tabs: tabs, agents: agents))
        workspace.vm.forgeStore.now = { Self.forgeNow }
        return workspace
    }

    /// The window as the boards draw it: the destination's list in the sidebar, the page beside it.
    private func forgeWindow(_ vm: ShepherdViewModel, @ViewBuilder page: () -> some View) -> some View {
        HStack(spacing: 0) {
            SHSidebar(topBar: SHSidebarTopBar(search: {}, hide: {})) {
                ForgeSidebarPanel(vm: vm)
            } footer: {
                SHSidebarFooter(name: "Baily", detail: "This Mac · build-01", settingsShortcut: "⌘,") {}
            }
            .frame(width: Self.forgeSidebar)
            SHHairline(.vertical)
            page().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.sh.bgWindow)
    }

    private func openForge(_ vm: ShepherdViewModel, _ kind: ForgeKind, _ number: Int) async {
        let ref = ForgeItemRef(kind: kind, repo: ForgeFixtures.repo, number: number)
        await vm.forgeStore.start(opening: ref)
        await vm.forgeStore.open(ref)
    }

    @Test func forgePullRequest() async throws {
        let workspace = try await forgeWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        await openForge(vm, .pullRequest, 31)
        try await Preview.render("forge-pr", size: Self.forgeWindow, ready: { vm.forgeStore.pullRequest != nil }) {
            forgeWindow(vm) { ForgeDestination(vm: vm) }
        }
    }

    @Test func forgePullRequestTeam() async throws {
        let workspace = try await forgeWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        await openForge(vm, .pullRequest, 31)
        await vm.forgeStore.toggleSection(.teamReview)
        try await Preview.render("forge-pr-team", size: Self.forgeWindow, ready: { vm.forgeStore.pullRequest != nil }) {
            forgeWindow(vm) { ForgeDestination(vm: vm) }
        }
    }

    @Test func forgePullRequestMergeMenu() async throws {
        let workspace = try await forgeWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        await openForge(vm, .pullRequest, 31)
        let detail = try #require(vm.forgeStore.pullRequest)
        try await Preview.render("forge-pr-merge-menu", size: CGSize(width: 360, height: 420)) {
            ForgeMergeMenu(store: vm.forgeStore, detail: detail) {}.padding(SH.Space.l).background(Color.sh.bgWindow)
        }
    }

    @Test func forgePullRequestChanges() async throws {
        let workspace = try await forgeWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        await openForge(vm, .pullRequest, 31)
        vm.forgeStore.tab = .changes
        try await Preview.render("forge-pr-changes", size: Self.forgeWindow, ready: { vm.forgeStore.files != nil }) {
            forgeWindow(vm) { ForgeDestination(vm: vm) }
        }
    }

    @Test func forgePullRequestChecks() async throws {
        let workspace = try await forgeWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        await openForge(vm, .pullRequest, 31)
        vm.forgeStore.tab = .checks
        try await Preview.render("forge-pr-checks", size: Self.forgeWindow, ready: { !vm.forgeStore.logs.isEmpty }) {
            forgeWindow(vm) { ForgeDestination(vm: vm) }
        }
    }

    /// Draft, merged and closed: #31's view rewritten.
    @Test(arguments: [
        ("draft", #""isDraft":false"#, #""isDraft":true"#),
        ("merged", #""state":"OPEN","isDraft":false"#, #""state":"MERGED","isDraft":false"#),
        ("closed", #""state":"OPEN","isDraft":false"#, #""state":"CLOSED","isDraft":false"#),
    ])
    func forgePullRequestState(name: String, from: String, to: String) async throws {
        let runner = Self.forgeRunner { line, output in
            guard line.hasPrefix("gh pr view 31"), !line.contains("isCrossRepository") else { return output }
            var next = output.replacingOccurrences(of: from, with: to)
            if name == "merged" { next = next.replacingOccurrences(of: #""mergeCommit":null"#, with: #""mergeCommit":{"oid":"7d41c0a9"}"#) }
            return next
        }
        let workspace = try await forgeWorkspace(runner)
        defer { workspace.stop() }
        let vm = workspace.vm
        await openForge(vm, .pullRequest, 31)
        try await Preview.render("forge-pr-\(name)", size: Self.forgeWindow, ready: { vm.forgeStore.pullRequest != nil }) {
            forgeWindow(vm) { ForgeDestination(vm: vm) }
        }
    }

    @Test func forgeLoading() async throws {
        let workspace = try await forgeWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        await vm.forgeStore.start()
        try await Preview.render("forge-loading", size: Self.forgeWindow) {
            forgeWindow(vm) {
                VStack(spacing: 0) {
                    ForgeHeaderBar(chrome: PageHeaderChrome()) { EmptyView() } trailing: { EmptyView() }
                    ForgeLoadingPage(number: 31)
                }
            }
        }
    }

    @Test func forgeEmpty() async throws {
        let runner = Self.forgeRunner { line, output in line.hasPrefix("gh pr list") ? "[]" : output }
        let workspace = try await forgeWorkspace(runner)
        defer { workspace.stop() }
        let vm = workspace.vm
        await vm.forgeStore.start()
        try await Preview.render("forge-empty", size: Self.forgeWindow, ready: { vm.forgeStore.loadingKinds.isEmpty }) {
            forgeWindow(vm) { ForgeDestination(vm: vm) }
        }
    }

    /// No gh on the host: the page says so and how to fix it.
    @Test func forgeGhMissing() async throws {
        let workspace = try await forgeWorkspace { command in
            command.arguments.first == "gh" ? ForgeOutput(errors: "gh: command not found", status: 127)
                : await PreviewTests.forgeRunner()(command)
        }
        defer { workspace.stop() }
        let vm = workspace.vm
        await vm.forgeStore.start()
        try await Preview.render("forge-gh-missing", size: Self.forgeWindow, ready: { vm.forgeStore.error != nil }) {
            forgeWindow(vm) { ForgeDestination(vm: vm) }
        }
    }

    @Test(arguments: [false, true])
    func forgeIssue(started: Bool) async throws {
        let workspace = try await forgeWorkspace(issueThread: started)
        defer { workspace.stop() }
        let vm = workspace.vm
        await openForge(vm, .issue, 34)
        try await Preview.render(started ? "forge-issue-started" : "forge-issue", size: Self.forgeWindow,
                                 ready: { vm.forgeStore.issue != nil }) {
            forgeWindow(vm) { ForgeDestination(vm: vm) }
        }
    }

    /// The main sidebar with Issues & PRs' row and a pinned pull request (PRSidebarPinned).
    @Test func forgeSidebarPinned() async throws {
        let workspace = try await forgeWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        let ref = ForgeItemRef(kind: .pullRequest, repo: ForgeFixtures.repo, number: 31)
        await vm.forgeStore.perform(.setPinned(ref: ref, title: "Add refund events to the ledger outbox", pinned: true))
        await vm.forgeStore.loadSidebar()
        vm.selectAgent(try #require(vm.state.agents.first).id)
        try await Preview.render("forge-sidebar-pinned", size: CGSize(width: Self.forgeSidebar, height: 600),
                                 ready: { vm.forgeStore.sidebar?.pins.first?.pullRequest != nil }) {
            SidebarView(vm: vm).frame(width: Self.forgeSidebar)
        }
    }
}
