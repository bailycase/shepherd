import SwiftUI
import ShepherdCore
import ShepherdUI

// MARK: Spec Kit, behind the planner

/// The steps the planner runs in each repository, in order, as it reports them.
private let specKitPlanningSteps: [SpecKitCommand] = [.constitution, .specify, .clarify, .plan, .tasks, .analyze]

extension SpecKitCommand {
    /// What the step did, in the planner's words (the command stays in Details and the thread).
    var plannerWords: (done: String, working: String, file: String?) {
        switch self {
        case .specify: ("Wrote the spec", "Writing the spec", "spec.md")
        case .clarify: ("Clarified the spec", "Clarifying the spec", "spec.md")
        case .plan: ("Planned the work", "Planning the work", "plan.md")
        case .tasks: ("Broke it into tasks", "Breaking it into tasks", "tasks.md")
        case .analyze: ("Checked the artifacts", "Checking the artifacts", nil)
        case .checklist: ("Wrote a checklist", "Writing a checklist", nil)
        case .constitution: ("Updated the constitution", "Updating the constitution", nil)
        case .implement: ("Implemented", "Implementing", nil)
        case .converge: ("Wrote the completion report", "Writing the completion report", nil)
        }
    }
}

extension Mission {
    var specKit: MissionSpecKitRun? { run?.specKit }

    /// A station's latest receipt, as the pages draw it. One /speckit.implement turn works through every phase of
    /// tasks.md, so a Spec Kit map's phase stations all read their repository's one implement receipt.
    func latest(_ station: MissionStationID) -> MissionAttempt? {
        guard let run else { return nil }
        if specKit != nil, let drawn = draft.plan?.stations.first(where: { $0.id == station }), drawn.kind == .worker,
           let lane = drawn.laneID {
            return run.latest(SpecKit.stationID(id, lane, "phase-0"))
        }
        return run.latest(station)
    }

    /// Every repository carries the owner's grant to its current Spec Kit files.
    var specKitConsented: Bool {
        guard let lanes = specKit?.lanes, !lanes.isEmpty else { return false }
        return lanes.allSatisfy { $0.consentFingerprint != nil }
    }

    /// Every repository finished this step, from its own station's receipts.
    func specKitFinished(_ command: SpecKitCommand) -> Bool {
        guard let lanes = specKit?.lanes, !lanes.isEmpty, let run else { return false }
        return lanes.allSatisfy { lane in
            let station = SpecKit.stationID(id, lane.spaceID, command.rawValue)
            return run.attempts.contains { $0.stationID == station && $0.command == command && $0.status == .succeeded }
        }
    }

    /// The step still missing somewhere (specify → plan → tasks); nil once the map is ready.
    var specKitNext: SpecKitCommand? {
        guard specKit != nil else { return nil }
        return [SpecKitCommand.specify, .plan, .tasks].first { !specKitFinished($0) }
    }

    /// The planner's work so far, from the planning turns' receipts, oldest first.
    var specKitActivity: [(lane: String, command: SpecKitCommand, attempt: MissionAttempt)] {
        guard let specKit, let run else { return [] }
        var stations: [MissionStationID: String] = [:]
        for lane in specKit.lanes {
            let name = self.lane(lane.spaceID)?.name ?? "repository"
            for key in ["specify", "plan", "tasks"] { stations[SpecKit.stationID(id, lane.spaceID, key)] = name }
        }
        return run.attempts.compactMap { attempt in
            guard let station = attempt.stationID, let name = stations[station], let command = attempt.command,
                  specKitPlanningSteps.contains(command), attempt.status != .superseded else { return nil }
            return (name, command, attempt)
        }
    }

    /// Each repository's trust, in lane order, from the reports as last read.
    func specKitTrusts(_ reports: [SpaceID: SpecKitPreflight]) -> [MissionTrust] {
        (draft.plan?.lanes ?? []).map { MissionTrust(lane: specKit?[$0.spaceID], report: reports[$0.spaceID]) }
    }

    /// A repository is read as needing your OK right now. Unread or unready ones don't count: Continue
    /// planning re-reads them (after you fix a setup, for one).
    func specKitAwaitingTrust(_ reports: [SpaceID: SpecKitPreflight]) -> Bool {
        specKitTrusts(reports).contains { switch $0 { case .needs, .changed: true; default: false } }
    }

    /// The footer's line while planning can't start: allow, fix, or read.
    func specKitStartNote(_ reports: [SpaceID: SpecKitPreflight]) -> String? {
        guard specKit != nil, !specKitConsented else { return nil }
        if specKitAwaitingTrust(reports) { return "Allow each repository's project files in the conversation to start planning. Nothing has been sent." }
        if specKitTrusts(reports).contains(where: { if case .unready = $0 { true } else { false } }) {
            return "Set up Spec Kit in the conversation to start planning. Nothing has been sent."
        }
        return "Continue planning reads each repository's project files first. Nothing has been sent."
    }

    /// Whether the map inspector edits this station. A Spec Kit map is redrawn from each repository's
    /// artifacts and keeps only the owner's command checks; the legacy map edits every station.
    func mapStationsEditable(_ station: MissionStation) -> Bool { specKit == nil || station.kind == .check }

    /// What the work came to, for Review and Done. A Spec Kit mission's evidence is each repository's
    /// latest completion report (/speckit.converge); the planner's last reply there is often an
    /// acknowledgement, not a summary. Others keep the planner's own summary.
    var workSummary: (title: String, text: String)? {
        guard let specKit, let run else { return plannerSummary.map { ("Planner's summary", $0) } }
        let reports = specKit.lanes.compactMap { lane -> String? in
            let station = SpecKit.stationID(id, lane.spaceID, SpecKitCommand.converge.rawValue)
            guard let report = run.attempts.last(where: { $0.stationID == station && $0.status == .succeeded })?.output,
                  !report.isEmpty else { return nil }
            return specKit.lanes.count > 1 ? "**\(self.lane(lane.spaceID)?.name ?? "repository")**: \(report)" : report
        }
        return reports.isEmpty ? nil : ("Completion report\(reports.count > 1 ? "s" : "")", reports.joined(separator: "\n\n"))
    }

    /// A finished completion report (/speckit.converge) only the owner can accept.
    var specKitAwaitingAcceptance: (attempt: UUID, lane: String)? {
        guard let specKit, let run else { return nil }
        for lane in specKit.lanes {
            guard let convergence = lane.convergence, !convergence.accepted,
                  convergence.outcome != .tasksAppended, convergence.outcome != .missing,
                  run.attempts.first(where: { $0.id == convergence.attemptID })?.status == .succeeded else { continue }
            return (convergence.attemptID, self.lane(lane.spaceID)?.name ?? "repository")
        }
        return nil
    }
}

/// One repository's trust, read from its files as the planner last read them.
enum MissionTrust: Equatable {
    case allowed, unread, needs(SpecKitPreflight), changed(SpecKitPreflight), unready(SpecKitPreflight)

    init(lane: MissionSpecKitLane?, report: SpecKitPreflight?) {
        guard let report else { self = lane?.consentFingerprint != nil ? .allowed : .unread; return }
        guard report.status == .ready else { self = .unready(report); return }
        if lane?.consentFingerprint == report.consentFingerprint { self = .allowed }
        else if lane?.consentFingerprint != nil { self = .changed(report) }
        else { self = .needs(report) }
    }

    /// The brief's lane column.
    var word: String {
        switch self {
        case .allowed: "project files allowed"
        case .unread: "checked when planning resumes"
        case .needs: "needs your OK"
        case .changed: "files changed · needs your OK"
        case .unready: "can't plan yet"
        }
    }
    var asksYou: Bool {
        switch self { case .needs, .changed, .unready: true; default: false }
    }
}

/// In the conversation where the planner needs it: what this repository's own planning setup is,
/// the grant that binds to it, and Not now, which pauses the mission. Details holds the files.
struct MissionTrustCard: View {
    let name: String
    let space: SpaceID
    let trust: MissionTrust
    /// The other repositories are already allowed, so this grant lets planning continue.
    let last: Bool
    let enabled: Bool
    let action: (MissionUIAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
                Image(systemName: "lock.shield").foregroundStyle(Color.nw.lanternText).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NW.Space.xs) {
                    heading.nwText(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(summary).nwText(.caption).foregroundStyle(Color.nw.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            switch trust {
            case .needs(let report), .changed(let report):
                Text("Loads \(name)'s own Spec Kit prompts with `--prompt-template`, which skips pi's project-trust prompt. Allowing binds to these files as they are now; if any change, I'll ask again.")
                    .nwText(.caption).foregroundStyle(Color.nw.textSecondary).fixedSize(horizontal: false, vertical: true)
                details(report)
                NWFlowLayout(spacing: NW.Space.m) {
                    Button(last ? "Allow \(name)'s project files and continue planning" : "Allow \(name)'s project files") {
                        action(.specKitConsent(space, report.consentFingerprint, continuePlanning: last))
                    }
                    .buttonStyle(.nw(.raised, tint: Color.nw.lanternText)).disabled(!enabled)
                    Button("Not now") { action(.pause) }.buttonStyle(.nw(.ghost)).disabled(!enabled)
                        .nwHelp("Pauses the mission. Planning stays paused until you allow \(name).")
                }
            case .unready(let report):
                Text((try? AttributedString(markdown: MissionController.describe(report))) ?? AttributedString(MissionController.describe(report)))
                    .nwText(.caption).foregroundStyle(Color.nw.textSecondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if report.status == .notInitialized || report.status == .piIntegrationMissing {
                    Button("Set up Spec Kit in \(name)") { action(.specKitSetUp(space)) }
                        .buttonStyle(.nw(.raised, tint: Color.nw.lanternText)).disabled(!enabled)
                        .nwHelp("Runs the stock specify CLI in this mission's worktree. Your repository's own checkout is untouched.")
                }
                details(report)
            case .allowed, .unread: EmptyView()
            }
        }
        .padding(NW.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(Color.nw.lineStrong, radius: NW.Radius.m)
        .accessibilityElement(children: .contain)
    }

    private var heading: Text {
        switch trust {
        case .changed: Text("\(name)'s planning setup changed since you allowed it.")
        case .unready(let report) where report.status == .blocked: Text("\(name)'s Spec Kit setup conflicts with how missions work.")
        case .unready: Text("\(name) isn't set up for Spec Kit planning yet.")
        default: Text("Before I plan in \(name), I need to use its own planning setup.")
        }
    }

    private var summary: String {
        guard case .needs(let report) = trust, report.customizedFiles.isEmpty && report.hooks.isEmpty else {
            if case .needs(let report) = trust { return counts(report) }
            if case .changed(let report) = trust { return counts(report) }
            if case .unready(let report) = trust, report.status == .blocked {
                return "Planning in \(name) waits until the conflict is resolved. Then Continue planning reads its files again."
            }
            return "Planning in \(name) waits until it is. Setting it up uses the stock specify CLI, then I'll ask you to allow the files it wrote."
        }
        return "Its stock Spec Kit templates, prompts and scripts, as they are in the repository."
    }

    private func counts(_ report: SpecKitPreflight) -> String {
        var parts: [String] = []
        if !report.customizedFiles.isEmpty { parts.append("\(report.customizedFiles.count) file\(report.customizedFiles.count == 1 ? "" : "s") customized") }
        if !report.hooks.isEmpty { parts.append("\(report.hooks.count) hook\(report.hooks.count == 1 ? "" : "s")") }
        if !report.warnings.isEmpty { parts.append("\(report.warnings.count) warning\(report.warnings.count == 1 ? "" : "s")") }
        return "Its Spec Kit templates, prompts and scripts, as they are in the repository" + (parts.isEmpty ? "." : " (\(parts.joined(separator: ", "))).")
    }

    private func details(_ report: SpecKitPreflight) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: NW.Space.xs) {
                fact("Version", (report.recordedVersion ?? "not recorded")
                     + (report.matchesTestedRelease ? " · matches the tested release" : " · differs from the tested release \(report.testedVersion)"))
                if !report.integrations.isEmpty { fact("Integrations", report.integrations.joined(separator: ", ") + (report.scriptType.map { " · \($0) scripts" } ?? "")) }
                if !report.missingCommands.isEmpty { fact("Missing", report.missingCommands.map { $0.invocation("") }.joined(separator: ", ")) }
                if !report.customizedFiles.isEmpty { fact("Customized, used as-is", report.customizedFiles.joined(separator: "\n")) }
                if !report.hooks.isEmpty {
                    fact("Hooks", report.hooks.map { "\($0.event) → \($0.command)\($0.optional ? " (optional)" : "")\($0.enabled ? "" : " (off)")" }.joined(separator: "\n"))
                }
                if !report.warnings.isEmpty { fact("Warnings", report.warnings.joined(separator: "\n")) }
            }.padding(.top, NW.Space.s)
        } label: {
            Text("Details").nwText(.caption).foregroundStyle(Color.nw.textSecondary)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
            Text(label).nwText(.caption).foregroundStyle(Color.nw.textTertiary).frame(width: AppLayout.missionBriefLaneName, alignment: .leading)
            Text(value).nwText(.mono).foregroundStyle(Color.nw.textSecondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The planner's own steps, as activity rows like "Explored 3 repositories": each opens its thread.
struct MissionPlannerActivity: View {
    let rows: [(lane: String, command: SpecKitCommand, attempt: MissionAttempt)]
    let openThread: (AgentID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.s) {
            ForEach(rows, id: \.attempt.id) { row in
                let words = row.command.plannerWords
                let running = row.attempt.status == .running
                Button { if let agent = row.attempt.agentID { openThread(agent) } } label: {
                    HStack(spacing: NW.Space.m) {
                        if running { ProgressView().progressViewStyle(.nwSpinner()) }
                        else { NWStateGlyph(row.attempt.status.missionState) }
                        Text("\(running ? words.working : words.done) for \(row.lane)\(running ? "…" : "")").nwText(.ui)
                        if let file = words.file, !running { Text(file).nwText(.mono).foregroundStyle(Color.nw.textTertiary) }
                        if row.attempt.agentID != nil {
                            Image(systemName: "chevron.right").font(.nw(.micro)).foregroundStyle(Color.nw.textTertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(row.attempt.agentID == nil)
                .accessibilityLabel("\(running ? words.working : words.done) for \(row.lane)")
                .accessibilityHint("Opens its thread")
            }
        }
    }
}
