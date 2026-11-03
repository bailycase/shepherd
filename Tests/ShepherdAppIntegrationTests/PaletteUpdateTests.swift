#if DEBUG
import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Palette updates", .mainActorExclusive)
@MainActor
struct PaletteUpdateTests {
    @MainActor @Observable
    fileprivate final class Fixture {
        var revision = 0
        var child = ChildRun(runID: "run", label: "Fix child", state: "running")
        var context = "parent · running 5m"
        var shortcut = "⌘R"
        var includesChild = true
        let parent = AgentID()
        let host = UUID()
        let remote: Bool
        var selected: [PaletteItem] = []
        var queries: [String] = []
        let fleet = ListFixtures.paletteItems(1000)

        init(remote: Bool = false) { self.remote = remote }

        var items: [PaletteItem] {
            let run = PaletteItem(id: "child", kind: remote ? .remoteChild(hostID: host, agentID: parent, child: child)
                                  : .child(agentID: parent, child: child), section: .subagents,
                                  title: child.label, subtitle: context)
            return [PaletteItem(id: "command", kind: .action("fix"), section: .commands,
                                title: "Fix settings", shortcut: shortcut)] + (includesChild ? [run] : []) + fleet
        }
    }

    private struct Parent: View {
        let fixture: Fixture
        let probe: PaletteDerivationProbe
        let highlight: PaletteHighlight
        var initialQuery = "fix"
        var searchConversations = false

        var body: some View {
            // Read unrelated parent state to force a genuine PaletteCard reconstruction.
            let _ = fixture.revision
            PaletteCard(items: fixture.items, run: { fixture.selected.append($0) }, close: {},
                        contentSearch: searchConversations ? { query, _ in
                            fixture.queries.append(query)
                            return [PaletteItem(id: "conversation", kind: .action("found"), section: .conversations,
                                                title: "Found \(query)", contentSnippet: "…\(query)…")]
                        } : nil,
                        initialQuery: initialQuery, highlight: highlight, probe: probe)
        }
    }

    private func window(_ fixture: Fixture, probe: PaletteDerivationProbe, highlight: PaletteHighlight,
                        search: Bool = false) -> OffscreenWindow {
        OffscreenWindow(size: CGSize(width: 900, height: 700), dark: false,
                        Color.clear.shCommandPalette(isPresented: .constant(true)) {
                            Parent(fixture: fixture, probe: probe, highlight: highlight, searchConversations: search)
                        }.environment(\._accessibilityReduceMotion, true))
    }

    private func settled(_ window: OffscreenWindow, probe: PaletteDerivationProbe,
                         query: String, scope: PaletteItem.Scope = .all, fixture: Fixture) async throws {
        let expected = PaletteSearch.filter(fixture.items, query: query, scope: scope)
        try await eventuallyOnMain("palette reflects query/scope/items") {
            ListPerf.settle(window)
            return probe.derivations >= 2 && probe.query == query && probe.scope == scope
                && probe.rows == expected && probe.submit != nil
        }
    }

    @Test(arguments: [false, true])
    func parentRedrawsAndChildProgressDoNotRankAgainButPresentationStillUpdates(remote: Bool) async throws {
        let fixture = Fixture(remote: remote), probe = PaletteDerivationProbe(), highlight = PaletteHighlight()
        let window = window(fixture, probe: probe, highlight: highlight)
        defer { window.close() }
        try await settled(window, probe: probe, query: "fix", fixture: fixture)
        #expect(probe.firstRows?.isEmpty == false && probe.firstLayout == 0)
        #expect(probe.emptyRenders == 0)
        highlight.move(to: 2)
        ListPerf.settle(window)
        let counts = (probe.derivations, probe.searches, probe.rankedItems)
        let layout = probe.layout

        for step in 1...4 {
            let initializations = probe.cardInitializations
            fixture.revision = step
            try await eventuallyOnMain("identical parent redraw reaches the card") {
                ListPerf.settle(window)
                return probe.cardInitializations > initializations
            }
            #expect(probe.derivations == counts.0 && probe.searches == counts.1 && probe.rankedItems == counts.2,
                    "discarded State seeds must not derive or rank")
        }
        for step in 1...4 {
            let initializations = probe.cardInitializations
            fixture.child.tokens = step * 100
            fixture.child.toolCalls = step
            fixture.child.currentTool = "read-\(step)"
            try await eventuallyOnMain("child progress reaches the card") {
                ListPerf.settle(window)
                return probe.cardInitializations > initializations
            }
            #expect(probe.derivations == counts.0 && probe.searches == counts.1 && probe.rankedItems == counts.2)
        }
        #expect(highlight.index == 2 && probe.layout == layout && probe.query == "fix")
        probe.submit?()
        #expect(fixture.selected.last?.id == probe.rows[2].id)

        // Every actual presentation input must still update, without resetting the selection.
        let mutations: [() -> Void] = [
            { fixture.child.needsAttention = true },
            { fixture.child.needsAttention = false; fixture.child.state = "complete"; fixture.context = "parent · done" },
            { fixture.child.state = "running"; fixture.context = "parent · running 6m" },
            { fixture.child.label = "Fix renamed child" },
            { fixture.shortcut = "⇧⌘R" },
            { fixture.includesChild = false },
            { fixture.includesChild = true },
        ]
        for mutate in mutations {
            let before = probe.derivations
            mutate()
            try await settled(window, probe: probe, query: "fix", fixture: fixture)
            #expect(probe.derivations > before)
            #expect(highlight.index == 2)
        }
        probe.setScope?(.commands)
        try await settled(window, probe: probe, query: "fix", scope: .commands, fixture: fixture)
        #expect(highlight.index == 0)
        highlight.move(to: 1)
        probe.setQuery?("command")
        try await settled(window, probe: probe, query: "command", scope: .commands, fixture: fixture)
        #expect(highlight.index == 0)
        probe.submit?()
        #expect(fixture.selected.last?.id == probe.rows.first?.id)
    }

    @Test(arguments: [false, true], ["", "fix"])
    func imageRendererFirstPaintAlreadyHasUnanimatedResults(dark: Bool, query: String) throws {
        let fixture = Fixture(), probe = PaletteDerivationProbe()
        let renderer = ImageRenderer(content:
            Color.clear.shCommandPalette(isPresented: .constant(true)) {
                PaletteCard(items: fixture.items, run: { _ in }, close: {}, initialQuery: query, probe: probe)
            }
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: 900, height: 700))
        // ImageRenderer need not run onAppear: an appearance-only population would leave this blank.
        _ = try #require(renderer.cgImage)
        #expect(probe.firstRows == PaletteSearch.filter(fixture.items, query: query))
        #expect(probe.firstLayout == 0 && probe.layout == 0)
        #expect(probe.emptyRenders == 0)
    }

    @Test func initialQuerySearchesConversationsOnceAndChangesKeepTheirNormalLifecycle() async throws {
        let fixture = Fixture(), probe = PaletteDerivationProbe(), highlight = PaletteHighlight()
        let window = window(fixture, probe: probe, highlight: highlight, search: true)
        defer { window.close() }
        try await eventuallyOnMain("the actual initial query searches conversations") {
            ListPerf.settle(window)
            return fixture.queries == ["fix"] && probe.rows.last?.id == "conversation" && !probe.searching
        }
        #expect(probe.firstRows?.isEmpty == false && probe.emptyRenders == 0)
        let counts = (probe.derivations, probe.searches, probe.rankedItems)
        let initializations = probe.cardInitializations
        fixture.revision += 1
        fixture.child.tokens = 999
        try await eventuallyOnMain("parent refresh with conversation results") {
            ListPerf.settle(window)
            return probe.cardInitializations > initializations
        }
        #expect(probe.derivations == counts.0 && probe.searches == counts.1 && probe.rankedItems == counts.2)
        #expect(fixture.queries == ["fix"])
        highlight.move(to: 3)
        probe.setQuery?("other")
        try await eventuallyOnMain("a new query replaces transcript matches") {
            ListPerf.settle(window)
            return fixture.queries == ["fix", "other"] && probe.rows.last?.title == "Found other" && !probe.searching
        }
        #expect(highlight.index == 0)
        probe.setScope?(.commands)
        try await eventuallyOnMain("Commands hides transcript matches without another search") {
            ListPerf.settle(window)
            return probe.scope == .commands && probe.rows.isEmpty
        }
        #expect(fixture.queries == ["fix", "other"])
    }
}

@Suite("Palette activation", .mainActorExclusive)
@MainActor
struct PaletteActivationTests {
    private struct Parent: View {
        let vm: ShepherdViewModel
        let probe: PaletteDerivationProbe
        var body: some View {
            PaletteCard(items: vm.paletteItems, run: vm.runPaletteItem, close: {},
                        initialQuery: "_palette_child_", probe: probe)
        }
    }

    @Test func anAlreadyRenderedActionResolvesTheLiveRunAndCannotOpenARemovedChild() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("palette", path: app.dir.path)
        let parent = Fixture.agent("parent", in: space, order: 0)
        let other = Fixture.agent("other", in: space, order: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [parent, other]))
        vm.selectAgent(other.agent.id)
        var child = ChildRun(runID: "run", label: "_palette_child_", state: "running")
        vm.applyAgentChildren(parent.agent.id, [child])
        let probe = PaletteDerivationProbe()
        let window = OffscreenWindow(Parent(vm: vm, probe: probe))
        defer { window.close() }
        try await eventuallyOnMain("the child action is rendered") {
            ListPerf.settle(window)
            return probe.rows.count == 1 && probe.rows.first?.title == child.label && probe.submit != nil
        }
        let activate = try #require(probe.submit)
        let initialized = probe.cardInitializations
        child.tokens = 1234
        vm.applyAgentChildren(parent.agent.id, [child])
        try await eventuallyOnMain("progress reaches the real palette producer") {
            ListPerf.settle(window)
            return probe.cardInitializations > initialized
        }
        activate()
        #expect(vm.selectedAgentID == parent.agent.id)
        #expect(vm.subagentInspector.runByAgent[parent.agent.id] == child.runID)

        vm.subagentInspector.runByAgent[parent.agent.id] = nil
        vm.selectAgent(other.agent.id)
        vm.applyAgentChildren(parent.agent.id, [])
        // No layout/await: deliberately invoke the old body's action before it can be replaced.
        activate()
        #expect(vm.selectedAgentID == other.agent.id)
        #expect(vm.subagentInspector.runByAgent[parent.agent.id] == nil)
    }
}
#endif
