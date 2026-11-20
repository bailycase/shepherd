import ShepherdCore
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

extension PreviewTests {
    @Test func supervisionCommandsAndReview() async throws {
        let repo = try makeScratchRepo(files: ["ledger/outbox.go": "package ledger\n"])
        defer { try? FileManager.default.removeItem(at: repo) }
        try "package ledger\n\nconst refundCreated = \"refund.created\"\n"
            .write(to: repo.appendingPathComponent("ledger/outbox.go"), atomically: true, encoding: .utf8)
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let space = Space(name: "acme-web", path: repo.path)
        var (question, questionTab) = try await workspace.agent("Approve rollout", in: space, order: 0, status: .blocked)
        var (old, oldTab) = try await workspace.agent("Add refund events", in: space, order: 1, status: .done)
        var (new, newTab) = try await workspace.agent("Tighten retry limits", in: space, order: 2, status: .done)
        question.waitingOn = "Approve a gradual rollout?"
        old.completedAt = 1000
        new.completedAt = 2000
        old.checkout = AgentCheckout(branch: "feature/refund-events", changedFiles: 2)
        new.checkout = AgentCheckout(branch: "feature/retry-limits", changedFiles: 1)
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [questionTab, oldTab, newTab], agents: [question, old, new]))
        let vm = workspace.vm
        vm.openNewThread()
        #expect(vm.nextNeedingYouRow == .local(question.id))
        let menu = MenuState.Snapshot(vm)
        #expect(menu.hasNextNeedingYou)
        #expect(menu.reviewQueueCount == 2)
        try await Preview.render("supervision-agent-menu", size: CGSize(width: 540, height: 230)) {
            // A representation of the two menu rows; opening AppKit's menu would take focus.
            SHListCard {
                SHListRow(ShortcutAction.nextNeedingYou.title, trailing: .value(vm.keybindings.display(.nextNeedingYou)), chevron: false)
                SHListRow(MenuState.reviewNextTitle(count: menu.reviewQueueCount), trailing: .value(vm.keybindings.display(.reviewNext)), chevron: false)
            }
            .padding(SH.Space.xxl)
            .frame(maxHeight: .infinity)
            .background(Color.sh.bgWindow)
        }
        try await Preview.render("supervision-palette", size: CGSize(width: 900, height: 480)) {
            Color.sh.bgWindow.shCommandPalette(isPresented: .constant(true)) {
                PaletteCard(items: vm.paletteItems, run: { vm.runPaletteItem($0) }, close: {}, initialQuery: "next")
            }
        }
        vm.openNextNeedingYou()
        #expect(vm.selectedSidebarRow == .local(question.id))
        vm.openReviewNext()
        #expect(vm.selectedSidebarRow == .local(old.id))
        #expect(vm.subagentInspector.tab(for: .local(old.id)) == .changes)
        #expect(vm.isRightPaneOpen)
        vm.advanceQueuedReview(for: .local(new.id))
        #expect(vm.selectedSidebarRow == .local(old.id))
        vm.advanceQueuedReview(for: .local(old.id))
        #expect(vm.selectedSidebarRow == .local(new.id))
        #expect(vm.isRightPaneOpen)
        #expect(vm.reviewQueueCount == 1)
        try await Preview.render("supervision-changes", size: CGSize(width: 1300, height: 780), ready: {
            vm.reviewSessions.values.contains { $0.agentID == new.id && !$0.files.isEmpty && !$0.isLoading }
        }) {
            RootView(vm: vm)
        }

        vm.settingsSection = .keyboard
        try await Preview.render("supervision-keyboard", size: CGSize(width: 1280, height: 900)) {
            SettingsView(vm: vm)
        }
    }
}
