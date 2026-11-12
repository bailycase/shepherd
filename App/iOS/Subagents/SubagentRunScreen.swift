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
            .background(Color.sh.bgWindow)
            .navigationTitle(run.map(nativeRunAgentName) ?? "Subagent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .principal) { SubagentRunTitle(run: run) }
                // The run's controls in the system's ••• menu, which overflows with the bar where it
                // runs down the side (iPhone Duo).
                if let run {
                    ToolbarOverflowMenu {
                        SubagentControlItems(run: run, commands: SubagentCommands(store: store, enabled: store.takesSubagentCommands))
                    }
                }
            }
            .keepsThreadLive(ref)
    }
}

/// "worker" over "Running · 37m" (MobileSubagent: plain `textTertiary`, no dot; the agent's name,
/// the task is the goal below).
struct SubagentRunTitle: View {
    let run: NativeSubagent?

    var body: some View {
        let phase = run.map(nativeRunPhase)
        let timing = run.map(nativeTrayRow)
        VStack(spacing: SH.Space.xxs) {
            Text(run.map(nativeRunAgentName) ?? "Subagent").font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1)
            HStack(spacing: SH.Space.s) {
                Text(phase.map(nativeRunPhaseLabel) ?? "No longer listed")
                if let started = timing?.since {
                    Text("·")
                    SHElapsedText(since: SubagentValues.date(started)!, until: SubagentValues.date(timing?.until))
                }
            }
            .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
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
    @State private var follower = NativeScrollFollower()
    /// Lands the run on its tail after layout; only a mount's first few landings run inside it (ThreadTailPin).
    @State private var tailPin = ThreadTailPin()
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
                            SHRunCard(SubagentValues.card(summary), isEnabled: commands.enabled, open: nil)
                                .equatable()
                        }
                        SHRunGoal(goal: summary.goal, label: compact ? "Goal · from the parent" : "Goal",
                                  note: run.flatMap(Self.goalNote), result: summary.result,
                                  resultState: AgentState(summary.phase))
                        if compact, let question = summary.question {
                            SHRunQuestion(question, options: summary.options)
                                .padding(SH.Space.l)
                                .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: MobileLayout.cardRadius))
                        }
                    } else {
                        Text("This run is no longer listed.").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    }
                    if !compact {
                        Text("Its run").shSectionLabel().padding(.top, SH.Space.s)
                    }
                    if let error = transcript.loadError {
                        Text(error).font(.sh(.caption)).foregroundStyle(Color.sh.failed)
                        Button("Retry") { Task { await transcript.reload(store: store) } }
                            .buttonStyle(.sh(.secondary))
                            .disabled(transcript.loading)
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
            .onScrollGeometryChange(for: TailReading.self, of: Self.reading) { old, new in
                // This runs inside the layout pass, so it records and the pin lands after it; only
                // a mount's first few landings run here, so its first frames are already at the tail.
                let wants = follow { $0.observe(from: old.probe, to: new.probe, gesture: $0.userScrolling, nativeAnchor: false) }
                tailPin.reading(distance: NativeTailRepin.distance(of: new.probe, belowMarker: MobileLayout.gutter),
                                wants: wants && run?.isTerminal == false, resized: new.resized(from: old), land: lander(proxy))
            }
            .onScrollPhaseChange { old, phase, context in
                follow { follower in
                    follower.userScrolling = phase == .interacting
                    if phase == .idle, old == .interacting || old == .decelerating {
                        follower.observe(distanceFromBottom: Self.probe(context.geometry).distance, userIntent: true)
                    }
                    return false
                }
                tailPin.reader(scrolling: phase != .idle, touching: phase == .tracking || phase == .interacting)
            }
            .onChange(of: transcript.turns.last) { _, _ in
                follow { $0.contentArrived(); return false }
                if !transcript.loadingOlder, run?.isTerminal == false { tailPin.outputArrived() }
            }
            .overlay(alignment: .bottom) {
                SHJumpToLatest(action: follower.showsJump(running: run?.isTerminal == false) ? {
                    follow { $0.jumpToLatest(); return false }
                    tailPin.asked(lander(proxy))
                } : nil)
            }
            .onDisappear { tailPin.stop() }
        }
        .task(id: FollowKey(runID: runID, startedAt: run?.startedAt, ready: store.ready, active: scenePhase == .active)) {
            guard store.ready, scenePhase == .active else { return }
            let store = store, runID = runID
            await transcript.follow(store: store, runID: runID) { store.subagents.first { $0.runID == runID }?.isTerminal != true }
        }
    }

    /// Applies a change to the follower, writing it back only when it changed, so a scroll frame
    /// that changes nothing redraws nothing. Returns what the change returned.
    @discardableResult
    private func follow(_ change: (inout NativeScrollFollower) -> Bool) -> Bool {
        var next = follower
        let result = change(&next)
        if next != follower { follower = next }
        return result
    }

    /// What the pin calls once the layout pass that asked is over: a live run lands on its tail
    /// while the reader still follows it and has not taken hold of it.
    private func lander(_ proxy: ScrollViewProxy) -> ThreadTailPin.Land {
        { resized in
            guard follower.sticky, !follower.userScrolling,
                  store.subagents.first(where: { $0.runID == runID })?.isTerminal == false else { return }
            SHRenderProbe.tick(resized ? "subagent.tailLandingResized" : "subagent.tailLanding")
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo("run-bottom", anchor: .bottom) }
        }
    }

    private static func reading(_ geometry: ScrollGeometry) -> TailReading {
        TailReading(probe: probe(geometry), width: geometry.containerSize.width)
    }

    private static func probe(_ geometry: ScrollGeometry) -> NativeScrollProbe {
        NativeScrollProbe(content: geometry.contentSize.height, offset: geometry.contentOffset.y,
                          container: geometry.containerSize.height, insetTop: geometry.contentInsets.top,
                          insetBottom: geometry.contentInsets.bottom)
    }

    /// "step 1 of 3 · 62%" beside a live run's goal.
    static func goalNote(_ run: NativeSubagent) -> String? {
        guard !run.isTerminal else { return nil }
        var parts: [String] = []
        if let step = run.step { parts.append("step \(step.index) of \(step.total)") }
        if let percent = run.contextPercent { parts.append(nativeContextPercentText(percent)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private func footer(_ run: NativeSubagent?) -> some View {
        if transcript.earlierCount > 0 {
            HStack(spacing: SH.Space.s) {
                Text(nativeCount(transcript.earlierCount, "earlier turn")).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
                Button(transcript.loadingOlder ? "Loading…" : "Show all") {
                    follower.beginJump()
                    Task { await transcript.loadAll(store: store) }
                }
                    .buttonStyle(.sh(.ghost, size: .s))
                    .disabled(transcript.loadingOlder)
            }
        }
    }

    @ViewBuilder private func bottomBar(_ run: NativeSubagent?, summary: NativeRunSummary?, commands: SubagentCommands) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            if let notice = copyNotice ?? store.notice {
                Text(notice).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            }
            if let run, let summary, nativeRunAcceptsSteer(run) {
                // The same Steer command, called Reply while the run waits on its parent's answer.
                let words = nativeRunSteerWords(run)
                // "Steer worker…", the agent, not the task (MobileSubagent, iPadSteer).
                let agent = summary.role ?? summary.name
                SHSteerField(text: $draft, prompt: "\(words.label(agent))…",
                             caption: words.caption(agent),
                             isEnabled: commands.enabled, focus: $steering, accessibilityLabel: words.label(agent),
                             sendLabel: words.verb) {
                    steer(commands)
                }
            } else if let run {
                HStack(spacing: SH.Space.m) {
                    Button("Re-run") { commands.control(run.runID, .rerun) }
                        .buttonStyle(.sh(.secondary, size: .l))
                        .disabled(!commands.enabled)
                        .accessibilityLabel("Re-run \(summary?.name ?? "subagent")")
                    Button("Copy transcript") { copy() }
                        .buttonStyle(.sh(.ghost, size: .l))
                        .disabled(transcript.messages.isEmpty)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, MobileLayout.gutter)
        .padding(.vertical, SH.Space.m)
        .frame(maxWidth: MobileLayout.threadMaxWidth + 2 * MobileLayout.gutter)
        .frame(maxWidth: .infinity)
        .background(Color.sh.bgWindow)
        .overlay(alignment: .top) { SHHairline() }
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
