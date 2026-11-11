import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Remote threads are pages of their own deck: showing one flips two hosts' visibility and
/// rebuilds nothing, as it does for a local thread.
@Suite("Remote deck", .mainActorExclusive)
@MainActor
struct RemoteDeckTests {
    /// pi's own message JSON: `pairs` question and answer pairs, each answer holding a Swift fence
    /// and a Markdown table, so a rebuilt thread shows up as native code fields and tables.
    static func history(pairs: Int) -> Data {
        let base = 1_733_000_000_000.0
        let out: [[String: Any]] = (0..<pairs).flatMap { i -> [[String: Any]] in
            let answer = """
                Answer \(i). The build step:

                ```swift
                func step\(i)() {
                    let value = compute(\(i), from: source[\(i)])
                    print(value)
                }
                ```

                | file | calls |
                | --- | --- |
                | Sources/Cart\(i).swift | \(i + 3) |
                | Sources/Checkout\(i).swift | \(i + 5) |

                That is the whole change.
                """
            return [["role": "user", "content": "Question \(i)", "timestamp": base + Double(i) * 10_000],
                    ["role": "assistant", "stopReason": "stop", "timestamp": base + Double(i) * 10_000 + 5000,
                     "content": [["type": "text", "text": answer]]]]
        }
        return try! JSONSerialization.data(withJSONObject: out)
    }

    /// A paired host with agents and this Mac's workspace showing them, in an off-screen window.
    @MainActor
    final class Rig {
        let local: AppHarness
        let remote: RemoteHostHarness
        let vm: ShepherdViewModel
        let connection: RemoteHostStore.Connection
        let agents: [AgentFixture]
        private(set) var window: OffscreenWindow

        var refs: [RemoteAgentRef] { agents.map { RemoteAgentRef(hostID: connection.id, agentID: $0.agent.id) } }

        /// `seed` adds to the host's workspace before it starts. `designTool` turns the Design tool on in both
        /// apps first, so the host offers designs and references.
        init(agents count: Int = 2, auxiliary: Int = 0, designTool: Bool = false,
             seed: (inout ShepherdState, Space) -> Void = { _, _ in }) async throws {
            let local = try AppHarness(), remote = try RemoteHostHarness()
            self.local = local
            self.remote = remote
            if designTool {
                local.settings.designToolEnabled = true
                remote.host.settings.designToolEnabled = true
            }
            let space = Fixture.space(path: remote.host.dir.path)
            var fixtures: [AgentFixture] = []
            for index in 0..<count {
                let file = remote.host.dir.appendingPathComponent("history-\(index).json")
                try RemoteDeckTests.history(pairs: 24).write(to: file)
                var agent = try await remote.host.liveAgent("remote \(index)", in: space, order: index, auxiliary: index == 0 ? auxiliary : 0,
                                                            env: ["STUB_PI_MESSAGES_FILE": file.path])
                agent.agent.piSessionID = "stub-session"
                agent.agent.lastActiveAt = Double(count - index)
                fixtures.append(agent)
            }
            var state = Fixture.state(spaces: [space], agents: fixtures)
            seed(&state, space)
            try await remote.host.start(with: state)
            vm = try await local.start()
            if designTool {
                vm.designNetwork = .none
                vm.designLiveCap = 0
            }
            connection = try await remote.connect(local.remoteHosts)
            agents = fixtures
            window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, WorkspaceView(vm: vm))
        }

        func close() {
            window.close()
            local.stop()
            remote.stop()
        }

        /// A new window on the same workspace, the first one closed (the Window scene reopened).
        func reopenWindow() {
            window.close()
            window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, WorkspaceView(vm: vm))
        }

        func store(_ index: Int) -> NativeThreadStore { vm.remoteThreadStores.store(for: refs[index]) }

        /// The window's remote deck.
        func deck() throws -> RemoteLayoutDeck.Container {
            func find(_ view: NSView) -> RemoteLayoutDeck.Container? {
                (view as? RemoteLayoutDeck.Container) ?? view.subviews.lazy.compactMap(find).first
            }
            return try #require(find(window.window.contentView!))
        }

        /// The host of thread `index`'s page, once mounted.
        func host(_ index: Int) throws -> RemoteLayoutDeck.Host? { try deck().pages[refs[index]]?.host }

        /// The scroll views on screen: none inside a hidden host.
        var shownScrolls: [NSScrollView] { HiddenAgentsWorkspace.shownScrollViews(in: window) }

        /// The thread's scroll view on screen: the tallest one.
        var transcript: NSScrollView? { shownScrolls.max { $0.frame.height < $1.frame.height } }

        func select(_ index: Int) {
            vm.selectRemoteAgent(hostID: connection.id, agentID: agents[index].agent.id)
        }

        /// Waits until nothing builds a row, a thread or a composer any more: what the change
        /// set off has landed.
        func quiet(polls: Int = 20) async throws {
            var last = -1, still = 0
            try await eventuallyOnMain("the window to stop building", timeout: .seconds(60)) {
                ListPerf.settle(window)
                let now = ["thread.rowBuilder", "thread.view", "composer.body", "layout.remoteLayout", "remoteDeck.layout", "remoteDeck.hiddenLayout"]
                    .reduce(0) { $0 + SHRenderProbe.count($1) }
                still = now == last ? still + 1 : 0
                last = now
                return still >= polls
            }
        }

        /// Shows thread `index` and counts everything its draw builds, until the window is quiet.
        @discardableResult
        func show(_ index: Int) async throws -> [String: Int] {
            SHRenderProbe.start()
            select(index)
            do {
                try await quiet()
            } catch {
                SHRenderProbe.stop()
                throw error
            }
            return SHRenderProbe.stop()
        }

        /// Shows thread `index` for the first time and waits for its history to draw.
        func firstVisit(_ index: Int) async throws -> [String: Int] {
            let store = store(index)
            SHRenderProbe.start()
            select(index)
            do {
                try await eventuallyOnMain("remote \(index)'s history to draw", timeout: .seconds(60)) {
                    ListPerf.settle(window)
                    return store.ready && !store.rows.isEmpty && SHRenderProbe.count("prose.table") > 0
                }
                try await quiet()
            } catch {
                SHRenderProbe.stop()
                throw error
            }
            return SHRenderProbe.stop()
        }
    }

    // MARK: Switching

    @Test func switchingBetweenTwoRemoteThreadsFlipsTheirHosts() async throws {
        let rig = try await Rig()
        defer { rig.close() }

        let firstA = try await rig.firstVisit(0)
        #expect(firstA["code.nativeCreated", default: 0] > 0 && firstA["prose.table", default: 0] > 0, "the fixture draws code and tables: \(firstA)")
        let scrollA = try #require(rig.transcript)
        _ = try await rig.firstVisit(1)
        let scrollB = try #require(rig.transcript)
        #expect(scrollA !== scrollB)

        // A reader scrolls into A's history: the wheel monitor's input path, then the clip view's movement.
        _ = try await rig.show(0)
        rig.vm.remoteThreadStores.input(for: rig.refs[0]).readerScrolled(upward: true)
        let clip = scrollA.contentView
        let middle = max(0, ((scrollA.documentView?.bounds.height ?? 0) - clip.bounds.height) / 2)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: middle), size: clip.bounds.size)).origin)
        scrollA.reflectScrolledClipView(clip)
        try await rig.quiet()
        let place = clip.bounds.origin.y
        #expect(place > 0, "A's reader is mid-history")

        for step in 0..<6 {
            let index = step.isMultiple(of: 2) ? 1 : 0
            let counts = try await rig.show(index)
            let name = index == 0 ? "A" : "B"
            for key in ["thread.userTurn", "thread.agentTurn", "code.nativeCreated", "code.nativeDismantled", "prose.table",
                        "thread.tailRepair", "remoteDeck.mount", "remoteDeck.unmount"] {
                #expect(counts[key, default: 0] == 0, "switch \(step) to \(name): \(key) in \(counts)")
            }
            #expect(counts["thread.view", default: 0] <= 2, "switch \(step) to \(name): \(counts)")
            #expect(counts["composer.body", default: 0] <= 3, "switch \(step) to \(name): \(counts)")
            #expect(rig.transcript === (index == 0 ? scrollA : scrollB), "switch \(step) to \(name) shows the thread it showed before")
        }
        #expect(abs(clip.bounds.origin.y - place) < 1, "A keeps the reader's place: \(clip.bounds.origin.y) from \(place)")
    }

    @Test func aRemoteSwitchKeepsTheThreadAndItsDraftMountedThroughAMaximizedPanel() async throws {
        let rig = try await Rig(auxiliary: 1)
        defer { rig.close() }
        let a = rig.refs[0]
        let input = rig.vm.remoteThreadStores.input(for: a)
        input.attachments.add([("draft.png", ImageAttachment(name: "draft.png", image: NativeImage(mimeType: "image/png", data: Data([1]))))])
        let store = rig.store(0)
        store.draft = "Unsent draft"

        _ = try await rig.firstVisit(0)
        let original = try #require(rig.transcript)
        let key = TerminalPanelKey(host: a.hostID, tab: rig.agents[0].tab.id)
        rig.vm.terminalPanels.update(key) { $0.shown = true; $0.maximized = true }
        ListPerf.settle(rig.window)
        #expect(rig.shownScrolls.contains { $0 === original }, "the maximized panel leaves the thread mounted")
        rig.vm.terminalPanels.update(key) { $0.maximized = false }
        ListPerf.settle(rig.window)
        #expect(rig.transcript === original)

        _ = try await rig.firstVisit(1)
        #expect(rig.transcript !== original)
        _ = try await rig.show(0)
        #expect(rig.transcript === original, "back on A: the same scroll view")
        #expect(store.draft == "Unsent draft")
        #expect(rig.vm.remoteThreadStores.input(for: a) === input)
        #expect(input.attachments.items.map(\.name) == ["draft.png"])
    }
}

extension RemoteDeckTests {
    // MARK: Hidden pages rest

    @Test func aHiddenRemoteThreadStopsPollingAndDetachesItsTerminal() async throws {
        let rig = try await Rig(auxiliary: 1)
        defer { rig.close() }
        let (a, b) = (rig.refs[0], rig.refs[1])
        let tab = rig.agents[0].tab.id, shell = rig.agents[0].auxiliary[0].id
        func session() -> SessionID? { rig.connection.state.tabs.first { $0.id == tab }?.layout.leaf(withID: shell)?.sessionID }
        func attached() -> Bool { session().map { rig.connection.pane(for: $0) != nil } ?? false }

        _ = try await rig.firstVisit(0)
        let scroll = try #require(rig.transcript)
        rig.vm.terminalPanels.update(TerminalPanelKey(host: a.hostID, tab: tab)) { $0.shown = true }
        // An off-screen window is no active scene, so the leaf does not ask by itself.
        try await rig.local.remoteHosts.agentAction(a, action: .startTerminal(paneID: shell))
        try await eventuallyOnMain("A's terminal to attach", timeout: .seconds(60)) { ListPerf.settle(rig.window); return attached() }
        #expect(rig.vm.remoteThreadStores.live.contains(a))

        try await rig.show(1)
        try await eventuallyOnMain("A's terminal to detach and its thread to rest") {
            ListPerf.settle(rig.window)
            return !attached() && !rig.vm.remoteThreadStores.live.contains(a)
        }
        #expect(rig.vm.remoteThreadStores.live.contains(b), "the shown page polls")

        try await rig.show(0)
        try await eventuallyOnMain("A's terminal to attach again", timeout: .seconds(60)) { ListPerf.settle(rig.window); return attached() }
        #expect(rig.vm.remoteThreadStores.live.contains(a))
        #expect(rig.transcript === scroll, "back on A: the same scroll view")
    }

    @Test func aHiddenRemotePagesInspectorStopsFollowing() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        let a = rig.refs[0]
        _ = try await rig.firstVisit(0)
        let children = try ExtensionClient(path: rig.remote.host.scratch.socketPath)
        defer { withExtendedLifetime(children) {} }
        try children.send(.helloChildren(agentID: a.agentID))
        let run = ChildRun(runID: "run-1", label: "worker: audit the cart", state: "running",
                           startedAt: Date().timeIntervalSince1970 * 1000, role: "worker", task: "audit the cart")
        try children.send(.setAgentChildren(agentID: a.agentID, children: [run]))
        try await eventuallyOnMain("the child to reach A's thread", timeout: .seconds(30)) { rig.store(0).subagents.contains { $0.runID == run.runID } }

        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        rig.vm.subagentInspector.remoteRuns[a] = run.runID
        try await eventuallyOnMain("the inspector to follow the child") { ListPerf.settle(rig.window); return SHRenderProbe.count("inspector.follow") >= 1 }
        let (followed, ended) = (SHRenderProbe.count("inspector.follow"), SHRenderProbe.count("inspector.followEnded"))

        rig.select(1)
        try await eventuallyOnMain("A's inspector to stop following") {
            ListPerf.settle(rig.window)
            return SHRenderProbe.count("inspector.followEnded") > ended
        }
        #expect(rig.store(0).subagents.first { $0.runID == run.runID }?.isTerminal == false, "the child still runs")

        rig.select(0)
        try await eventuallyOnMain("A's inspector to follow again") { ListPerf.settle(rig.window); return SHRenderProbe.count("inspector.follow") > followed }
    }

    // MARK: Pushes and lifetimes

    @Test func aHostPushChangesNoHiddenRemoteLayout() async throws {
        let rig = try await Rig(designTool: true)
        defer { rig.close() }
        let a = rig.refs[0]
        _ = try await rig.firstVisit(0)
        _ = try await rig.firstVisit(1)
        let reporter = try ExtensionClient(path: rig.remote.host.scratch.socketPath)
        defer { withExtendedLifetime(reporter) {} }

        // A's page has finished resting; what follows is the pushes' own.
        SHRenderProbe.start()
        do { try await rig.quiet(polls: 40) } catch { SHRenderProbe.stop(); throw error }
        SHRenderProbe.start()
        for edge in 0..<5 {
            let status: AgentStatus = edge.isMultiple(of: 2) ? .working : .done
            try reporter.send(.setAgentStatus(agentID: a.agentID, status: status))
            try await eventuallyOnMain("the host's \(status) report for A") {
                rig.connection.state.agents.first { $0.id == a.agentID }?.status == status
            }
            ListPerf.settle(rig.window)
        }
        try await rig.quiet()
        let pushes = SHRenderProbe.stop()
        for key in ["layout.remoteLayout", "layout.remotePaneTree", "remoteDeck.hiddenLayout", "remoteDeck.mount", "remoteDeck.unmount"] {
            #expect(pushes[key, default: 0] == 0, "\(key): \(pushes)")
        }
    }

    @Test func aRemoteThreadLeavesTheDeckWhenItsAgentGoes() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        let (a, b) = (rig.refs[0], rig.refs[1])
        _ = try await rig.firstVisit(0)
        _ = try await rig.firstVisit(1)
        let kept = try #require(try rig.host(1))
        #expect(try rig.deck().pages.count == 2)

        SHRenderProbe.start()
        try await rig.remote.host.server.deleteAgent(a.agentID)
        try await eventuallyOnMain("A's page to leave the deck") {
            ListPerf.settle(rig.window)
            return (try? rig.deck().pages.keys.contains(a)) == false
        }
        try await rig.quiet()
        let counts = SHRenderProbe.stop()
        #expect(counts["remoteDeck.unmount", default: 0] == 1, "\(counts)")
        #expect(counts["remoteDeck.mount", default: 0] == 0, "\(counts)")
        #expect(try rig.host(1) === kept, "B's host is the one it had")
        #expect(rig.vm.remoteDeckRefs == [b])
        #expect(rig.vm.selectedRemoteAgent == b && !kept.isHidden)
    }

    @Test func aNewDeckMountsOnlyTheVisiblePage() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        _ = try await rig.firstVisit(0)
        _ = try await rig.firstVisit(1)
        #expect(rig.vm.remoteDeckRefs == rig.refs)

        // The window closes and opens again on the same workspace: B is selected, A was shown before it.
        SHRenderProbe.start()
        rig.reopenWindow()
        do { try await rig.quiet() } catch { SHRenderProbe.stop(); throw error }
        let reopened = SHRenderProbe.stop()
        #expect(reopened["remoteDeck.mount", default: 0] == 1, "only the page shown mounts: \(reopened)")
        #expect(try rig.deck().pages.keys.map { $0 } == [rig.refs[1]])

        SHRenderProbe.start()
        rig.select(0)
        do { try await rig.quiet() } catch { SHRenderProbe.stop(); throw error }
        let selected = SHRenderProbe.stop()
        #expect(selected["remoteDeck.mount", default: 0] == 1, "A mounts when it is shown: \(selected)")
        #expect(try rig.deck().pages.count == 2)
    }

    // MARK: What draws over the deck

    @Test func designsAndAHostsUtilityTerminalStillDrawOverTheDeck() async throws {
        var utility: ShepherdCore.Tab?
        var designAgent: AgentFixture?
        var shell: SessionID?
        let rig = try await Rig(designTool: true) { state, space in
            var drawer = Fixture.agent("Landing hero", in: space, order: 9)
            let design = Design(name: "Landing hero", agentID: drawer.agent.id, createdAt: 1_000)
            drawer.agent.designID = design.id
            state.tabs.append(drawer.tab)
            state.agents.append(drawer.agent)
            state.designs = [design]
            designAgent = drawer
        }
        defer { rig.close() }
        let a = rig.refs[0]
        let session = try await rig.remote.host.server.createSession(params: CreateSessionParams(cwd: rig.remote.host.dir.path, command: ["/bin/cat"]))
        shell = session.id
        let inspector = ShepherdCore.Tab(spaceID: rig.agents[0].space.id, order: 8,
                                         layout: .leaf(LeafPane(sessionID: session.id, cwd: rig.remote.host.dir.path)), inspectorFor: a.agentID)
        utility = inspector
        try await rig.remote.host.server.putState({
            var state = rig.remote.host.server.state
            state.tabs.append(inspector)
            return state
        }())
        try await eventuallyOnMain("the utility tab to reach this Mac") { rig.connection.state.tabs.contains { $0.id == inspector.id } }

        _ = try await rig.firstVisit(0)
        let page = try #require(try rig.host(0))
        let container = try rig.deck()
        #expect(!page.isHidden && !container.isHidden)

        // A design the host draws shows beside its chat over the deck: every page rests.
        let drawer = try #require(designAgent)
        rig.vm.selectRemoteAgent(hostID: a.hostID, agentID: drawer.agent.id)
        try await rig.quiet()
        let drawn = RemoteLayoutModel.Resolver(vm: rig.vm).presentation(for: RemoteAgentRef(hostID: a.hostID, agentID: drawer.agent.id))
        guard case .design? = drawn else { Issue.record("the host's design draws a design screen: \(String(describing: drawn))"); return }
        #expect(page.isHidden && container.isHidden, "the design draws over a deck at rest")
        #expect(container.pages.count == 1, "a design agent is no page")

        // The host's utility terminal for A shows in place of A's layout, over its resting page.
        rig.select(0)
        try await rig.quiet()
        #expect(!page.isHidden)
        rig.vm.remoteInspectorTabs[a] = try #require(utility).id
        rig.vm.remoteInspectingAgent = a
        try await eventuallyOnMain("the utility tab to draw over the deck") {
            ListPerf.settle(rig.window)
            return page.isHidden && ((try? rig.deck().isHidden) == true) && rig.connection.pane(for: shell!) != nil
        }

        // Closing it shows A's page again, the host it had.
        rig.vm.remoteInspectingAgent = nil
        try await eventuallyOnMain("A's page to show again") { ListPerf.settle(rig.window); return !page.isHidden }
        #expect(try rig.host(0) === page)
        #expect(!container.isHidden)
    }

    @Test func theRemoteDeckLetsClicksThroughToALocalLayout() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        _ = try await rig.firstVisit(0)
        _ = try await rig.firstVisit(1)

        // This Mac's own thread, from the workspace the app is the client of.
        let space = Fixture.space("local", path: rig.local.dir.path)
        let local = try await rig.local.liveAgent("local thread", in: space)
        try await rig.local.server.putState(Fixture.state(spaces: [space], agents: [local]))
        try await eventuallyOnMain("the local thread to reach the workspace") { rig.vm.state.agents.contains { $0.id == local.agent.id } }
        rig.vm.selectAgent(local.agent.id)
        try await eventuallyOnMain("the local layout to show") {
            ListPerf.settle(rig.window)
            return (try? WorkspaceNavigationTests.deck(in: rig.window).pages[local.tab.id]).map { !$0.host.isHidden } ?? false
        }

        let deck = try rig.deck()
        #expect(deck.pages.count == 2 && deck.pages.values.allSatisfy { $0.host.isHidden }, "both remote pages are mounted and rest")
        #expect(deck.isHidden)
        let shown = try #require(try WorkspaceNavigationTests.deck(in: rig.window).pages[local.tab.id]).host
        // Where the composer sits: the lower middle of the column.
        let point = shown.convert(CGPoint(x: shown.bounds.midX, y: shown.bounds.maxY - 60), to: rig.window.window.contentView?.superview)
        let hit = rig.window.window.contentView?.hitTest(point)
        #expect(hit?.isDescendant(of: shown) == true, "a click lands in the local layout, not the remote deck: \(String(describing: hit))")
        #expect(hit?.isDescendant(of: deck) == false)
    }
}
