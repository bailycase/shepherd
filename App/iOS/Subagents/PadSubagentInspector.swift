import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The iPad's subagents (iPadSteer, iPadSubagents boards): the thread keeps its place and the
/// runs open in an inspector beside it. The screen is the thread itself with the inspector
/// attached, so closing the inspector returns to the thread as it was.
struct PadSubagentsScreen: View {
    let route: SubagentsRoute
    @State private var shown = true
    @Environment(\.dismiss) private var dismiss
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let ref = route.thread
        ThreadScreen(ref: ref)
            .inspector(isPresented: $shown) {
                PadSubagentInspector(ref: ref) { shown = false }
                    .inspectorColumnWidth(min: MobileLayout.subagentInspectorMinWidth, ideal: MobileLayout.subagentInspectorIdealWidth,
                                          max: MobileLayout.subagentInspectorMaxWidth)
            }
            .navigationBarBackButtonHidden(true)
            .onAppear {
                let runID: String? = if case .run(_, let id) = route { id } else { nil }
                SubagentInspection.of(navigator).show(ref, runID: runID)
            }
            .onDisappear { SubagentInspection.of(navigator).close(ref) }
            .onChange(of: shown) { _, shown in
                guard !shown else { return }
                SubagentInspection.of(navigator).close(ref)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { dismiss() }
            }
            .keepsThreadLive(ref)
    }
}

/// The inspector's column: the thread's runs, or one run with its live siblings as tabs (up to
/// four; otherwise ‹ › step through them), its card, goal, transcript, and steer field or
/// finished actions.
struct PadSubagentInspector: View {
    let ref: AgentRef
    let close: () -> Void
    @Environment(ThreadStores.self) private var threads
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let store = threads.store(for: ref)
        let inspection = SubagentInspection.of(navigator)
        let runID = inspection.selected(in: ref)
        VStack(spacing: 0) {
            if let runID {
                PadRunHeader(ref: ref, store: store, runID: runID, close: close)
                SubagentRunView(ref: ref, store: store, runID: runID, compact: false)
                    .id(runID)
            } else {
                let tally = nativeRunTally(store.subagents)
                NWRunHeader("Subagents", state: tally.map { AgentState($0.phase) } ?? .idle, meta: tally?.text ?? "") {
                    closeButton
                }
                ScrollView {
                    SubagentListContent(ref: ref, store: store) { inspection.show(ref, runID: $0) }
                        .padding(MobileLayout.gutter)
                }
                .background(Color.nw.bgSunken)
            }
        }
        .background(Color.nw.bgWindow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Subagent inspector")
    }

    private var closeButton: some View {
        Button(action: close) { Image(systemName: "xmark") }
            .buttonStyle(.nwIcon)
            .accessibilityLabel("Close inspector")
    }
}

/// The run's head in the inspector: tabs between its siblings when there are a few, else its
/// name with "k of n" and ‹ ›; a button back to every run; and close.
private struct PadRunHeader: View {
    let ref: AgentRef
    let store: NativeThreadStore
    let runID: String
    let close: () -> Void
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
            HStack(spacing: NW.Space.m) {
                NWRunTabs(selection: Binding(get: { runID }, set: { inspection.show(ref, runID: $0) }),
                          tabs: siblings.map { (id: $0.runID, title: nativeRunNames($0).name) })
                if let run { controls(run) }
                allRuns
                closeButton
            }
            .padding(.leading, NW.Space.l)
            .padding(.trailing, NW.Space.s)
            .padding(.vertical, NW.Space.s)
            .background(Color.nw.bgWindow)
            .overlay(alignment: .bottom) { NWHairline() }
        } else {
            let meta = run.map { nativeRunInspectorMeta($0) }
            NWRunHeader(run.map { nativeRunNames($0).name } ?? "Subagent",
                        position: position.flatMap { siblings.count > 1 ? "\($0 + 1) of \(siblings.count)" : nil },
                        state: run.map { AgentState(nativeRunPhase($0)) } ?? .idle, meta: meta?.meta ?? "no longer listed",
                        accent: meta?.accent) {
                if let position, siblings.count > 1 {
                    Button { inspection.show(ref, runID: siblings[position - 1].runID) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.nwIcon).disabled(position == 0)
                        .accessibilityLabel("Previous subagent")
                    Button { inspection.show(ref, runID: siblings[position + 1].runID) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.nwIcon).disabled(position == siblings.count - 1)
                        .accessibilityLabel("Next subagent")
                }
                if let run { controls(run) }
                allRuns
                closeButton
            }
        }
    }

    private func controls(_ run: NativeSubagent) -> some View {
        Menu {
            SubagentControlItems(run: run, commands: SubagentCommands(store: store, enabled: store.takesSubagentCommands))
        } label: {
            Image(systemName: "ellipsis")
        }
        .buttonStyle(.nwIcon)
        .accessibilityLabel("Subagent options")
    }

    private var allRuns: some View {
        Button { SubagentInspection.of(navigator).show(ref, runID: nil) } label: { Image(systemName: "list.bullet") }
            .buttonStyle(.nwIcon)
            .accessibilityLabel("All subagents")
    }

    private var closeButton: some View {
        Button(action: close) { Image(systemName: "xmark") }
            .buttonStyle(.nwIcon)
            .accessibilityLabel("Close inspector")
    }
}
