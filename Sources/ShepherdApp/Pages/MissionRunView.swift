import SwiftUI
import ShepherdCore
import ShepherdUI
import ShepherdRemote

/// Run (MXRun): the compact route with what is moving, what waits on you and what was decided,
/// beside the selected station's transcript, evidence, inputs and diff.
struct MissionRunPage: View {
    let mission: Mission
    let output: String
    let attemptOutput: [UUID: String]
    let reviews: [MissionRepositoryReview]
    let openThread: (AgentID) -> Void
    let threads: MissionThreads
    private let layout: MissionMapLayout
    @State private var selection: String?
    /// Narrow windows only: the station in place of the route.
    @State private var inspecting = false
    @Environment(\.missionInitialPanes) private var seed

    init(mission: Mission, output: String, attemptOutput: [UUID: String] = [:], reviews: [MissionRepositoryReview], openThread: @escaping (AgentID) -> Void,
         threads: MissionThreads = MissionThreads()) {
        self.mission = mission; self.output = output; self.attemptOutput = attemptOutput; self.reviews = reviews; self.openThread = openThread
        self.threads = threads
        layout = MissionMapLayout(plan: mission.draft.plan ?? MissionPlan())
    }

    private var plan: MissionPlan { mission.draft.plan ?? MissionPlan() }
    private var running: [MissionAttempt] { mission.stationAttempts.filter { $0.status == .running } }
    /// The running station, else the last one that ran.
    private var shown: MissionStation? {
        let id = selection.flatMap { layout.node(id: $0)?.station?.id }
            ?? running.first?.stationID ?? mission.stationAttempts.last?.stationID
            ?? plan.stations.first { $0.kind == .worker }?.id
        return plan.stations.first { $0.id == id }
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < AppLayout.missionNarrowWidth {
                // A narrow window shows the route or the station, as Review shows diff or contract.
                VStack(spacing: 0) {
                    SHSegmentedPicker("Show", selection: $inspecting, options: [(false, "Route"), (true, "Station")])
                        .fixedSize().padding(SH.Space.m)
                    SHHairline()
                    GeometryReader { inner in
                        if inspecting { station } else { route(CGSize(width: inner.size.width, height: inner.size.height)) }
                    }
                }
            } else {
                HStack(spacing: 0) {
                    let width = geometry.size.width * AppLayout.missionRunGraphShare
                    route(CGSize(width: width, height: geometry.size.height)).frame(width: width)
                    Rectangle().fill(Color.sh.lineSubtle).frame(width: 1)
                    station
                }
            }
        }
        .onAppear { if seed.side { inspecting = true } }
    }

    /// The compact route over the frontier, what waits on you and the decisions.
    private func route(_ room: CGSize) -> some View {
        VStack(spacing: 0) {
            // The whole route in the top half, scaled down while it stays readable; past that it scrolls.
            let graph = layout.size(.compact)
            let fit = CGSize(width: room.width - SH.Space.l * 2, height: room.height / 2 - SH.Space.l * 2)
            let scale = min(1, max(AppLayout.missionReadableZoom, min(fit.width / graph.width, fit.height / graph.height)))
            ScrollView([.horizontal, .vertical]) {
                MissionGraph(mission: mission, layout: layout, metrics: .compact, filter: .both,
                             selection: shown?.id.rawValue) { selection = $0; inspecting = true }
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: graph.width * scale, height: graph.height * scale, alignment: .topLeading)
                    .padding(SH.Space.l)
            }
            .frame(maxHeight: room.height / 2)
            SHHairline()
            ScrollView {
                VStack(spacing: 0) {
                    frontier
                    waiting
                    decisions
                }
            }
        }
    }

    @ViewBuilder private var station: some View {
        if let station = shown {
            MissionRunInspector(mission: mission, station: station, attemptOutput: attemptOutput,
                                output: running.count == 1 && running.first?.stationID == station.id ? output : "",
                                review: reviews.first { $0.spaceID == station.laneID }, openThread: openThread, threads: threads,
                                close: { selection = nil; inspecting = false })
                .id(station.id)
        } else {
            Text("Select a station to follow its work.").shText(.body).foregroundStyle(Color.sh.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func title(_ id: MissionStationID?) -> String { plan.stations.first { $0.id == id }?.title ?? "station" }

    private var frontier: some View {
        MissionInspectorSection(title: "Frontier", meta: running.isEmpty ? nil : "\(running.count) moving") {
            if running.isEmpty {
                Text(mission.phase == .running ? "Starting the next stations…" : "Nothing is moving while the mission is \(mission.phase.missionLabel.lowercased()).")
                    .shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textTertiary)
            }
            ForEach(running) { attempt in
                let station = plan.stations.first { $0.id == attempt.stationID }
                Button { selection = attempt.stationID?.rawValue; inspecting = true } label: {
                    HStack(spacing: SH.Space.m) {
                        ProgressView().progressViewStyle(.shSpinner())
                        Text(station?.title ?? "station").shText(.mono).fontWeight(.semibold).lineLimit(1)
                        Text(mission.lane(station?.laneID)?.name ?? "mission").shText(.micro).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
                        Spacer()
                        MissionAttemptClock(attempt: attempt)
                    }
                    .padding(.horizontal, SH.Space.m).frame(height: SH.Height.controlL).contentShape(Rectangle())
                }
                .buttonStyle(.shRow(selected: shown?.id == attempt.stationID))
                .accessibilityLabel("Follow \(station?.title ?? "station")")
            }
            let moving = Set(running.compactMap(\.stationID))
            let next = plan.stations.filter { station in
                mission.latest(station.id)?.status != .succeeded && !moving.contains(station.id)
                    && plan.dependencies.contains { $0.target == station.id && moving.contains($0.source) }
            }
            if !next.isEmpty {
                HStack(spacing: SH.Space.s) {
                    Image(systemName: "chevron.down").font(.sh(.micro)).foregroundStyle(Color.sh.textTertiary)
                    Text("then").shText(.caption).foregroundStyle(Color.sh.textTertiary)
                    Text(next.map(\.title).joined(separator: ", ")).shText(.mono).lineLimit(1)
                    Text("once \(running.count == 1 ? "it passes" : "these pass")").shText(.caption).foregroundStyle(Color.sh.textTertiary)
                }.padding(.horizontal, SH.Space.m)
            }
        }
    }

    private var waiting: some View {
        MissionInspectorSection(title: "Waiting on you") {
            if let question = mission.run?.pendingQuestion {
                Text(question).shText(.body).foregroundStyle(Color.sh.lanternText)
            } else if mission.phase == .paused || mission.phase == .stopped {
                Text(mission.run?.notice ?? "Resume or stop the mission from the header.").shText(.body)
            } else {
                let count = plan.lanes.count
                Text("Nothing. Next check-in is ") + Text("review").font(.sh(.mono)) + Text(", approving \(count) pull request\(count == 1 ? "" : "s").")
            }
        }
        .shText(.body)
    }

    /// The step's own reply after its evidence lines ("Changed: …", stock-contract notes), first line only.
    static func summary(_ output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let reply = lines.drop { !$0.isEmpty }.first { !$0.isEmpty && !$0.hasPrefix("#") }
        return (reply ?? lines.first ?? "done").replacingOccurrences(of: "**", with: "")
    }

    /// What the route decided so far, from receipts: retries, research findings, your answers and verdicts.
    private var decisions: some View {
        let entries = (mission.run?.attempts ?? []).enumerated().compactMap { index, attempt -> (String, String, String, String)? in
            guard let station = plan.stations.first(where: { $0.id == attempt.stationID }) else { return nil }
            let retried = (mission.run?.attempts ?? []).dropFirst(index + 1).contains { $0.stationID == station.id && $0.task == attempt.task }
            let time = attempt.endedAt.map { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened) } ?? ""
            if attempt.status == .failed && retried { return (time, station.title, "failed, retried", "auto") }
            guard attempt.status == .succeeded else { return nil }
            let first = attempt.output.split(separator: "\n").first.map(String.init) ?? "done"
            // A Spec Kit step reads as what it did ("Updated the constitution"); its first output line is evidence
            // ("Changed: …"), and several steps share one station, so the station's title would mislabel them.
            if let command = attempt.command, station.kind == .research {
                return (time, command.plannerWords.done, Self.summary(attempt.output), "planner")
            }
            switch station.kind {
            case .research: return (time, station.title, first, "research")
            case .decision: return (time, station.title, first, "you")
            case .validator: return (time, station.title, "passed", "validator")
            default: return nil
            }
        }
        return MissionInspectorSection(title: "Decisions so far") {
            if entries.isEmpty { Text("None yet.").shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textTertiary) }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: SH.Space.l) {
                    Text(entry.0).shText(.micro).foregroundStyle(Color.sh.textTertiary).fixedSize()
                    Text(entry.1).shText(.mono).fontWeight(.semibold).lineLimit(1)
                    Image(systemName: "arrow.right").font(.sh(.micro)).foregroundStyle(Color.sh.textTertiary)
                    Text(entry.2).shText(.ui).fontWeight(.regular).lineLimit(1)
                    Spacer(minLength: SH.Space.m)
                    Text(entry.3).shText(.caption).foregroundStyle(Color.sh.textTertiary).fixedSize()
                }.accessibilityElement(children: .combine)
            }
        }
    }
}

/// "14m" since the attempt started, ticking while it runs.
struct MissionAttemptClock: View {
    let attempt: MissionAttempt
    var body: some View {
        TimelineView(.periodic(from: .now, by: AppLayout.missionBudgetRefresh)) { clock in
            if let start = attempt.startedAt {
                Text(MissionFormat.duration((attempt.endedAt ?? clock.date.timeIntervalSince1970) - start))
                    .shText(.micro).foregroundStyle(Color.sh.textTertiary).monospacedDigit()
            }
        }
    }
}

private enum MissionRunTab: Hashable { case transcript, evidence, inputs, diff }

private struct MissionRunInspector: View {
    let mission: Mission
    let station: MissionStation
    let attemptOutput: [UUID: String]
    /// The mission's latest live text, used only when one station runs and the attempt has none of its own.
    let output: String
    let review: MissionRepositoryReview?
    let openThread: (AgentID) -> Void
    let threads: MissionThreads
    let close: () -> Void
    @State private var tab = MissionRunTab.transcript
    /// The latest attempt's own thread, re-read when the attempt or its run changes state (its `send`
    /// exists only while the turn can be steered).
    @State private var source: MissionThreadSource?
    /// Re-read when the attempt, its status, the run's phase, or whether its agent exists changes. A
    /// worker's agent is reserved before it is created: the store read then is pruned once state
    /// moves on, so the source is read again when the agent appears.
    private var sourceKey: String {
        let live = latest?.agentID.map(threads.isLive) ?? false
        return "\(latest?.id.uuidString ?? "")|\(latest?.status.rawValue ?? "")|\(mission.phase.rawValue)|\(live)"
    }

    private var plan: MissionPlan { mission.draft.plan ?? MissionPlan() }
    private var attempts: [MissionAttempt] { mission.run?.attempts.filter { $0.stationID == station.id } ?? [] }
    private var latest: MissionAttempt? { attempts.last }
    private var inputs: [MissionDependency] { plan.dependencies.filter { $0.target == station.id && $0.kind == .data } }
    private func title(_ id: MissionStationID) -> String { plan.stations.first { $0.id == id }?.title ?? "station" }

    var body: some View {
        VStack(spacing: 0) {
            MissionInspectorHead(symbol: station.kind.symbol, title: station.title, tag: station.kind == .check ? "command" : "agent",
                                 pill: latest.map { attempt in
                                     (attempt.status.missionState, attempt.status.rawValue.capitalized + (attempt.startedAt.map { " · " + MissionFormat.duration((attempt.endedAt ?? Date().timeIntervalSince1970) - $0) } ?? ""))
                                 },
                                 lane: mission.lane(station.laneID)?.name, close: close) {
                if let agent = latest?.agentID {
                    Button { openThread(agent) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.shIcon).shHelp("Open its thread").accessibilityLabel("Open its thread")
                }
            }
            HStack(spacing: SH.Space.xl) {
                tabButton(.transcript, "Transcript")
                tabButton(.evidence, "Evidence")
                tabButton(.inputs, "Inputs · \(inputs.count)")
                tabButton(.diff, "Diff", stat: review.map { ($0.files.reduce(0) { $0 + $1.addedCount }, $0.files.reduce(0) { $0 + $1.removedCount }) })
                Spacer()
                Text("\(station.model ?? mission.run?.model ?? "") · \(MissionFormat.tokens(attempts.reduce(0) { $0 + $1.tokens })) tok")
                    .shText(.micro).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
            }
            .padding(.horizontal, SH.Space.xl)
            .frame(height: SHPageMetrics.headerHeight)
            .overlay(alignment: .bottom) { SHHairline() }
            if tab == .transcript, let source {
                // The station's real thread (tool rows, edits, commands), steered only through the mission.
                MissionStationThread(source: source, title: station.title, report: threads.report)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: SH.Space.l) {
                        switch tab {
                        case .transcript: transcript
                        case .evidence: evidence
                        case .inputs: inputList
                        case .diff: diff
                        }
                    }
                    .padding(SH.Space.xxl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Color.sh.bgWindow)
        .task(id: sourceKey) {
            // Only an agent the app holds has a store that lives; before that, the receipts' text shows.
            guard let latest, let agent = latest.agentID, threads.isLive(agent) else { source = nil; return }
            source = threads.source(latest.id)
        }
    }

    private func tabButton(_ value: MissionRunTab, _ label: String, stat: (Int, Int)? = nil) -> some View {
        Button { tab = value } label: {
            HStack(spacing: SH.Space.s) {
                Text(label).font(.sh(.ui, weight: tab == value ? .semibold : .regular))
                if let stat { SHDiffStat(added: stat.0, removed: stat.1) }
            }
            .foregroundStyle(tab == value ? Color.sh.textPrimary : Color.sh.textSecondary)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if tab == value { Rectangle().fill(Color.sh.textPrimary).frame(height: AppLayout.missionSelectedBorder) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }

    @ViewBuilder private var transcript: some View {
        if !inputs.isEmpty {
            HStack(spacing: SH.Space.s) {
                SHGlyph.gitBranch.image.foregroundStyle(Color.sh.textTertiary)
                Text("Started from").shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textTertiary)
                ForEach(inputs, id: \.self) { wire in
                    Text(wire.artifact ?? "output").shText(.mono).foregroundStyle(Color.sh.synKeyword)
                }
                if let start = latest?.startedAt {
                    Text("at \(Date(timeIntervalSince1970: start).formatted(date: .omitted, time: .shortened))").shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textTertiary)
                }
            }
        }
        if attempts.isEmpty {
            Text("This station has not started.").shText(.body).foregroundStyle(Color.sh.textTertiary)
        }
        ForEach(Array(attempts.enumerated()), id: \.element.id) { index, attempt in
            if attempts.count > 1 {
                HStack(spacing: SH.Space.s) {
                    SHStatusDot(attempt.status.missionState)
                    // One agent per task shares its phase's station: its rows name the task, not an attempt number.
                    Text("\(attempt.task ?? "Attempt \(index + 1)") · \(attempt.status.rawValue)").shText(.caption).foregroundStyle(Color.sh.textTertiary)
                }
            }
            let live = attempt.status == .running ? (attemptOutput[attempt.id] ?? output) : ""
            let text = live.isEmpty ? attempt.output : live
            if text.isEmpty && attempt.status == .running {
                HStack(spacing: SH.Space.m) {
                    ProgressView().progressViewStyle(.shSpinner())
                    Text("Working…").shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textSecondary)
                }
            } else if station.kind == .check {
                Text(text).shText(.code).textSelection(.enabled)
                    .padding(SH.Space.l).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            } else {
                MissionProse(text, live: attempt.status == .running)
            }
        }
    }

    @ViewBuilder private var evidence: some View {
        if let exit = latest?.exitCode {
            MissionFactRow(label: "Exit status") { Text("\(exit)").shText(.mono).foregroundStyle(exit == 0 ? Color.sh.done : Color.sh.failed) }
        }
        let gates = plan.stations.filter { gate in
            (gate.kind == .check || gate.kind == .validator) && ((try? plan.dataConsumers(of: [station.id]))?.contains(gate.id) == true || gate.id == station.id)
        }
        if gates.isEmpty { Text("No check or validator reads this station's output.").shText(.body).foregroundStyle(Color.sh.textTertiary) }
        ForEach(gates) { gate in
            let attempt = mission.latest(gate.id)
            VStack(alignment: .leading, spacing: SH.Space.s) {
                HStack(spacing: SH.Space.m) {
                    SHStateGlyph(attempt?.status.missionState ?? .queued)
                    Text(gate.kind == .check ? (gate.command ?? gate.title) : gate.title).shText(.mono).fontWeight(.semibold)
                    Spacer()
                    Text(attempt?.status.rawValue ?? "not run").shText(.micro).foregroundStyle(Color.sh.textTertiary)
                }
                if let output = attempt?.output, !output.isEmpty {
                    Text(output).shText(.caption).foregroundStyle(Color.sh.textSecondary).lineLimit(6).textSelection(.enabled)
                }
            }
            .padding(SH.Space.l)
            .shCard()
        }
    }

    @ViewBuilder private var inputList: some View {
        if inputs.isEmpty { Text("This station has no data inputs.").shText(.body).foregroundStyle(Color.sh.textTertiary) }
        ForEach(inputs, id: \.self) { wire in
            VStack(alignment: .leading, spacing: SH.Space.s) {
                MissionWireRow(artifact: wire.artifact ?? "output", other: title(wire.source), incoming: true,
                               state: mission.latest(wire.source)?.status.missionState)
                if let output = mission.latest(wire.source)?.output, !output.isEmpty {
                    Text(output).shText(.caption).foregroundStyle(Color.sh.textSecondary).lineLimit(4).textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder private var diff: some View {
        if let review, !review.files.isEmpty {
            Text("\(review.name) · \(review.branch)").shText(.mono).foregroundStyle(Color.sh.textTertiary)
            ForEach(review.files) { file in
                HStack(spacing: SH.Space.m) {
                    Text(file.isNew ? "add" : file.isDeleted ? "delete" : file.isRenamed ? "rename" : "edit").shText(.micro).foregroundStyle(Color.sh.textTertiary)
                    Text(file.displayPath).shText(.mono).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    SHDiffStat(added: file.addedCount, removed: file.removedCount)
                }
            }
        } else {
            Text(station.laneID == nil ? "Orchestration stations read every worktree and change none." : "No changes collected in this lane yet.")
                .shText(.body).foregroundStyle(Color.sh.textTertiary)
        }
    }
}

/// A station's own native thread inside Run. Its composer sends only through the source's `send`
/// (the controller's owned steer); while there is no `send` (a finished turn, or not the mission's to
/// steer) the thread is read-only and draws no composer. While a steer waits to be taken it shows in
/// the composer's Up next as "Waiting for <station> to take it…"; the words clear only once the
/// steer is consumed, and a refusal or timeout keeps them and reports why.
private struct MissionStationThread: View {
    let source: MissionThreadSource
    let title: String
    let report: (String) -> Void
    @State private var gate = MissionSendGate()

    var body: some View {
        let steer = source.send
        let placeholder = "Steer \(title) — delivered before its next turn"
        let waiting = gate.pending.map { [ProjectHeldMessage(id: $0.id, text: $0.text, note: "Waiting for \(title) to take it…", phase: .delivering)] } ?? []
        ThreadView(store: source.store, active: true, isFocused: false, request: source.request, preview: source.preview, agentName: title)
            .environment(\.projectComposerSend, ProjectComposerSend(placeholder: placeholder, carriesImages: false, send: { [gate, report] text, images in
                // Every refusal says why in the banner; the words stay in the composer.
                guard let steer else { report("\(title) can't take a steer now: its turn has ended or isn't the mission's to steer. Your words are kept."); return false }
                guard images.isEmpty else { report("Steering a mission station takes words only. Remove the images and send again."); return false }
                let landed = await gate.run(text) {
                    do { try await steer(text); return true } catch { report(String(describing: error)); return false }
                }
                guard let landed else { report("A steer to \(title) is still on its way. Send again once it lands."); return false }
                return landed
            }, held: { waiting }))
            .environment(\.projectWorkerThread, ProjectWorkerThreadStyle(placeholder: placeholder, composerHidden: steer == nil))
            // A replaced store is a new poll loop: the thread view follows the store, not just the agent.
            .id(ObjectIdentifier(source.store))
    }
}

/// One steer at a time: a second send while one is on its way is refused, keeping its words.
@MainActor @Observable private final class MissionSendGate {
    private(set) var pending: (id: UUID, text: String)?
    /// nil when another steer is still on its way (nothing was sent); else whether this one landed.
    func run(_ text: String, _ operation: () async -> Bool) async -> Bool? {
        guard pending == nil else { return nil }
        pending = (UUID(), text)
        defer { pending = nil }
        return await operation()
    }
}
