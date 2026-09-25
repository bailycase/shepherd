import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// A thread's runs (MobileSubagents board): "This turn" as cards, each answering its question in
/// place, then "Earlier in this thread" as rows. Pushed on iPhone; the iPad shows the same list
/// in the inspector beside the thread.
struct SubagentListScreen: View {
    let ref: AgentRef
    @Environment(ThreadStores.self) private var threads

    var body: some View {
        let store = threads.store(for: ref)
        ScrollView {
            SubagentListContent(ref: ref, store: store, select: nil)
                .frame(maxWidth: MobileLayout.threadMaxWidth)
                .padding(MobileLayout.gutter)
                .frame(maxWidth: .infinity)
        }
        .background(Color.nw.bgSunken)
        .navigationTitle("Subagents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) { SubagentListTitle(store: store) }
        }
        .keepsThreadLive(ref)
    }
}

/// "Subagents" over "● 1 running · 1 needs you".
struct SubagentListTitle: View {
    let store: NativeThreadStore

    var body: some View {
        let tally = nativeRunTally(store.subagents)
        VStack(spacing: NW.Space.xxs) {
            Text("Subagents").font(.nw(.headline)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
            if let tally {
                let state = AgentState(tally.phase)
                HStack(spacing: NW.Space.s) {
                    NWStatusDot(state)
                    Text(tally.text).foregroundStyle(state.textColor)
                }
                .font(.nw(.caption, weight: .medium))
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The list's sections. `select` opens a run in place (the iPad inspector); nil pushes it.
struct SubagentListContent: View {
    let ref: AgentRef
    let store: NativeThreadStore
    let select: ((String) -> Void)?
    @Environment(MobileNavigator.self) private var navigator
    @State private var list = SubagentList()

    var body: some View {
        let key = SubagentList.Key(store)
        let commands = SubagentCommands(store: store, enabled: store.takesSubagentCommands)
        let selected = SubagentInspection.shared.selected(in: ref)
        VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
            SubagentHostNotice(ref: ref, subject: "runs")
            if let notice = store.notice { Text(notice).font(.nw(.caption)).foregroundStyle(Color.nw.failed) }
            if list.isEmpty {
                NWEmptyState(Text("No subagents"), message: store.snapshot == nil ? "Loading the thread…"
                             : "Runs this thread starts show here, with their questions and results.")
                    .frame(maxWidth: .infinity)
                    .padding(.top, NW.Space.xxxl)
            }
            if !list.current.isEmpty {
                VStack(alignment: .leading, spacing: MobileLayout.subagentSectionSpacing) {
                    sectionHead("This turn", trailing: "\(list.current.count)", mono: true)
                    ForEach(list.current) { summary in
                        card(summary, selected: summary.runID == selected, commands: commands)
                    }
                }
            }
            if !list.earlier.isEmpty {
                VStack(alignment: .leading, spacing: MobileLayout.subagentSectionSpacing) {
                    sectionHead("Earlier in this thread", trailing: "kept after they finish", mono: false)
                    NWRunHistoryList(list.earlier.map(SubagentValues.historyRow)) { id in
                        if let run = list.earlier.first(where: { $0.id == id }) { open(run.runID) }
                    }
                    .equatable()
                }
                .padding(.top, NW.Space.s)
            }
        }
        .onChange(of: key, initial: true) { list = SubagentList(store) }
    }

    private func sectionHead(_ title: String, trailing: String, mono: Bool) -> some View {
        HStack {
            Text(title).font(.nw(.ui, weight: .semibold)).foregroundStyle(Color.nw.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: NW.Space.m)
            Text(trailing).font(mono ? .nw(.mono) : .nw(.caption)).foregroundStyle(Color.nw.textTertiary)
        }
        .padding(.horizontal, NW.Space.xs)
    }

    private func card(_ summary: NativeRunSummary, selected: Bool, commands: SubagentCommands) -> some View {
        let run = store.subagents.first { $0.id == summary.id }
        return NWRunCard(SubagentValues.card(summary), isSelected: selected, isEnabled: commands.enabled,
                         open: { open(summary.runID) },
                         answer: summary.phase == .needsYou ? commands.answer(summary.runID) : nil,
                         rerun: summary.phase == .failed ? { commands.control(summary.runID, .rerun) } : nil)
            .equatable()
            .contextMenu {
                Button("Open", systemImage: "arrow.up.right") { open(summary.runID) }
                if let run { SubagentControlItems(run: run, commands: commands) }
            }
            .accessibilityActions {
                if let run, commands.enabled {
                    ForEach(nativeRunControls(run), id: \.self) { control in
                        Button(control.title) { commands.control(run.runID, control) }
                    }
                }
            }
    }

    private func open(_ runID: String) {
        if let select { select(runID) } else { SubagentOpening.open(.run(ref, runID: runID), navigator: navigator) }
    }
}

/// Why the runs on screen may be stale or read-only: the host is forgotten or offline, or the
/// agent is gone from it. Nothing while the host serves the thread.
struct SubagentHostNotice: View {
    let ref: AgentRef
    /// What is shown from before: "runs", "run".
    let subject: String
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        if let text {
            Text(text).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var text: String? {
        guard let host = hosts.host(ref.host) else { return "This host was forgotten." }
        if !host.phase.isConnected { return "\(host.name) is offline · showing the last known \(subject)" }
        if host.agent(ref.agent) == nil { return "This agent is no longer on \(host.name)." }
        return nil
    }
}
