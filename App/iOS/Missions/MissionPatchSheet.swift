import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol

/// MobilePatch: the planner's patch to a mission's map, as a sheet over the mission. What it adds,
/// changes and keeps, what it costs against the limits, and Apply or Reject against the revision shown.
struct MissionPatchSheet: View {
    let mission: Mission
    let patch: MissionPatch
    let busy: Bool
    let perform: (RemoteMissionAction, UInt64) -> Task<Bool, Never>
    @Environment(\.dismiss) private var dismiss

    private var diff: MissionPlanDiff { patch.diff(from: mission.draft) }
    private var lanes: [MissionLane] { mission.draft.plan?.lanes ?? [] }
    /// The repositories the patch touches, by name.
    private var touched: [String] {
        let ids = Set((diff.added + diff.changed + diff.removed).compactMap(\.laneID))
        return lanes.filter { ids.contains($0.spaceID) }.map(\.name)
    }
    private var untouched: [String] {
        let ids = Set((diff.added + diff.changed + diff.removed).compactMap(\.laneID))
        return lanes.filter { !ids.contains($0.spaceID) }.map(\.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                    VStack(alignment: .leading, spacing: SH.Space.xs) {
                        Text(touched.count == 1 ? "Patch for \(touched[0])" : "Patch").shText(.title).foregroundStyle(Color.sh.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text("proposed by the planner · \(Date(timeIntervalSince1970: patch.proposedAt).formatted(date: .omitted, time: .shortened))")
                            .shText(.ui).foregroundStyle(Color.sh.textTertiary)
                    }
                    SHHairline()
                    VStack(alignment: .leading, spacing: SH.Space.l) {
                        ForEach(diff.added) { row("+", Color.sh.done, $0.title, detail($0)) }
                        ForEach(diff.changed) { row("↻", Color.sh.running, $0.title, "changes; what it feeds checks again") }
                        ForEach(diff.removed) { row("−", Color.sh.failed, $0.title, "leaves the map") }
                        if !untouched.isEmpty {
                            row("=", Color.sh.textTertiary, untouched.joined(separator: ", "), "unchanged", muted: true)
                        }
                    }
                    cost
                    if !patch.summary.isEmpty {
                        Text(patch.summary).shText(.ui).foregroundStyle(Color.sh.textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    if !patch.applies(to: mission.draft) {
                        SHBanner(.attention, title: "The map changed after the planner proposed this. Reject it and ask again.") { EmptyView() }
                    }
                }
                .padding(MobileLayout.gutter)
            }
            VStack(spacing: SH.Space.m) {
                Button { act(.applyPatch(patchID: patch.id)) } label: { Text("Apply patch").frame(maxWidth: .infinity) }
                    .buttonStyle(.sh(.primary, size: .l)).disabled(busy || !patch.applies(to: mission.draft))
                Button { act(.rejectPatch(patchID: patch.id)) } label: { Text("Reject").frame(maxWidth: .infinity) }
                    .buttonStyle(.sh(.secondary, size: .l)).disabled(busy)
            }
            .padding(MobileLayout.gutter)
        }
        .background(Color.sh.bgWindow)
    }

    private func detail(_ station: MissionStation) -> String {
        station.kind == .check ? "check" : "\(station.kind == .worker ? "agent" : station.kind.rawValue) · \(station.goal)"
    }

    private func row(_ sign: String, _ color: Color, _ name: String, _ detail: String, muted: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            Text(sign).shText(.mono).foregroundStyle(color)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(name).font(.sh(.mono, weight: .semibold)).foregroundStyle(muted ? Color.sh.textTertiary : Color.sh.textPrimary)
                Text(detail).shText(.caption).foregroundStyle(Color.sh.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var cost: some View {
        let limits = patch.draft.limits
        let before = mission.draft.plan?.estimate, after = patch.draft.plan?.estimate
        return VStack(spacing: SH.Space.m) {
            line("Tokens", before.map { MissionCost.tokens($0.tokens) }, after.map { MissionCost.tokens($0.tokens) }, MissionCost.tokens(limits.tokens))
            line("Time", before.map { MissionCost.duration($0.seconds) }, after.map { MissionCost.duration($0.seconds) }, MissionCost.duration(limits.seconds))
        }
        .padding(SH.Space.l)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: MobileLayout.cardRadius))
        .shBorder(Color.sh.lineSubtle, radius: MobileLayout.cardRadius)
    }

    private func line(_ label: String, _ before: String?, _ after: String?, _ limit: String) -> some View {
        HStack(spacing: SH.Space.s) {
            Text(label).shText(.ui).foregroundStyle(Color.sh.textSecondary)
            Spacer(minLength: SH.Space.m)
            if let before { Text("\(before) →").foregroundStyle(Color.sh.textTertiary) }
            Text(after ?? "no estimate").fontWeight(.semibold).foregroundStyle(after == nil ? Color.sh.textTertiary : Color.sh.textPrimary)
            Text("of \(limit)").foregroundStyle(Color.sh.textTertiary)
        }
        .shText(.mono)
        .accessibilityElement(children: .combine)
    }

    private func act(_ action: RemoteMissionAction) {
        let task = perform(action, mission.revision)
        Task { if await task.value { dismiss() } }
    }
}

/// "3.1M", "2h05": the Mac's formats for a mission's spend.
enum MissionCost {
    static func tokens(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))).replacingOccurrences(of: "K", with: "k")
    }
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 60 { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h" + String(format: "%02d", rest)
    }
}
