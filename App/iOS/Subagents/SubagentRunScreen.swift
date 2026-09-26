import SwiftUI
import UIKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// One run on iPhone (MobileSubagent board): its name and state as the title, the goal from the
/// parent, its question while it waits on you, its own transcript following live, and a steer
/// field that reaches only this child. A finished run is read-only, with Re-run and Copy.
struct SubagentRunScreen: View {
    let ref: AgentRef
    let runID: String
    @Environment(ThreadStores.self) private var threads

    var body: some View {
        let store = threads.store(for: ref)
        let run = store.subagents.first { $0.runID == runID }
        SubagentRunView(ref: ref, store: store, runID: runID, compact: true)
            .background(Color.nw.bgWindow)
            .navigationTitle(run.map { nativeRunNames($0).name } ?? "Subagent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .principal) { SubagentRunTitle(run: run) }
                ToolbarItem(placement: .topBarTrailing) { SubagentRunMenu(store: store, run: run) }
            }
            .keepsThreadLive(ref)
    }
}

/// "worker" over "● Running · 37m".
struct SubagentRunTitle: View {
    let run: NativeSubagent?

    var body: some View {
        let phase = run.map(nativeRunPhase)
        let state = phase.map { AgentState($0) } ?? .idle
        VStack(spacing: NW.Space.xxs) {
            Text(run.map { nativeRunNames($0).name } ?? "Subagent").font(.nw(.headline)).foregroundStyle(Color.nw.textPrimary)
                .lineLimit(1)
            HStack(spacing: NW.Space.s) {
                NWStatusDot(state)
                Text(phase.map(nativeRunPhaseLabel) ?? "No longer listed").foregroundStyle(state.textColor)
                if let started = run?.startedAt {
                    Text("·").foregroundStyle(Color.nw.textTertiary)
                    NWElapsedText(since: SubagentValues.date(started)!, until: SubagentValues.date(run?.isTerminal == true ? run?.endedAt : nil))
                        .font(.nw(.mono)).foregroundStyle(Color.nw.textTertiary)
                }
            }
            .font(.nw(.caption, weight: .medium))
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The run's options: Pause or Continue, Stop, Re-run, and Copy transcript.
struct SubagentRunMenu: View {
    let store: NativeThreadStore
    let run: NativeSubagent?
    var copy: (() -> Void)?

    var body: some View {
        Menu {
            if let run {
                SubagentControlItems(run: run, commands: SubagentCommands(store: store, enabled: store.takesSubagentCommands))
            }
            if let copy { Button("Copy Transcript", systemImage: "doc.on.doc", action: copy) }
        } label: {
            Label("Subagent options", systemImage: "ellipsis")
        }
        .disabled(run == nil)
    }
}

/// One run's body, on iPhone and in the iPad inspector: the brief, its question, the transcript,
/// then the steer field or, once finished, Re-run and Copy transcript.
struct SubagentRunView: View {
    let ref: AgentRef
    let store: NativeThreadStore
    let runID: String
    /// iPhone: the goal box heads the transcript. The iPad inspector heads it with the run's card.
    let compact: Bool
    @State private var transcript = SubagentTranscriptModel()
    @State private var draft = ""
    @State private var copyNotice: String?
    @FocusState private var steering: Bool
    @Environment(\.scenePhase) private var scenePhase

    private struct FollowKey: Hashable {
        var runID: String
        var startedAt: Double?
        var ready: Bool
        var active: Bool
    }

    var body: some View {
        let run = store.subagents.first { $0.runID == runID }
        let summary = run.map(nativeRunSummary)
        let commands = SubagentCommands(store: store, enabled: store.takesSubagentCommands)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                    SubagentHostNotice(ref: ref, subject: "run")
                    if let summary {
                        // The inspector heads the run with its card, which carries its question.
                        if !compact {
                            NWRunCard(SubagentValues.card(summary), isEnabled: commands.enabled, open: nil,
                                      answer: summary.phase == .needsYou ? commands.answer(runID) : nil)
                                .equatable()
                        }
                        NWRunGoal(goal: summary.goal, label: compact ? "Goal · from the parent" : "Goal",
                                  note: run.flatMap(Self.goalNote), result: summary.result,
                                  resultState: AgentState(summary.phase))
                        if compact, let question = summary.question {
                            NWRunQuestion(question, options: summary.options, name: summary.name, isEnabled: commands.enabled,
                                          answer: commands.answer(runID))
                                .padding(NW.Space.l)
                                .background(Color.nw.lanternTint, in: RoundedRectangle(cornerRadius: MobileLayout.cardRadius))
                        }
                    } else {
                        Text("This run is no longer listed.").font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                    }
                    if !compact {
                        Text("Its run").nwSectionLabel().padding(.top, NW.Space.s)
                    }
                    SubagentTranscriptList(model: transcript, live: run.flatMap(nativeRunLive),
                                           emptyText: run == nil ? "This run is no longer listed." : "No transcript yet.",
                                           showsTask: !compact)
                    footer(run)
                    Color.clear.frame(height: 1).id("run-bottom")
                }
                .padding(MobileLayout.gutter)
                .frame(maxWidth: MobileLayout.threadMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(run?.isTerminal == true ? .top : .bottom, for: .initialOffset)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar(run, summary: summary, commands: commands) }
            .onChange(of: transcript.turns.count) { _, _ in
                if run?.isTerminal == false { proxy.scrollTo("run-bottom", anchor: .bottom) }
            }
        }
        .task(id: FollowKey(runID: runID, startedAt: run?.startedAt, ready: store.ready, active: scenePhase == .active)) {
            guard store.ready, scenePhase == .active else { return }
            let store = store, runID = runID
            await transcript.follow(store: store, runID: runID) { store.subagents.first { $0.runID == runID }?.isTerminal != true }
        }
    }

    /// "step 1 of 3 · 62%" beside a live run's goal.
    static func goalNote(_ run: NativeSubagent) -> String? {
        guard !run.isTerminal else { return nil }
        var parts: [String] = []
        if let step = run.step { parts.append("step \(step.index) of \(step.total)") }
        if let percent = run.contextPercent { parts.append("\(Int(percent.rounded()))%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private func footer(_ run: NativeSubagent?) -> some View {
        if transcript.earlierCount > 0 {
            HStack(spacing: NW.Space.s) {
                Text(nativeCount(transcript.earlierCount, "earlier turn")).font(.nw(.mono)).foregroundStyle(Color.nw.textTertiary)
                Button(transcript.loadingOlder ? "Loading…" : "Show all") { Task { await transcript.loadAll(store: store) } }
                    .buttonStyle(.nw(.ghost, size: .s))
                    .disabled(transcript.loadingOlder)
            }
        }
    }

    @ViewBuilder private func bottomBar(_ run: NativeSubagent?, summary: NativeRunSummary?, commands: SubagentCommands) -> some View {
        VStack(alignment: .leading, spacing: NW.Space.s) {
            if let notice = copyNotice ?? store.notice {
                Text(notice).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            }
            if let run, let summary, nativeRunAcceptsSteer(run) {
                NWSteerField(text: $draft, prompt: "Steer \(summary.name)…",
                             caption: "to: \(summary.name) · not the parent · lands before its next turn",
                             isEnabled: commands.enabled, focus: $steering, accessibilityLabel: "Steer \(summary.name)") {
                    steer(commands)
                }
            } else if let run {
                HStack(spacing: NW.Space.m) {
                    Button("Re-run") { commands.control(run.runID, .rerun) }
                        .buttonStyle(.nw(.secondary, size: .l))
                        .disabled(!commands.enabled)
                        .accessibilityLabel("Re-run \(summary?.name ?? "subagent")")
                    Button("Copy transcript") { copy() }
                        .buttonStyle(.nw(.ghost, size: .l))
                        .disabled(transcript.messages.isEmpty)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, MobileLayout.gutter)
        .padding(.vertical, NW.Space.m)
        .frame(maxWidth: MobileLayout.threadMaxWidth + 2 * MobileLayout.gutter)
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .top) { NWHairline() }
    }

    private func steer(_ commands: SubagentCommands) {
        guard let command = NativeRunCommand.steer(draft), commands.enabled else { return }
        let sent = draft
        let target = runID
        Task {
            await store.subagentCommand(runID: target, action: command.action, text: command.text, mode: command.mode)
            // A failed send keeps the draft.
            if store.notice == nil, draft == sent { draft = "" }
        }
    }

    private func copy() {
        Task {
            if let text = await transcript.copyText(store: store) {
                UIPasteboard.general.string = text
                copyNotice = nil
            } else {
                copyNotice = "Couldn't load the full transcript. Nothing was copied."
            }
        }
    }
}
