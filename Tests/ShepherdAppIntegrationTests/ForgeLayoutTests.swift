import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Issues & PRs at the widths the window allows (#423): every control and line of text stays inside
/// its column at text sizes 1 and 1.3, the window keeps the size it was given, and Back to threads
/// returns to the thread it covered without remounting it.
@Suite("Forge layout and navigation", .mainActorExclusive)
@MainActor
struct ForgeLayoutTests {
    static let scales: [CGFloat] = [1, 1.3]
    static let longRepo = "acme/a-repository-name-that-is-wider-than-the-sidebar"

    @Test func theSidebarFitsEveryWidthAndBackReturnsToTheThread() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.sidebar() }
        }
        expectScenarioCompleted(result)
    }

    @Test func emptyAndPopulatedPagesKeepTheirWindowAndHeaderControlsInside() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.pages() }
        }
        expectScenarioCompleted(result)
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

    // MARK: Scenarios

    private static func sidebar() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("Existing thread", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.forgeStore = emptyStore(repo: longRepo, path: app.dir.path)
        await vm.forgeStore.start()
        let mounted = vm.mountedTabs.map(\.id)
        defer { ThemeStore.shared.textScale = 1 }
        for scale in scales {
            ThemeStore.shared.textScale = scale
            for dark in [false, true] {
                for width in [AppLayout.sidebarMinWidth, AppLayout.sidebarDefaultWidth, AppLayout.sidebarMaxWidth] {
                    let place = "\(Int(width))pt at text size \(scale)"
                    vm.selectAgent(agent.agent.id)
                    vm.openDestination(.forge)
                    let window = OffscreenWindow(size: CGSize(width: width, height: 700), dark: dark, ForgeSidebarPanel(vm: vm))
                    defer { window.close() }
                    try await eventuallyOnMain("the return action to appear at \(place)") {
                        window.layout()
                        return ControlPress.controls(in: window.host).contains { $0.label == "Back to threads" }
                    }
                    expectInside(window, place)
                    let nodes = AccessibilityNode.all(under: window.host)
                    // A native menu button names itself by its tooltip.
                    let repository = nodes.first { $0.role == ControlRole.menuButton && help($0) == "Repository: All repositories" }
                    #expect(repository?.isEnabled == true, "the repository picker is an enabled menu button at \(place)")
                    #expect(nodes.contains { $0.role == ControlRole.menuButton && help($0) == "More" }, "More at \(place)")
                    let kinds = ControlPress.controls(in: window.host).compactMap(\.label)
                    #expect(kinds.contains("Issues, 0") && kinds.contains("Pull requests, 0"), "both kinds at \(place): \(kinds)")
                    try ControlPress.press("Back to threads", under: window.host)
                    #expect(vm.shownDestination == nil)
                    #expect(vm.selectedAgentID == agent.agent.id)
                    #expect(vm.mountedTabs.map(\.id) == mounted, "returning does not remount the thread")
                }
            }
        }
    }

    private static func pages() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("Existing thread", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        defer { ThemeStore.shared.textScale = 1 }

        // The empty state, docked beside the narrowest sidebar and alone with the sidebar hidden.
        vm.forgeStore = emptyStore(repo: ForgeFixtures.repo, path: app.dir.path)
        await vm.forgeStore.start()
        let hidden = PageHeaderChrome(leadingInset: AppLayout.trafficLightInset, showSidebar: {})
        for scale in scales {
            ThemeStore.shared.textScale = scale
            let width = AppLayout.sidebarMinWidth
            let docked = CGSize(width: width + AppLayout.dividerWidth + AppLayout.mainColumnMinWidth, height: 700)
            try await check("docked empty at text size \(scale)", size: docked, vm: vm, expecting: "Paste a link") {
                HStack(spacing: 0) {
                    ForgeSidebarPanel(vm: vm).frame(width: width)
                    SHHairline(.vertical)
                    ForgeDestination(vm: vm)
                }
            }
            try await check("hidden-sidebar empty at text size \(scale)", size: CGSize(width: AppLayout.windowMinWidth, height: 700),
                            vm: vm, expecting: "Paste a link", back: agent.agent.id) {
                ForgeDestination(vm: vm, chrome: hidden)
            }
        }

        // A pull request and an issue from the recorded gh: their header actions stay in the column.
        let forge = try ScratchServer(forgeRunner: { command in
            let (output, status, errors) = ForgeFixtures.answer(command.arguments)
            return ForgeOutput(output: Data(output.utf8), errors: errors, status: status)
        })
        defer { forge.stop() }
        for (kind, number, primary) in [(ForgeKind.pullRequest, 31, "Merge"), (.issue, 34, "Close issue")] {
            vm.forgeStore = ForgeStore { [server = forge.server] in await server.forge($0) }
            let ref = ForgeItemRef(kind: kind, repo: ForgeFixtures.repo, number: number)
            await vm.forgeStore.start(opening: ref)
            await vm.forgeStore.open(ref)
            for scale in scales {
                ThemeStore.shared.textScale = scale
                try await check("#\(number) beside the sidebar at text size \(scale)", size: CGSize(width: AppLayout.mainColumnMinWidth, height: 700),
                                vm: vm, expecting: primary) {
                    ForgeDestination(vm: vm)
                }
                try await check("#\(number) with the sidebar hidden at text size \(scale)", size: CGSize(width: AppLayout.windowMinWidth, height: 700),
                                vm: vm, expecting: primary, back: agent.agent.id) {
                    ForgeDestination(vm: vm, chrome: hidden)
                }
            }
        }
    }

    // MARK: Helpers

    /// Renders `content` in a window of `size`, waits for `expecting`, and checks the window kept its
    /// size and that every control and line of text is inside it. `back` presses Back to threads,
    /// which must return to that thread.
    private static func check(_ place: String, size: CGSize, vm: ShepherdViewModel, expecting: String, back: AgentID? = nil,
                              @ViewBuilder _ content: () -> some View) async throws {
        if let back { vm.selectAgent(back) }
        vm.openDestination(.forge)
        let window = OffscreenWindow(size: size, dark: true, content())
        defer { window.close() }
        try await eventuallyOnMain("\(expecting) to show for \(place)") {
            window.layout()
            return ControlPress.controls(in: window.host).contains { $0.label == expecting }
        }
        #expect(abs(window.host.bounds.width - size.width) <= 1 && abs(window.host.bounds.height - size.height) <= 1,
                "\(place) resized its window to \(window.host.bounds.size), asked for \(size)")
        expectInside(window, place, vertical: true)
        if let back {
            try ControlPress.press("Back to threads", under: window.host)
            #expect(vm.shownDestination == nil && vm.selectedAgentID == back, "Back to threads returns to the thread from \(place)")
        }
    }

    /// Every control and line of text lies inside the window horizontally, and with `vertical`, no
    /// control is pushed above its top.
    private static func expectInside(_ window: OffscreenWindow, _ place: String, vertical: Bool = false,
                                     sourceLocation: SourceLocation = #_sourceLocation) {
        let bounds = window.window.convertToScreen(window.host.convert(window.host.bounds, to: nil))
        let roles = ControlRole.actionable.union(["AXTextField", "AXStaticText"])
        for node in AccessibilityNode.all(under: window.host) where roles.contains(node.role ?? "") && !node.frame.isEmpty {
            let frame = node.frame
            let name = node.label ?? node.value ?? help(node) ?? node.role ?? "element"
            #expect(frame.minX >= bounds.minX - 1 && frame.maxX <= bounds.maxX + 1,
                    "\(name) overflows \(place) horizontally: \(frame), bounds \(bounds)", sourceLocation: sourceLocation)
            // Screen coordinates rise upward: a header control cut off at the top reaches past maxY.
            // (The bottom edge is the scroll view's; rows under it scroll rather than clip.)
            if vertical, node.role != "AXStaticText" {
                #expect(frame.maxY <= bounds.maxY + 1,
                        "\(name) is cut off in \(place): \(frame), bounds \(bounds)", sourceLocation: sourceLocation)
            }
        }
    }

    private static func help(_ node: AccessibilityNode) -> String? {
        let selector = NSSelectorFromString("accessibilityHelp")
        guard node.object.responds(to: selector) else { return nil }
        return node.object.perform(selector)?.takeUnretainedValue() as? String
    }

    private static func emptyStore(repo: String, path: String) -> ForgeStore {
        ForgeStore { request in
            switch request {
            case .repos: .success(.repos([ForgeRepo(nameWithOwner: repo, path: path)]))
            case .list(let kind, _, _): .success(.list(ForgeList(kind: kind, repo: repo, sections: [])))
            case .sidebar: .success(.sidebar(ForgeSidebar(pins: [], needsYou: 0)))
            default: .failure(ForgeError(.notFound, "No fixture for this request"))
            }
        }
    }
}
