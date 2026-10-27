import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The side pane's Subagents tab (iPadSteer, iPadSubagents, DuoSidePaneTabs boards): the thread's runs, or one run with its live
/// siblings as tabs (up to four; otherwise ‹ › step through them), its card, goal, transcript, and steer field or finished actions.
/// The pane's tabs name it, so the list has no head of its own.
struct PadSubagentInspector: View {
    let ref: AgentRef
    @Environment(ThreadStores.self) private var threads
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let store = threads.store(for: ref)
        let inspection = SubagentInspection.of(navigator)
        let runID = inspection.selected(in: ref)
        VStack(spacing: 0) {
            if let runID {
                PadRunHeader(ref: ref, store: store, runID: runID)
                SubagentRunView(ref: ref, store: store, runID: runID, compact: false)
                    .id(runID)
            } else {
                ScrollView {
                    SubagentListContent(ref: ref, store: store) { inspection.show(ref, runID: $0) }
                        .padding(MobileLayout.gutter)
                }
                .background(Color.sh.bgSunken)
            }
        }
        .background(Color.sh.bgWindow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Subagents")
    }
}

/// The run's head in the inspector: tabs between its siblings when there are a few, else its
/// name with "k of n" and ‹ ›; and a button back to every run.
private struct PadRunHeader: View {
    let ref: AgentRef
    let store: NativeThreadStore
    let runID: String
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let inspection = SubagentInspection.of(navigator)
        let siblings = nativeSubagentSiblings(of: runID, in: store.subagents, turns: store.rows.map(\.turn))
        let position = siblings.firstIndex { $0.runID == runID }
        let run = store.subagents.first { $0.runID == runID }
        // A live group switches between its runs as tabs (iPadSteer); a finished one, or any
        // group at accessibility sizes, steps through them (iPadSubagents).
        if !dynamicType.isAccessibilitySize, siblings.count > 1, siblings.count <= MobileLayout.subagentTabsMax, siblings.contains(where: { nativeRunPhase($0).isLive }) {
            HStack(spacing: SH.Space.m) {
                SHRunTabs(selection: Binding(get: { runID }, set: { inspection.show(ref, runID: $0) }),
                          tabs: siblings.map { (id: $0.runID, title: nativeRunAgentName($0)) })
                if let run { controls(run) }
                allRuns
            }
            .padding(.leading, SH.Space.l)
            .padding(.trailing, SH.Space.s)
            .padding(.vertical, SH.Space.s)
            .background(Color.sh.bgWindow)
            .overlay(alignment: .bottom) { SHHairline() }
        } else {
            let meta = run.map { nativeRunInspectorMeta($0, withRole: false) }
            SHRunHeader(run.map(nativeRunAgentName) ?? "Subagent",
                        position: position.flatMap { siblings.count > 1 ? "\($0 + 1) of \(siblings.count)" : nil },
                        state: run.map { AgentState(nativeRunPhase($0)) } ?? .idle, meta: meta?.meta ?? "no longer listed",
                        accent: meta?.accent) {
                if let position, siblings.count > 1 {
                    Button { inspection.show(ref, runID: siblings[position - 1].runID) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.shIcon).disabled(position == 0)
                        .accessibilityLabel("Previous subagent")
                    Button { inspection.show(ref, runID: siblings[position + 1].runID) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.shIcon).disabled(position == siblings.count - 1)
                        .accessibilityLabel("Next subagent")
                }
                if let run { controls(run) }
                allRuns
            }
        }
    }

    private func controls(_ run: NativeSubagent) -> some View {
        Menu {
            SubagentControlItems(run: run, commands: SubagentCommands(store: store, enabled: store.takesSubagentCommands))
        } label: {
            Image(systemName: "ellipsis")
        }
        .buttonStyle(.shIcon)
        .accessibilityLabel("Subagent options")
    }

    private var allRuns: some View {
        Button { SubagentInspection.of(navigator).show(ref, runID: nil) } label: { Image(systemName: "list.bullet") }
            .buttonStyle(.shIcon)
            .accessibilityLabel("All subagents")
    }
}
