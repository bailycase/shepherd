import SwiftUI
import ShepherdCore
import ShepherdUI

// MARK: Patch preview (MXPatch)

/// Which nodes and wires of the previewed map a patch adds, drops or settles. Built once per record.
struct MissionPatchMarks: Equatable {
    enum Mark: Equatable { case added, removed, resolved(String) }
    var added: Set<String> = []
    var removed: Set<String> = []
    var wires: Set<String> = []
    var resolved: String?
    var answer: String?

    func mark(_ id: String) -> Mark? {
        if added.contains(id) { return .added }
        if removed.contains(id) { return .removed }
        if id == resolved, let answer { return .resolved(answer) }
        return nil
    }
    func patched(_ wire: MissionMapLayout.Wire) -> Bool { wires.contains(wire.id) || added.contains(wire.source) || added.contains(wire.target) }
    func dropped(_ wire: MissionMapLayout.Wire) -> Bool { removed.contains(wire.source) || removed.contains(wire.target) }
}

extension MissionPatch {
    /// The patched map with the stations it drops kept in place (drawn as not taken), and its marks.
    func preview(over current: MissionPlan) -> (plan: MissionPlan, marks: MissionPatchMarks) {
        let diff = MissionPlanDiff(from: current, to: draft.plan ?? MissionPlan())
        var plan = draft.plan ?? MissionPlan()
        plan.stations += diff.removed
        let kept = Set(plan.stations.map(\.id))
        plan.dependencies += diff.removedWires.filter { kept.contains($0.source) && kept.contains($0.target) && !plan.dependencies.contains($0) }
        let marks = MissionPatchMarks(
            added: Set(diff.added.map(\.id.rawValue)), removed: Set(diff.removed.map(\.id.rawValue)),
            wires: Set(diff.addedWires.map { MissionMapLayout.Wire(source: $0.source.rawValue, target: $0.target.rawValue, kind: $0.kind, artifact: $0.artifact).id }),
            resolved: resolves?.rawValue, answer: answer)
        return (plan, marks)
    }
}

/// The toolbar's "Previewing patch +2 stations · fog cleared"; selects the patch.
struct MissionPatchBanner: View {
    let patch: MissionPatch
    let diff: MissionPlanDiff
    let select: () -> Void
    var body: some View {
        Button(action: select) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: "eye").font(.sh(.caption))
                Text("Previewing patch").shText(.ui).foregroundStyle(Color.sh.textPrimary)
                Text(([diff.added.isEmpty ? nil : "+\(diff.added.count) station\(diff.added.count == 1 ? "" : "s")",
                       // A fog patch's removals are the fog it clears.
                       diff.removed.isEmpty || patch.clearsFog ? nil : "−\(diff.removed.count)",
                       patch.clearsFog ? "fog cleared" : nil].compactMap { $0 }).joined(separator: " · "))
                    .shText(.micro)
            }
            .foregroundStyle(Color.sh.done)
            .padding(.horizontal, SH.Space.l).frame(height: SH.Height.controlM)
            .background(Color.sh.doneTint, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .shBorder(Color.sh.done, radius: SH.Radius.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Previewing patch")
        .accessibilityHint("Shows the patch in the inspector")
    }
}

/// MXPatch's inspector: the decision it resolves, what changes, why, what it costs and the decisions so far.
struct MissionPatchInspector: View {
    let mission: Mission
    let patch: MissionPatch
    let busy: Bool
    let editable: Bool
    let openThread: (AgentID) -> Void
    let close: () -> Void
    let edit: () -> Void
    let action: (MissionUIAction) -> Void

    private var diff: MissionPlanDiff { patch.diff(from: mission.draft) }
    private var stale: Bool { !patch.applies(to: mission.draft) }

    var body: some View {
        VStack(spacing: 0) {
            MissionInspectorHead(symbol: SHGlyph.mission.symbolName, title: "Patch", tag: patch.clearsFog ? "clears fog" : nil, pill: nil, lane: nil,
                                 subtitle: "proposed by planner · \(mission.run?.model ?? "planner") · \(Self.time(patch.proposedAt))",
                                 mono: false, close: close) {
                if let planner = mission.run?.plannerID {
                    Menu { Button("Open planner thread") { openThread(planner) } } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.button).buttonStyle(.shIcon).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("More patch actions").help("More patch actions")
                }
            }
            ScrollView {
                VStack(spacing: 0) {
                    if let question = patch.question {
                        MissionInspectorSection(title: "Decision it resolves") {
                            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                                if let name = resolvedName { Text(name).shText(.mono).fontWeight(.semibold) }
                                Text(question).shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textSecondary)
                            }
                            if let answer = patch.answer {
                                VStack(alignment: .leading, spacing: SH.Space.s) {
                                    Text("You").shText(.micro).foregroundStyle(Color.sh.textTertiary)
                                    Text(answer).shText(.body).textSelection(.enabled)
                                }
                                .padding(SH.Space.l)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                                .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
                            }
                        }
                    }
                    MissionInspectorSection(title: "What changes") { changes }
                    if !patch.summary.isEmpty {
                        MissionInspectorSection(title: "Why this shape") { MissionProse(patch.summary) }
                    }
                    MissionInspectorSection(title: "Cost") { cost }
                    // Settled decisions, then the one this patch settles.
                    let decisions = (mission.run?.decisions ?? []) + (patch.answer.map { [MissionDecisionRecord(station: resolvedName ?? "decision", answer: $0, at: patch.proposedAt)] } ?? [])
                    if !decisions.isEmpty {
                        MissionInspectorSection(title: "Decisions so far") {
                            ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in
                                HStack(spacing: SH.Space.m) {
                                    Text(Self.time(decision.at)).shText(.micro).foregroundStyle(Color.sh.textTertiary)
                                    Text(decision.station).shText(.mono).fontWeight(.semibold).lineLimit(1)
                                    Image(systemName: "arrow.right").font(.sh(.micro)).foregroundStyle(Color.sh.textTertiary)
                                    Text(decision.answer).shText(.ui).fontWeight(.regular).lineLimit(1)
                                    Spacer(minLength: SH.Space.m)
                                    Text("you").shText(.micro).foregroundStyle(Color.sh.textTertiary)
                                }.accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
            if stale {
                Text("The map changed after the planner proposed this patch. Reject it and ask again.")
                    .shText(.caption).foregroundStyle(Color.sh.lanternText)
                    .padding(.horizontal, SH.Space.xl).padding(.vertical, SH.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: SH.Space.l) {
                Text("Apply fog patches automatically when they fit the budget").shText(.ui).fontWeight(.regular)
                    .foregroundStyle(Color.sh.textSecondary)
                Spacer(minLength: SH.Space.m)
                Toggle("Apply fog patches automatically", isOn: Binding(get: { mission.run?.autoApplyPatches == true },
                                                                       set: { action(.autoApplyPatches($0)) }))
                    .labelsHidden().toggleStyle(.shSwitch).disabled(busy || !editable)
            }
            .padding(.horizontal, SH.Space.xl).padding(.vertical, SH.Space.l)
            SHHairline()
            HStack(spacing: SH.Space.l) {
                Button("Reject") { action(.rejectPatch(patch.id)) }.buttonStyle(.sh(.ghost)).disabled(busy || !editable)
                Spacer()
                Button("Edit on map", action: edit).buttonStyle(.sh(.secondary)).disabled(busy || !editable || stale)
                    .shHelp("Apply the patch, then change its stations on the map")
                Button("Apply patch") { action(.applyPatch(patch.id)) }
                    .buttonStyle(.sh(.primary)).keyboardShortcut(.return, modifiers: .command)
                    .disabled(busy || !editable || stale)
                    .shHelp("Make this the map. Launch approves it.", shortcut: "⌘↩")
            }
            .padding(.horizontal, SH.Space.xl).frame(height: SHPageMetrics.headerHeight)
        }
        .background(Color.sh.bgWindow)
    }

    private var resolvedName: String? {
        patch.resolves.flatMap { id in (patch.draft.plan?.stations ?? []).first { $0.id == id }?.title }
    }

    @ViewBuilder private var changes: some View {
        ForEach(diff.added) { station in row("+", Color.sh.done, station.title, detail(station), trailing: station.kind == .check ? nil : model(station)) }
        ForEach(diff.changed) { station in row("↻", Color.sh.running, station.title, detail(station), trailing: nil) }
        let flow = diff.addedWires.filter { $0.kind == .flow }.count, data = diff.addedWires.filter { $0.kind == .data }.count
        if flow + data > 0 {
            let names = diff.addedWires.compactMap(\.artifact)
            row("+", Color.sh.done, [flow > 0 ? "\(flow) flow" : nil, data > 0 ? "\(data) data" : nil].compactMap { $0 }.joined(separator: " · "),
                names.isEmpty ? "wires" : names.joined(separator: ", "), trailing: nil)
        }
        ForEach(diff.removed) { station in row("−", Color.sh.failed, station.title, station.goal, trailing: nil) }
        if diff.isEmpty {
            Text("The planner kept the map as it is.").shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textTertiary)
        }
    }

    private func detail(_ station: MissionStation) -> String {
        station.kind == .check ? "check" : "\(station.kind == .worker ? "agent" : station.kind.word) · \(station.goal)"
    }
    private func model(_ station: MissionStation) -> String? {
        (station.model ?? mission.run?.model).map { $0.split(separator: "/").last.map(String.init) ?? $0 }
    }

    private func row(_ sign: String, _ color: Color, _ name: String, _ detail: String, trailing: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            Text(sign).shText(.mono).foregroundStyle(color).frame(width: SH.Space.l)
            Text(name).shText(.mono).fontWeight(.semibold).lineLimit(1).fixedSize()
            Text(detail).shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textSecondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: SH.Space.m)
            if let trailing { Text(trailing).shText(.micro).foregroundStyle(Color.sh.textTertiary).lineLimit(1).fixedSize() }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var cost: some View {
        let limits = patch.draft.limits
        let before = mission.draft.plan?.estimate, after = patch.draft.plan?.estimate
        MissionFactRow(label: "Tokens") {
            change(before.map { MissionFormat.tokens($0.tokens) }, after.map { MissionFormat.tokens($0.tokens) }, of: MissionFormat.tokens(limits.tokens),
                   over: (after?.tokens ?? 0) > limits.tokens)
        }
        MissionFactRow(label: "Time") {
            change(before.map { MissionFormat.duration($0.seconds) }, after.map { MissionFormat.duration($0.seconds) }, of: MissionFormat.duration(limits.seconds),
                   over: (after?.seconds ?? 0) > limits.seconds)
        }
    }

    private func change(_ before: String?, _ after: String?, of limit: String, over: Bool) -> some View {
        HStack(spacing: SH.Space.s) {
            if let before { Text(before).foregroundStyle(Color.sh.textTertiary); Image(systemName: "arrow.right").font(.sh(.micro)).foregroundStyle(Color.sh.textTertiary) }
            Text(after ?? "no estimate").fontWeight(.semibold).foregroundStyle(over ? Color.sh.failed : after == nil ? Color.sh.textTertiary : Color.sh.textPrimary)
            Text("of \(limit)").foregroundStyle(Color.sh.textTertiary)
        }
        .shText(.mono)
    }

    static func time(_ seconds: Double) -> String {
        Date(timeIntervalSince1970: seconds).formatted(date: .omitted, time: .shortened)
    }
}
