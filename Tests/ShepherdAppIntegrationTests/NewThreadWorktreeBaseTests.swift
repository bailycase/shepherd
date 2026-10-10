import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// A new thread in a new worktree starts from the branch the user picked, not from where
/// Settings ▸ Worktrees points. The repository is a scratch one with `main` checked out and a
/// `release` branch one commit ahead; nothing touches a network or the user's folders.
@Suite("New thread worktree base", .integrationTimeLimit)
struct NewThreadWorktreeBaseTests {
    /// `main` checked out, `release` one commit ahead of it.
    private static func repo() throws -> URL {
        let repo = try makeScratchRepo()
        try git(["branch", "release"], in: repo)
        try git(["switch", "-q", "release"], in: repo)
        try "release\n".write(to: repo.appendingPathComponent("release.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["commit", "-qm", "release work"], in: repo)
        try git(["switch", "-q", "main"], in: repo)
        return repo
    }

    @MainActor
    @Test func sendingBranchesFromThePickedBaseAndRecordsIt() async throws {
        try StubPi.installAsEngine()
        let repo = try Self.repo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start(with: ShepherdState(spaces: [Fixture.space("proj", path: repo.path)]))
        vm.openNewThread()
        let draft = vm.newThread
        try await eventuallyOnMain("the defaults to load") { !draft.loadingDefaults }
        draft.worktree = true
        draft.worktreeBase = "release"
        draft.prompt = "tools:0 start from release"
        draft.send(vm)
        try await eventuallyOnMain("the thread to start", timeout: .seconds(60)) { vm.selectedAgentID != nil && !draft.starting }

        let agent = try #require(vm.state.agents.first)
        #expect(agent.worktreeBase == "release", "the agent records the picked base")
        let branch = try #require(agent.worktreeBranch)
        let path = try #require(agent.worktreePath)
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("release.txt").path),
                "the worktree has release's commit, which main (checked out) does not")
        #expect(try git(["rev-parse", branch], in: repo) == (try git(["rev-parse", "release"], in: repo)))
        #expect(draft.worktreeBase == nil, "the pick is spent with the thread")
    }

    @MainActor
    @Test func aPickedBranchAmongManyIsTheOneWithTheCheck() async throws {
        try StubPi.installAsEngine()
        let repo = try Self.repo()
        defer { try? FileManager.default.removeItem(at: repo) }
        for index in 0..<30 { try git(["branch", "feat/ledger-\(index)"], in: repo) }
        let app = try AppHarness()
        defer { app.stop() }
        let branches = try await app.server.changes.branches(agentID: nil, cwd: repo.path)
        let options = changesBaseOptions(branches, selected: "feat/ledger-1", includeCurrent: true)
        #expect(options.filter(\.selected).map(\.name) == ["feat/ledger-1"], "\(options.prefix(12).map { "\($0.name):\($0.selected)" })")
    }

    @MainActor
    @Test func theServersBranchListOffersTheCheckedOutBranchAsABase() async throws {
        try StubPi.installAsEngine()
        let repo = try Self.repo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let app = try AppHarness()
        defer { app.stop() }
        let branches = try await app.server.changes.branches(agentID: nil, cwd: repo.path)
        let names = changesBaseNames(branches)
        #expect(names.contains("main") && names.contains("release"), "\(names)")
        #expect(changesBaseOptions(branches, selected: "release", includeCurrent: true).filter(\.selected).map(\.name) == ["release"],
                "the picked branch is the one with the check")
    }

    /// Pressing a branch in the picker hands that exact name back.
    @Test func pressingABranchInThePickerChoosesIt() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressing() }
        }
    }

    @MainActor
    static func pressing() async throws {
        AccessibilityNode.enable()
        let repo = try Self.repo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start(with: ShepherdState(spaces: [Fixture.space("proj", path: repo.path)]))
        var chosen: [String] = []
        let window = OffscreenWindow(size: CGSize(width: 420, height: 420), dark: true,
                                     WorktreeBasePicker(vm: vm, repo: repo.path, selected: nil, choose: { chosen.append($0) }, close: {}))
        defer { window.close() }
        try await eventuallyOnMain("the branches to load") { window.layout(); return window.elements().contains { $0.label?.hasPrefix("release") == true } }
        let row = try #require(window.elements().compactMap(\.label).first { $0.hasPrefix("release") })
        try window.press(row)
        #expect(chosen == ["release"])
        // The picker marks the branch it was given as selected, to VoiceOver as the check does.
        let marked = WorktreeBasePicker(vm: vm, repo: repo.path, selected: "main", choose: { _ in }, close: {})
        let second = OffscreenWindow(size: CGSize(width: 420, height: 420), dark: true, marked)
        defer { second.close() }
        try await eventuallyOnMain("main to be marked selected") {
            second.layout(); return second.elements().contains { $0.label?.hasPrefix("main") == true && $0.isSelected }
        }
        #expect(second.elements().filter { $0.isSelected }.count == 1, "only the picked branch is marked")
        // The checked-out branch is a valid start, unlike a comparison's base.
        #expect(window.elements().contains { $0.label?.hasPrefix("main") == true })
    }
}

extension NewThreadWorktreeBaseTests {
    /// A branch picked in one project is not carried into another, whether the user changes the
    /// project or the page falls back to another because the chosen one went away.
    @MainActor
    @Test func aPickedBaseIsDroppedWhenTheProjectChanges() async throws {
        try StubPi.installAsEngine()
        let one = try Self.repo(), two = try Self.repo()
        defer { try? FileManager.default.removeItem(at: one); try? FileManager.default.removeItem(at: two) }
        let app = try AppHarness()
        defer { app.stop() }
        let first = Fixture.space("one", path: one.path), second = Fixture.space("two", path: two.path)
        let vm = try await app.start(with: ShepherdState(spaces: [first, second]))
        vm.openNewThread(in: first.id)
        let draft = vm.newThread
        draft.worktreeBase = "release"
        draft.choose(host: nil, space: first.id, vm: vm)
        #expect(draft.worktreeBase == "release", "choosing the same project keeps the pick")
        draft.choose(host: nil, space: second.id, vm: vm)
        #expect(draft.worktreeBase == nil, "another project starts with none")

        draft.worktreeBase = "release"
        vm.deleteSpace(second.id)
        try await eventuallyOnMain("the project to go") { !vm.state.spaces.contains { $0.id == second.id } }
        draft.prepare(for: vm)
        #expect(draft.place?.space == first.id)
        #expect(draft.worktreeBase == nil, "the fallback project does not inherit the gone project's pick")
    }

    /// A picked `origin/main` follows Settings ▸ Worktrees ▸ Fetch before creating, as the default
    /// base does: on, the worktree starts at the remote's newest commit; off, at the cached one.
    @MainActor
    @Test(arguments: [true, false])
    func aPickedRemoteBranchHonoursFetchBeforeCreating(fetch: Bool) async throws {
        try StubPi.installAsEngine()
        let sandbox = try WorktreeSandbox(origin: true)
        defer { sandbox.remove() }
        // Someone else pushes after this checkout last fetched.
        let other = sandbox.root.appendingPathComponent("other")
        try git(["clone", "-q", sandbox.origin.path, other.path], in: sandbox.root)
        try git(["config", "user.name", "T"], in: other)
        try git(["config", "user.email", "t@example.com"], in: other)
        try "new\n".write(to: other.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: other)
        try git(["commit", "-qm", "newer"], in: other)
        try git(["push", "-q", "origin", "main"], in: other)
        let cached = try git(["rev-parse", "origin/main"], in: sandbox.repo)
        let newest = try git(["rev-parse", "HEAD"], in: other)
        #expect(cached != newest)

        let app = try AppHarness()
        defer { app.stop() }
        app.settings.worktreeFetchBeforeCreate = fetch
        let vm = try await app.start(with: ShepherdState(spaces: [Fixture.space("proj", path: sandbox.repo.path)]))
        vm.openNewThread()
        let draft = vm.newThread
        try await eventuallyOnMain("the defaults to load") { !draft.loadingDefaults }
        draft.worktree = true
        draft.worktreeBase = "origin/main"
        draft.prompt = "tools:0 from the remote"
        draft.send(vm)
        try await eventuallyOnMain("the thread to start", timeout: .seconds(60)) { vm.selectedAgentID != nil && !draft.starting }
        let agent = try #require(vm.state.agents.first)
        #expect(agent.worktreeBase == "origin/main", "the pick is kept whatever the fetch did")
        let head = try git(["rev-parse", try #require(agent.worktreeBranch)], in: sandbox.repo)
        #expect(head == (fetch ? newest : cached))
    }

    /// The workplace menu's own controls, pressed as VoiceOver does: the project chip opens the menu,
    /// the New worktree switch turns on its Base row, the row opens the picker, a branch applies.
    @Test func theWorkplaceMenusBaseRowOpensThePickerAndAppliesTheBranch() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pickingThroughTheWorkplaceMenu() }
        }
    }

    @MainActor
    static func pickingThroughTheWorkplaceMenu() async throws {
        AccessibilityNode.enable()
        try StubPi.installAsEngine()
        let repo = try Self.repo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start(with: ShepherdState(spaces: [Fixture.space("proj", path: repo.path)]))
        vm.openNewThread()
        let draft = vm.newThread
        try await eventuallyOnMain("the defaults to load") { !draft.loadingDefaults }
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 800), dark: true, NewThreadPage(vm: vm, chrome: PageHeaderChrome()))
        defer { window.close() }

        try window.press("Where it runs: proj on This Mac")
        try await eventuallyOnMain("the workplace menu") { window.element("Where the thread runs") != nil }
        #expect(window.element("Base branch: Default") == nil, "no Base row while New worktree is off")

        // The switch is an accessibility switch or checkbox, whichever this SDK reports.
        let toggle = window.controls().first { $0.label == "New worktree" }
        try #require(toggle != nil, "the switch is a control: \(window.controls())")
        try window.press("New worktree", role: try #require(toggle).role)
        try await eventuallyOnMain("the switch to turn on") { draft.worktree }
        #expect(draft.worktreeBase == nil, "nothing is picked until the user picks")

        // The Base row is a button to VoiceOver and takes the whole row.
        let row = try window.press("Base branch: Default")
        #expect(row.frame.height >= 24 && row.frame.width > 200, "a row, not just its words: \(row)")
        try await eventuallyOnMain("the branch picker") { window.element("Branch from") != nil || window.elements().contains { $0.label?.hasPrefix("release") == true } }
        try await eventuallyOnMain("the branches to load") { window.elements().contains { $0.label?.hasPrefix("release") == true } }
        #expect(draft.worktreeBase == nil, "opening the picker picks nothing")

        let release = try #require(window.elements().compactMap(\.label).first { $0.hasPrefix("release") })
        try window.press(release)
        #expect(draft.worktreeBase == "release", "the model got the exact branch")
        try await eventuallyOnMain("the picker to close") { !window.elements().contains { $0.label?.hasPrefix("release") == true } }

        // Reopening the workplace menu shows the pick on the row, and the caption names it.
        try window.press("Where it runs: proj on This Mac")
        try await eventuallyOnMain("the Base row to name the pick") { window.element("Base branch: release") != nil }
    }
}

extension NewThreadWorktreeBaseTests {
    /// The New Worktree sheet's Choose… link opens the picker, and a branch fills the Base field,
    /// which Create and open then branches from.
    @Test func theSheetsChooseLinkOpensThePickerAndFillsTheBase() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.choosingInTheSheet() }
        }
    }

    @MainActor
    static func choosingInTheSheet() async throws {
        AccessibilityNode.enable()
        try StubPi.installAsEngine()
        let repo = try Self.repo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("proj", path: repo.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))
        let window = OffscreenWindow(size: CGSize(width: 700, height: 520), dark: true, NewWorktreeSheet(vm: vm, space: space))
        defer { window.close() }
        try await eventuallyOnMain("the base to resolve") { window.layout(); return window.controls().first { $0.label == "Create and open" }?.isEnabled == true }

        let link = try window.press("Choose…")
        #expect(link.frame.height >= 24, "the link is a real target: \(link)")
        // The picker is a popover: its own window, so read every window of the app.
        func rows() -> [AccessibilityNode] {
            NSApp.windows.flatMap { w -> [AccessibilityNode] in
                guard let content = w.contentView else { return [] }
                content.layoutSubtreeIfNeeded()
                return AccessibilityNode.all(under: content)
            }
        }
        try await eventuallyOnMain("the picker to list release") { rows().contains { $0.label?.hasPrefix("release") == true } }
        let release = try #require(rows().first { $0.label?.hasPrefix("release") == true })
        #expect(release.press())
        try await eventuallyOnMain("the Base field to say release") {
            window.layout()
            return window.elements().contains { $0.value == "release" }
        }
        try window.press("Create and open")
        try await eventuallyOnMain("the agent to be made", timeout: .seconds(60)) { vm.state.agents.first != nil }
        #expect(vm.state.agents.first?.worktreeBase == "release")
        let branch = try #require(vm.state.agents.first?.worktreeBranch)
        #expect(try git(["rev-parse", branch], in: repo) == (try git(["rev-parse", "release"], in: repo)), "the branch starts at release")
    }
}

private func changesBaseNames(_ branches: ChangesBranches) -> [String] {
    changesBaseOptions(branches, selected: nil, includeCurrent: true).map(\.name)
}
