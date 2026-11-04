import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Forge layout and navigation", .mainActorExclusive)
@MainActor
struct ForgeLayoutTests {
    @Test func narrowSidebarKeepsControlsInBoundsAndReturnsToTheThread() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.sidebarScenario() }
        }
        expectScenarioCompleted(result)
    }

    private static func sidebarScenario() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("Existing thread", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let repo = "acme/a-repository-name-that-is-wider-than-the-sidebar"
        vm.forgeStore = ForgeStore { request in
            switch request {
            case .repos: .success(.repos([ForgeRepo(nameWithOwner: repo, path: app.dir.path)]))
            case .list(let kind, _, _): .success(.list(ForgeList(kind: kind, repo: repo, sections: [])))
            case .sidebar: .success(.sidebar(ForgeSidebar(pins: [], needsYou: 0)))
            default: .failure(ForgeError(.notFound, "No fixture for this request"))
            }
        }
        await vm.forgeStore.start()
        let mounted = vm.mountedTabs.map(\.id)
        for dark in [false, true] {
            for width in [AppLayout.sidebarMinWidth, AppLayout.sidebarDefaultWidth, AppLayout.sidebarMaxWidth] {
                vm.selectAgent(agent.agent.id)
                vm.openDestination(.forge)
                let window = OffscreenWindow(size: CGSize(width: width, height: 700), dark: dark,
                                             ForgeSidebarPanel(vm: vm))
                defer { window.close() }
                try await eventuallyOnMain("the return action to appear") {
                    window.layout()
                    return ControlPress.controls(in: window.host).contains { $0.label == "Back to threads" }
                }
                let bounds = window.window.convertToScreen(window.host.convert(window.host.bounds, to: nil))
                let nodes = AccessibilityNode.all(under: window.host)
                let roles = ControlRole.actionable.union(["AXTextField", "AXStaticText"])
                for node in nodes where roles.contains(node.role ?? "") && !node.frame.isEmpty {
                    #expect(node.frame.minX >= bounds.minX - 1 && node.frame.maxX <= bounds.maxX + 1,
                            "\(node.label ?? node.value ?? node.role ?? "element") overflows the \(width)pt sidebar: \(node.frame), bounds \(bounds)")
                }
                let controls = ControlPress.controls(in: window.host)
                let repository = try #require(nodes.first { $0.label == "Repository" || $0.value == repo },
                                              "Repository menu missing from accessibility tree: \(nodes.map { "\($0.role ?? "?"): \($0.label ?? "") = \($0.value ?? "")" })")
                #expect(!repository.actionNames.isEmpty, "the repository picker is actionable")
                #expect(controls.contains { $0.label?.hasPrefix("Pull requests") == true })
                _ = try ControlPress.press("Back to threads", under: window.host)
                #expect(vm.shownDestination == nil)
                #expect(vm.selectedAgentID == agent.agent.id)
                #expect(vm.mountedTabs.map(\.id) == mounted, "returning does not remount the thread")
            }
        }
        vm.openDestination(.forge)
        let window = OffscreenWindow(size: CGSize(width: AppLayout.windowMinWidth, height: 700),
                                     ForgeDestination(vm: vm, chrome: PageHeaderChrome(leadingInset: AppLayout.trafficLightInset,
                                                                                     showSidebar: {})))
        defer { window.close() }
        try await eventuallyOnMain("a visible return action while the sidebar is hidden") {
            window.layout()
            return ControlPress.controls(in: window.host).contains { $0.label == "Back to threads" }
        }
        #expect(window.host.bounds.width <= AppLayout.windowMinWidth + 1)
        #expect(window.host.bounds.height <= 701, "the empty header must not expand the window")
        _ = try ControlPress.press("Back to threads", under: window.host)
        #expect(vm.shownDestination == nil)
        #expect(vm.selectedAgentID == agent.agent.id)
    }

    @Test func leavingForgeWithoutAThreadShowsNewThread() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        vm.openDestination(.forge)
        vm.leaveForge()
        #expect(vm.shownDestination == .newThread)
        #expect(vm.state.agents.isEmpty)
    }
}
