import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The side pane's Subagents tab (SubagentList board): every run of the thread under "5 subagents",
/// this turn's first, the earlier ones after. A row is one button that opens its run in the inspector over
/// the pane (`inspect`), where the run's own controls are; the list draws no other control. It is derived
/// once per change of the thread's runs (`SubagentListPresentation`), never in `body`.
struct SubagentListTab: View {
    var store: NativeThreadStore
    /// Opens a run in the inspector.
    let inspect: (ChildRun) -> Void
    @State private var list = SubagentListPresentation()
    @State private var placed = false

    /// What the list is derived from: the runs, where they were spawned, and the turns' order.
    private struct Key: Equatable {
        var runs: [NativeSubagent]
        var placements: [String: NativeSubagentPlacement]
        var turns: [String]
    }

    private var key: Key { Key(runs: store.subagents, placements: store.placements, turns: store.rows.map(\.id)) }

    var body: some View {
        ZStack {
            if list.isEmpty {
                // The board's `.sl-empty` rule, with no state drawn on it and so no copy of its own: centered, 8pt apart,
                // 32pt around, `ui` in `textSecondary`. The words are the app's.
                VStack(spacing: NW.Space.m) {
                    Text(store.snapshot == nil ? "Loading the thread…" : "No subagents").font(.nw(.ui, weight: .regular))
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.nw.textSecondary)
                .padding(NW.Space.xxxl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // Every head and row is its own element of the lazy stack, so only the rows on screen are built.
                    LazyVStack(spacing: 0) {
                        NWSubagentListSummary(title: list.title, tally: list.tally).equatable()
                        ForEach(list.elements) { element in
                            // One view per element: a container whatever the element is.
                            VStack(spacing: 0) {
                                switch element.kind {
                                case .section(let section):
                                    NWSubagentListSection(section.title, time: section.time).equatable()
                                case .item(let item):
                                    NWSubagentListRow(item.row, open: { inspect(item.run) }).equatable()
                                }
                            }
                        }
                    }
                    .padding(.bottom, NW.Space.xxl)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.nw.bgWindow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Subagents in this thread")
        .onChange(of: key, initial: true) { _, key in
            list = SubagentListPresentation(runs: key.runs, placements: key.placements, turnOrder: key.turns)
        }
    }
}
