import AppKit
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

extension ListPerformanceTests {
    /// The new-worktree base picker over a repository with 300 branches builds the rows that fit
    /// its 300pt list, and scrolling builds the rows that come into view, never every branch.
    @Test func theWorktreeBasePickerOverThreeHundredBranchesBuildsOnlyVisibleRows() async throws {
        try StubPi.installAsEngine()
        let repo = try makeScratchRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // One write for every ref: each branch points at the initial commit (packed-refs, which git
        // reads like loose refs), not 300 `git branch` processes.
        let head = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let packed = "# pack-refs with: peeled fully-peeled sorted \n"
            + (0..<300).map { "\(head) refs/heads/feat/ledger-\(String(format: "%03d", $0))\n" }.joined()
        try packed.write(to: repo.appendingPathComponent(".git/packed-refs"), atomically: true, encoding: .utf8)
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let branches = try await app.server.changes.branches(agentID: nil, cwd: repo.path)
        #expect(branches.branches.count >= 300)

        let size = CGSize(width: 380, height: 460)
        var window: OffscreenWindow!
        let onScreen = Int(ChangesMenuLayout.listMaxHeight / NWChangesMenuMetrics.rowHeight) + 1
        // Counted from before the window opens until the branches are in and drawn.
        NWRenderProbe.start()
        window = OffscreenWindow(size: size, dark: true, WorktreeBasePicker(vm: vm, repo: repo.path, selected: nil, choose: { _ in }, close: {}))
        defer { window.close() }
        try await eventuallyOnMain("the branches to load") {
            ListPerf.settle(window)
            return NWRenderProbe.count("changes.menu.row") > 0
        }
        ListPerf.settle(window)
        let opened = NWRenderProbe.stop()
        #expect(opened["changes.menu.row", default: 0] <= 2 * onScreen, "opening builds the rows that fit: \(opened)")

        let scroll = try #require(ListPerf.scrollView(in: window))
        // The 300pt window, not 300 rows tall: the list scrolls inside the menu.
        #expect(scroll.frame.height <= ChangesMenuLayout.listMaxHeight + 1, "\(scroll.frame)")
        let step = NWChangesMenuMetrics.rowHeight * 4
        var moved: CGFloat = 0
        let scrolled = ListPerf.counting { moved = ListPerf.scroll(window, scroll, step: step, steps: 20).distance }
        let arriving = Int(moved / NWChangesMenuMetrics.rowHeight) + 1
        #expect(moved > 0)
        #expect(scrolled["changes.menu.row", default: 0] <= 2 * (arriving + onScreen), "\(scrolled)")
        #expect(scrolled["changes.menu.row", default: 0] < 300, "never every branch: \(scrolled)")
    }
}
