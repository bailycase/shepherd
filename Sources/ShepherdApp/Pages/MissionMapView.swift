import SwiftUI
import ShepherdCore
import ShepherdUI

// MARK: Layout

/// The map's measures, full (Map, Done) or compact (Run's 40% graph).
struct MissionMapMetrics: Equatable {
    let laneWidth, laneHeader, nodeWidth, nodeHeight, checkHeight, rankHeight: CGFloat
    let compact: Bool
    static let full = MissionMapMetrics(laneWidth: AppLayout.missionLaneWidth, laneHeader: AppLayout.missionLaneHeader,
                                        nodeWidth: AppLayout.missionNodeWidth, nodeHeight: AppLayout.missionNodeHeight,
                                        checkHeight: AppLayout.missionCheckHeight, rankHeight: AppLayout.missionRankHeight, compact: false)
    static let compact = MissionMapMetrics(laneWidth: AppLayout.missionCompactLaneWidth, laneHeader: AppLayout.missionCompactLaneHeader,
                                           nodeWidth: AppLayout.missionCompactNodeWidth, nodeHeight: AppLayout.missionCompactNodeHeight,
                                           checkHeight: AppLayout.missionCompactNodeHeight, rankHeight: AppLayout.missionCompactRankHeight, compact: true)
}

/// A deterministic layered layout of the real map: the mission orchestration lane, one column
/// per repository, ranks from both wire kinds, and the host-owned ends of the route (the goal,
/// your review, each repository's pull request and publication). Computed outside `body`.
struct MissionMapLayout: Equatable {
    struct Lane: Identifiable, Equatable { let id: String; let title: String; let subtitle: String; let column: Int }
    enum Role: Equatable { case goal, station, review, pullRequest, finish }
    struct Node: Identifiable, Equatable {
        let id: String
        let role: Role
        let station: MissionStation?
        let laneID: SpaceID?
        let column: Int
        let rank: Int
    }
    struct Wire: Identifiable, Equatable {
        let source: String
        let target: String
        let kind: MissionDependency.Kind
        let artifact: String?
        var id: String { "\(source)>\(target)>\(kind.rawValue)" }
    }
    let lanes: [Lane]
    let nodes: [Node]
    let wires: [Wire]
    let dependencies: [MissionDependency]
    let plan: MissionPlan
    let ranks: Int

    init(plan: MissionPlan) {
        self.plan = plan
        lanes = [Lane(id: "mission", title: "mission", subtitle: "orchestration", column: 0)] + plan.lanes.enumerated().map {
            Lane(id: $0.element.id.rawValue, title: $0.element.name,
                 subtitle: $0.element.baseBranch.map(MissionBranchSelection.label) ?? "repository", column: $0.offset + 1)
        }
        let order = (try? plan.orderedStations()) ?? plan.stations.map(\.id)
        let stations = Dictionary(uniqueKeysWithValues: plan.stations.map { ($0.id, $0) })
        var ranks: [MissionStationID: Int] = [:], last: [Int: Int] = [0: 0], result: [Node] = []
        result.append(Node(id: "goal", role: .goal, station: nil, laneID: nil, column: 0, rank: 0))
        for id in order {
            guard let station = stations[id] else { continue }
            let column = station.laneID.flatMap { lane in plan.lanes.firstIndex { $0.id == lane }.map { $0 + 1 } } ?? 0
            let previous = plan.dependencies.filter { $0.target == id }.compactMap { ranks[$0.source] }.max() ?? 0
            let rank = max(previous, last[column] ?? 0) + 1
            ranks[id] = rank; last[column] = rank
            result.append(Node(id: id.rawValue, role: .station, station: station, laneID: station.laneID, column: column, rank: rank))
        }
        let deepest = ranks.values.max() ?? 0
        var wires = plan.stations.filter { station in !plan.dependencies.contains { $0.target == station.id } }
            .map { Wire(source: "goal", target: $0.id.rawValue, kind: .flow, artifact: nil) }
        wires += plan.dependencies.map { Wire(source: $0.source.rawValue, target: $0.target.rawValue, kind: $0.kind, artifact: $0.artifact) }
        if !plan.stations.isEmpty {
            result.append(Node(id: "review", role: .review, station: nil, laneID: nil, column: 0, rank: deepest + 1))
            wires += plan.stations.filter { station in !plan.dependencies.contains { $0.source == station.id } }
                .map { Wire(source: $0.id.rawValue, target: "review", kind: .flow, artifact: nil) }
            var previous = "review"
            for (index, lane) in plan.lanes.enumerated() {
                let id = "pr-\(lane.id.rawValue)"
                result.append(Node(id: id, role: .pullRequest, station: nil, laneID: lane.id, column: index + 1, rank: deepest + 2))
                wires.append(Wire(source: previous, target: id, kind: .flow, artifact: nil))
                previous = id
            }
            result.append(Node(id: "finish", role: .finish, station: nil, laneID: nil, column: plan.lanes.count, rank: deepest + 3))
            wires.append(Wire(source: previous, target: "finish", kind: .flow, artifact: nil))
        }
        nodes = result
        self.wires = wires
        dependencies = plan.dependencies
        self.ranks = (result.map(\.rank).max() ?? 0) + 1
    }

    func node(_ station: MissionStationID) -> Node? { nodes.first { $0.id == station.rawValue } }
    func node(id: String) -> Node? { nodes.first { $0.id == id } }

    func size(_ m: MissionMapMetrics) -> CGSize {
        CGSize(width: CGFloat(lanes.count) * m.laneWidth, height: m.laneHeader + CGFloat(ranks) * m.rankHeight)
    }
    func height(_ node: Node, _ m: MissionMapMetrics) -> CGFloat { node.station?.kind == .check ? m.checkHeight : m.nodeHeight }
    func frame(_ node: Node, _ m: MissionMapMetrics) -> CGRect {
        let h = height(node, m)
        let x = CGFloat(node.column) * m.laneWidth + (m.laneWidth - m.nodeWidth) / 2
        let y = m.laneHeader + CGFloat(node.rank) * m.rankHeight + (m.rankHeight - h) / 2
        return CGRect(x: x, y: y, width: m.nodeWidth, height: h)
    }

    /// Where a wire turns: just above a target that joins several wires, else just below its source.
    func elbow(_ wire: Wire, _ m: MissionMapMetrics) -> CGFloat? {
        guard let s = node(id: wire.source), let t = node(id: wire.target), s.rank != t.rank else { return nil }
        let source = frame(s, m), target = frame(t, m)
        if incoming(t.id).count > 1 { return target.minY - (m.rankHeight - m.nodeHeight) / 2 }
        return source.maxY + (m.rankHeight - m.nodeHeight) / 2
    }
    func incoming(_ id: String) -> [Wire] { wires.filter { $0.target == id && node(id: $0.source)?.rank != node(id: id)?.rank } }
    func outgoing(_ id: String) -> [Wire] { wires.filter { $0.source == id && node(id: $0.target)?.rank != node(id: id)?.rank } }
}

enum MissionWireFilter: String, CaseIterable { case flow = "Flow", data = "Data", both = "Both" }

/// Each node's state from receipts, never from prose.
struct MissionNodeState {
    let mission: Mission
    func state(_ node: MissionMapLayout.Node) -> AgentState? {
        let phase = mission.phase
        switch node.role {
        case .goal: return mission.stationAttempts.isEmpty ? nil : .done
        case .station:
            guard let station = node.station else { return nil }
            guard let attempt = mission.latest(station.id), attempt.status != .superseded else {
                return station.kind == .decision ? .attention : nil
            }
            return attempt.status.missionState
        case .review:
            if mission.run?.publicationApproval != nil || phase == .done { return .done }
            return phase == .review ? .attention : nil
        case .pullRequest:
            if mission.run?.checkouts.first(where: { $0.spaceID == node.laneID })?.prURL != nil { return .done }
            return phase == .publishing ? .running : nil
        case .finish: return phase == .done ? .done : nil
        }
    }
    var started: Bool { !mission.stationAttempts.isEmpty }
}

// MARK: Graph

struct MissionGraph: View {
    let mission: Mission
    let layout: MissionMapLayout
    let metrics: MissionMapMetrics
    let filter: MissionWireFilter
    let selection: String?
    let select: (String) -> Void

    private var states: MissionNodeState { MissionNodeState(mission: mission) }

    var body: some View {
        let size = layout.size(metrics)
        ZStack(alignment: .topLeading) {
            MissionWires(layout: layout, metrics: metrics, filter: filter, mission: mission)
            ForEach(layout.lanes) { lane in
                VStack(spacing: NW.Space.xxs) {
                    HStack(spacing: NW.Space.xs) {
                        (lane.column == 0 ? NWGlyph.mission.image : NWGlyph.repository.image).font(.nw(.micro)).foregroundStyle(Color.nw.textTertiary)
                        Text(lane.title).nwText(metrics.compact ? .micro : .mono).foregroundStyle(Color.nw.textSecondary).lineLimit(1)
                    }
                    if !metrics.compact {
                        Text(lane.subtitle).nwText(.micro).foregroundStyle(Color.nw.textTertiary).lineLimit(1)
                    }
                }
                .frame(width: metrics.laneWidth, height: metrics.laneHeader)
                .offset(x: CGFloat(lane.column) * metrics.laneWidth)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            MissionWireLabels(layout: layout, metrics: metrics, filter: filter, retries: mission.draft.limits.retries, done: mission.phase == .done)
            ForEach(layout.nodes) { node in
                let frame = layout.frame(node, metrics)
                MissionNodeView(node: node, mission: mission, state: states.state(node), started: states.started, metrics: metrics,
                                selected: selection == node.id, selectable: node.role == .station || node.role == .finish) { select(node.id) }
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// Lane separators, wires, fork and join bars and fail loops, drawn once in a canvas.
private struct MissionWires: View {
    let layout: MissionMapLayout
    let metrics: MissionMapMetrics
    let filter: MissionWireFilter
    let mission: Mission

    var body: some View {
        Canvas { context, size in
            let nw = Color.nw
            let line = StrokeStyle(lineWidth: AppLayout.missionWireWidth, lineCap: .round, lineJoin: .round)
            for lane in layout.lanes.dropFirst() {
                var separator = Path()
                let x = CGFloat(lane.column) * metrics.laneWidth
                separator.move(to: CGPoint(x: x, y: metrics.laneHeader / 2))
                separator.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(separator, with: .color(nw.lineSubtle), style: StrokeStyle(lineWidth: 1, dash: AppLayout.missionDataDash))
            }
            let states = MissionNodeState(mission: mission)
            // A data wire also orders its ends, so Flow draws it as a plain flow line (MXMap's default).
            for wire in layout.wires where filter != .data || wire.kind == .data {
                guard let s = layout.node(id: wire.source), let t = layout.node(id: wire.target) else { continue }
                let a = layout.frame(s, metrics), b = layout.frame(t, metrics)
                var path = Path()
                if let y = layout.elbow(wire, metrics) {
                    path.move(to: CGPoint(x: a.midX, y: a.maxY))
                    path.addLine(to: CGPoint(x: a.midX, y: y))
                    path.addLine(to: CGPoint(x: b.midX, y: y))
                    path.addLine(to: CGPoint(x: b.midX, y: b.minY))
                } else {
                    path.move(to: CGPoint(x: a.maxX, y: a.midY))
                    path.addLine(to: CGPoint(x: b.minX, y: b.midY))
                }
                let live = states.state(t) == .running && states.state(s) == .done
                let data = wire.kind == .data && filter != .flow
                let color = data ? nw.synKeyword : live ? nw.running : nw.lineStrong
                var style = line
                if data { style.dash = AppLayout.missionDataDash }
                context.stroke(path, with: .color(color), style: style)
            }
            guard filter != .data else { return }
            // A source fanning out to several columns forks; a target several wires reach joins them all.
            for node in layout.nodes {
                for (wires, end) in [(layout.outgoing(node.id), \MissionMapLayout.Wire.target), (layout.incoming(node.id), \MissionMapLayout.Wire.source)] where wires.count > 1 {
                    guard let y = layout.elbow(wires[0], metrics) else { continue }
                    let xs = wires.compactMap { layout.node(id: $0[keyPath: end]) }.map { layout.frame($0, metrics).midX } + [layout.frame(node, metrics).midX]
                    guard let low = xs.min(), let high = xs.max(), high - low > 1 else { continue }
                    var bar = Path()
                    bar.move(to: CGPoint(x: low, y: y)); bar.addLine(to: CGPoint(x: high, y: y))
                    // MXMap draws the bars a step brighter than the wires they gather.
                    context.stroke(bar, with: .color(nw.textTertiary), style: StrokeStyle(lineWidth: AppLayout.missionBarWidth, lineCap: .round))
                }
            }
            // A failed check or validator sends its upstream workers back, within the retry limit.
            for (check, worker) in MissionWireLabels.loops(layout) {
                let c = layout.frame(check, metrics), w = layout.frame(worker, metrics)
                let x = min(c.minX, w.minX) - AppLayout.missionLoopInset
                var loop = Path()
                loop.move(to: CGPoint(x: c.minX, y: c.midY))
                loop.addLine(to: CGPoint(x: x, y: c.midY))
                loop.addLine(to: CGPoint(x: x, y: w.midY))
                loop.addLine(to: CGPoint(x: w.minX, y: w.midY))
                context.stroke(loop, with: .color(nw.lineStrong), style: line)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The wires' words: data outputs, "pass" under a check, "fail · retry ≤N" by its loop, and the
/// fork and join bars. Each appears only where the controller enforces it.
private struct MissionWireLabels: View {
    let layout: MissionMapLayout
    let metrics: MissionMapMetrics
    let filter: MissionWireFilter
    let retries: Int
    let done: Bool

    /// Same-lane workers a check or validator retries when it fails (those whose output reaches it).
    static func loops(_ layout: MissionMapLayout) -> [(MissionMapLayout.Node, MissionMapLayout.Node)] {
        let plan = layout.plan
        return layout.nodes.filter { $0.station?.kind == .check || $0.station?.kind == .validator }.flatMap { gate in
            layout.nodes.filter { node in
                node.station?.kind == .worker && node.column == gate.column && node.rank < gate.rank
                    && ((try? plan.dataConsumers(of: [node.station!.id]))?.contains(gate.station!.id) == true)
            }.map { (gate, $0) }
        }
    }

    var body: some View {
        if !metrics.compact {
            ZStack(alignment: .topLeading) {
                if filter != .flow {
                    ForEach(layout.wires.filter { $0.kind == .data }) { wire in
                        if let s = layout.node(id: wire.source), let t = layout.node(id: wire.target), let y = layout.elbow(wire, metrics) {
                            // A join's labels sit over each source, a fork's over each target, so none overlap.
                            let x = layout.incoming(t.id).count > 1 ? layout.frame(s, metrics).midX : layout.frame(t, metrics).midX
                            // Outputs sit right of their wire, gates' words left of it, so neither covers the other.
                            anchored(chip(wire.artifact ?? "output", color: Color.nw.synKeyword, glyph: "circle"), x: x + NW.Space.s, y: y, leading: true)
                        }
                    }
                }
                if filter != .data {
                    ForEach(layout.nodes.filter { [.check, .validator].contains($0.station?.kind) }) { gate in
                        let frame = layout.frame(gate, metrics)
                        if !layout.outgoing(gate.id).isEmpty {
                            anchored(chip(gate.station?.kind == .validator ? "all pass" : "pass", color: Color.nw.done),
                                     x: frame.midX - NW.Space.s, y: frame.maxY + (metrics.rankHeight - metrics.nodeHeight) / 4, leading: false)
                        }
                        if retries > 0, !Self.loops(layout).filter({ $0.0.id == gate.id }).isEmpty || gate.station?.kind == .validator {
                            anchored(chip(gate.station?.kind == .validator ? "fail → workers ≤\(retries)" : "fail · retry ≤\(retries)", color: Color.nw.failed),
                                     x: frame.minX, y: frame.minY - NW.Space.m, leading: true)
                        }
                    }
                    ForEach(layout.nodes) { node in
                        if layout.outgoing(node.id).count > 1, let y = layout.elbow(layout.outgoing(node.id)[0], metrics), spans(node, layout.outgoing(node.id).map(\.target)) {
                            anchored(Text("fork").nwText(.micro).foregroundStyle(Color.nw.textTertiary),
                                     x: maxX(node, layout.outgoing(node.id).map(\.target)) + NW.Space.m, y: y, leading: true)
                        }
                        if layout.incoming(node.id).count > 1, let y = layout.elbow(layout.incoming(node.id)[0], metrics), spans(node, layout.incoming(node.id).map(\.source)) {
                            anchored(Text("join · all").nwText(.micro).foregroundStyle(Color.nw.textTertiary),
                                     x: maxX(node, layout.incoming(node.id).map(\.source)) + NW.Space.m, y: y, leading: true)
                        }
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// A label whose leading (or trailing) edge sits at `x`, centered on `y`.
    private func anchored<V: View>(_ view: V, x: CGFloat, y: CGFloat, leading: Bool) -> some View {
        Color.clear.frame(width: 1, height: 1)
            .overlay(alignment: leading ? .leading : .trailing) { view.fixedSize() }
            .position(x: x, y: y)
    }

    private func spans(_ node: MissionMapLayout.Node, _ ids: [String]) -> Bool {
        Set(ids.compactMap { layout.node(id: $0)?.column } + [node.column]).count > 1
    }
    private func maxX(_ node: MissionMapLayout.Node, _ ids: [String]) -> CGFloat {
        (ids.compactMap { layout.node(id: $0) } + [node]).map { layout.frame($0, metrics).midX }.max() ?? 0
    }

    private func chip(_ text: String, color: Color, glyph: String? = nil) -> some View {
        HStack(spacing: NW.Space.xs) {
            if let glyph { Image(systemName: glyph).font(.nw(.micro)) }
            Text(text).nwText(.micro).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, NW.Space.s)
        .frame(height: AppLayout.missionChipHeight - NW.Space.xxs)
        .background(Color.nw.bgWindow, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
        .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.xs)
        .fixedSize()
    }
}

private struct MissionNodeView: View {
    let node: MissionMapLayout.Node
    let mission: Mission
    let state: AgentState?
    let started: Bool
    let metrics: MissionMapMetrics
    let selected: Bool
    let selectable: Bool
    let select: () -> Void

    private var lane: MissionLane? { mission.lane(node.laneID) }
    private var checkout: MissionCheckout? { mission.run?.checkouts.first { $0.spaceID == node.laneID } }

    private var symbol: String {
        switch node.role {
        case .goal: "scope"
        case .station: node.station?.kind.symbol ?? "circle"
        case .review: "person"
        case .pullRequest: "arrow.triangle.pull"
        case .finish: "flag"
        }
    }
    private var title: String {
        switch node.role {
        case .goal: "goal"
        case .station: node.station?.title ?? ""
        case .review: "review"
        // Compact (Run) shows MXRun's bare "#412"; the lane column already names the repository.
        case .pullRequest: MissionFormat.pullNumber(checkout?.prURL).map { metrics.compact ? $0 : "PR \($0)" } ?? (metrics.compact ? "PR" : "pull request")
        case .finish: "published"
        }
    }
    private var subtitle: String {
        let prs = mission.draft.plan?.lanes.count ?? 0
        switch node.role {
        case .goal: return "\(prs) repo\(prs == 1 ? "" : "s")"
        case .station:
            guard let station = node.station else { return "" }
            switch station.kind {
            case .worker: return "worker · \(station.model ?? mission.run?.model ?? "default")"
            case .validator: return "validator · \(mission.draft.requirements.count) checks"
            case .decision: return "you · \(station.goal)"
            case .research: return "research · \(station.goal)"
            case .check: return station.command ?? station.title
            }
        case .review: return "you · approve \(prs) PR\(prs == 1 ? "" : "s")"
        case .pullRequest: return lane?.name ?? ""
        case .finish: return "\(prs) pull request\(prs == 1 ? "" : "s")"
        }
    }
    private var dashed: Color? {
        if node.station?.kind == .decision && state == .attention { return Color.nw.lantern }
        if node.station?.kind == .research && state == .running { return Color.nw.running }
        return nil
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NW.Radius.m)
        let content = HStack(spacing: metrics.compact ? NW.Space.xs : NW.Space.m) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
                .font(metrics.compact ? .nw(.micro) : .nw(.caption))
                .foregroundStyle(node.station?.kind == .decision || node.role == .review ? Color.nw.lanternText : Color.nw.textSecondary)
                .frame(width: metrics.compact ? NW.Space.l : AppLayout.missionNodeIcon, height: metrics.compact ? NW.Space.l : AppLayout.missionNodeIcon)
                .background(metrics.compact ? .clear : Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.s))
                .nwBorder(metrics.compact || node.station?.kind == .check ? .clear : Color.nw.lineSubtle, radius: NW.Radius.s)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.nw(metrics.compact ? .micro : .mono, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                if !metrics.compact && node.station?.kind != .check {
                    Text(subtitle).nwText(.caption).foregroundStyle(Color.nw.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            marker
        }
        .padding(.horizontal, metrics.compact ? NW.Space.s : NW.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.nw.bgRaised, in: shape)
        .overlay {
            if let dashed {
                shape.strokeBorder(dashed, style: StrokeStyle(lineWidth: AppLayout.missionWireWidth, dash: AppLayout.missionDataDash))
            } else {
                shape.strokeBorder(selected ? Color.nw.textPrimary : state == .running ? Color.nw.running : Color.nw.lineStrong,
                                   lineWidth: selected || state == .running ? AppLayout.missionSelectedBorder : 1)
            }
        }
        .contentShape(shape)
        let label = "\(title), \(subtitle), \(state?.label ?? (started ? "waiting" : "not started"))"
        Group {
            if selectable {
                Button(action: select) { content.accessibilityHidden(true) }.buttonStyle(.plain)
                    .accessibilityLabel(label)
                    .accessibilityHint("Inspect this station")
                    .accessibilityAddTraits(selected ? .isSelected : [])
            } else {
                content.accessibilityElement(children: .ignore).accessibilityLabel(label)
            }
        }
        .help("\(title) · \(subtitle)")
    }

    @ViewBuilder private var marker: some View {
        switch state {
        case .running?: ProgressView().progressViewStyle(.nwSpinner(size: metrics.compact ? 10 : 12))
        case .done?: Image(systemName: "checkmark").font(.nw(.caption, weight: .semibold)).foregroundStyle(Color.nw.done)
        case .failed?: Image(systemName: "xmark").font(.nw(.caption, weight: .semibold)).foregroundStyle(Color.nw.failed)
        case .attention?: NWStatusDot(.attention)
        default:
            if started { Image(systemName: "circle").font(.nw(.micro)).foregroundStyle(Color.nw.textTertiary) }
        }
    }
}

// MARK: Map and Done (MXMap, MXDone)

struct MissionMapPage: View {
    let mission: Mission
    let done: Bool
    let models: [String]
    let reviews: [MissionRepositoryReview]
    let busy: Bool
    let editable: Bool
    let openThread: (AgentID) -> Void
    let action: (MissionUIAction) -> Void
    private let layout: MissionMapLayout
    @State private var selection: String?
    @State private var dismissed = false
    /// Narrow windows only: the selected station's inspector in place of the map.
    @State private var inspecting = false
    @Environment(\.missionInitialPanes) private var seed
    @State private var wires = MissionWireFilter.flow
    @State private var zoom: CGFloat = 1
    /// Until you zoom or fit, the map follows the window: every lane in view, never above 100%.
    @State private var zoomed = false
    @State private var metrics = MissionMapMetrics.full
    @State private var viewport: CGSize = .zero
    @State private var feedback = ""
    @State private var editing: MissionStation?
    @State private var editRevision: UInt64 = 0
    @State private var undo: (draft: MissionDraft, label: String)?
    @FocusState private var asking: Bool

    init(mission: Mission, done: Bool, models: [String], reviews: [MissionRepositoryReview], busy: Bool, editable: Bool,
         openThread: @escaping (AgentID) -> Void, action: @escaping (MissionUIAction) -> Void) {
        self.mission = mission; self.done = done; self.models = models; self.reviews = reviews
        self.busy = busy; self.editable = editable; self.openThread = openThread; self.action = action
        layout = MissionMapLayout(plan: mission.draft.plan ?? MissionPlan())
    }

    /// Done opens on the publication; the map on the first worker.
    private var shown: String? {
        if dismissed { return nil }
        if let selection, layout.node(id: selection) != nil { return selection }
        if done { return "finish" }
        return (layout.nodes.first { $0.station?.kind == .worker } ?? layout.nodes.first { $0.role == .station })?.id
    }

    var body: some View {
        GeometryReader { page in
            if page.size.width < AppLayout.missionNarrowWidth, let id = shown {
                // A narrow window shows the map or the selected station, as Review shows diff or contract.
                VStack(spacing: 0) {
                    NWSegmentedPicker("Show", selection: $inspecting, options: [(false, "Map"), (true, id == "finish" ? "Summary" : "Station")])
                        .fixedSize().padding(NW.Space.m)
                    NWHairline()
                    if inspecting { inspector(id) } else { canvas }
                }
            } else {
                HStack(spacing: 0) {
                    canvas
                    if let id = shown {
                        Rectangle().fill(Color.nw.lineSubtle).frame(width: 1)
                        inspector(id).frame(width: AppLayout.missionSide(AppLayout.missionInspectorWidth, in: page.size.width))
                    }
                }
            }
        }
        .sheet(item: $editing) { station in
            MissionStationEditor(station: station, revision: editRevision, currentRevision: mission.revision, busy: busy, cancel: { editing = nil }) { updated in
                var plan = mission.draft.plan ?? MissionPlan()
                if let index = plan.stations.firstIndex(where: { $0.id == updated.id }) { plan.stations[index] = updated }
                apply(plan, nil); editing = nil
            }
        }
        .onChange(of: mission.revision) { _, _ in if !editable { undo = nil } }
        .onAppear {
            if seed.side { inspecting = true }
            if let seeded = seed.wires { wires = seeded }
        }
    }

    @ViewBuilder private func inspector(_ id: String) -> some View {
        if let node = layout.node(id: id) {
            if node.role == .finish {
                MissionDoneInspector(mission: mission, reviews: reviews, busy: busy, close: { dismissed = true; inspecting = false }, action: action)
            } else if let station = node.station {
                MissionStationInspector(mission: mission, station: station, layout: layout, models: models, busy: busy, editable: editable,
                                        openThread: openThread, close: { dismissed = true; inspecting = false },
                                        edit: { editRevision = mission.revision; editing = station }, apply: apply)
            }
        }
    }

    private var canvas: some View {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    toolbar
                    GeometryReader { geometry in
                        ScrollView([.horizontal, .vertical]) {
                            let size = layout.size(metrics)
                            MissionGraph(mission: mission, layout: layout, metrics: metrics, filter: wires, selection: shown) {
                                selection = $0; dismissed = false; inspecting = true
                            }
                            .scaleEffect(zoom, anchor: .topLeading)
                            .frame(width: size.width * zoom, height: size.height * zoom, alignment: .topLeading)
                            .padding(.horizontal, NW.Space.xl)
                            .padding(.trailing, Self.labelRoom)
                            .padding(.bottom, NW.Space.xxxl * 3)
                        }
                        .onAppear { follow(geometry.size) }
                        .onChange(of: geometry.size) { _, size in follow(size) }
                    }
                }
                HStack(alignment: .bottom) {
                    legend
                    Spacer()
                }.padding(NW.Space.xl).allowsHitTesting(false)
                if editable && !done {
                    plannerInput.padding(.horizontal, NW.Space.xl).padding(.bottom, NW.Space.xl)
                }
                if let undo {
                    HStack(spacing: NW.Space.l) {
                        Text(undo.label).nwText(.ui)
                        Button("Undo") {
                            action(.save(undo.draft, mission.revision)); self.undo = nil
                        }.buttonStyle(.nw(.secondary, size: .s)).disabled(busy || !editable)
                        Button { self.undo = nil } label: { Image(systemName: "xmark") }.buttonStyle(.nwIcon).accessibilityLabel("Dismiss")
                    }
                    .padding(.horizontal, NW.Space.l).padding(.vertical, NW.Space.m)
                    .nwPopover(radius: NW.Radius.m)
                    .padding(.bottom, AppLayout.missionReplyHeight)
                }
            }
            .frame(maxWidth: .infinity)
    }

    /// Room right of the last lane for the wire words that hang past it (an artifact, "join · all").
    private static let labelRoom = NW.Space.xxxl
    /// The graph's width with its margins and that room, unzoomed.
    private func framedWidth(_ m: MissionMapMetrics) -> CGFloat { layout.size(m).width + NW.Space.xl * 2 + Self.labelRoom }

    /// Every lane in view without shrinking text past legibility: the full map scaled down while it
    /// stays readable, else Run's compact route (MXRun) at its own size, scrolling if it must.
    private func follow(_ size: CGSize) {
        viewport = size
        guard !zoomed else { return }
        let full = size.width / framedWidth(.full)
        metrics = full >= AppLayout.missionReadableZoom ? .full : .compact
        zoom = min(1, max(AppLayout.missionReadableZoom, size.width / framedWidth(metrics)))
    }

    private func apply(_ plan: MissionPlan, _ label: String?) {
        var draft = mission.draft
        if let label { undo = (draft, label) }
        draft.plan = plan
        action(.save(draft, mission.revision))
    }

    private var toolbar: some View {
        HStack(spacing: NW.Space.l) {
            NWSegmentedPicker("Wires", selection: $wires, options: MissionWireFilter.allCases.map { ($0, $0.rawValue) })
                .fixedSize()
            Rectangle().fill(Color.nw.lineSubtle).frame(width: 1, height: NW.Height.controlS)
            HStack(spacing: NW.Space.xs) {
                Button { zoomed = true; zoom = max(AppLayout.missionZoomRange.lowerBound, zoom - AppLayout.missionZoomStep) } label: { Image(systemName: "minus") }
                    .buttonStyle(.nwIcon).accessibilityLabel("Zoom out").keyboardShortcut("-", modifiers: .command)
                Text("\(Int((zoom * 100).rounded()))%").nwText(.micro).foregroundStyle(Color.nw.textSecondary).monospacedDigit()
                    .frame(minWidth: NW.Space.xxxl)
                Button { zoomed = true; zoom = min(AppLayout.missionZoomRange.upperBound, zoom + AppLayout.missionZoomStep) } label: { Image(systemName: "plus") }
                    .buttonStyle(.nwIcon).accessibilityLabel("Zoom in").keyboardShortcut("=", modifiers: .command)
            }
            .padding(.horizontal, NW.Space.xs)
            .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.s)
            Button {
                let size = layout.size(metrics)
                zoomed = true
                zoom = min(1, max(AppLayout.missionZoomRange.lowerBound,  min(viewport.width / framedWidth(metrics), viewport.height / (size.height + NW.Space.xxxl))))
            } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.nwIcon(bordered: true)).nwHelp("Fit the map").accessibilityLabel("Fit the map")
            Spacer(minLength: NW.Space.m)
            // The counts never wrap: without room they step aside (the inspector repeats them).
            ViewThatFits(in: .horizontal) { frontier.fixedSize(); EmptyView() }
        }
        .padding(.horizontal, NW.Space.xl).padding(.vertical, NW.Space.m)
    }

    /// Counts from receipts: what is moving, waiting on you and how the route went.
    private var frontier: some View {
        let stations = mission.draft.plan?.stations ?? []
        let running = mission.stationAttempts.filter { $0.status == .running }.count
        let decisions = stations.filter { $0.kind == .decision }.count
        let retries = mission.stationAttempts.count - Set(mission.stationAttempts.compactMap(\.stationID)).count
        let items: [(AgentState?, String)] = done
            ? [(nil, "\(stations.count) stations"), (nil, "\(retries) retr\(retries == 1 ? "y" : "ies")"), (nil, "\(decisions) decision\(decisions == 1 ? "" : "s")"),
               (nil, "\(mission.run?.checkouts.filter { $0.prURL != nil }.count ?? 0) PRs")]
            : [(running > 0 ? .running : nil, running > 0 ? "\(running) running" : "\(stations.count) stations"),
               (mission.run?.pendingQuestion != nil || decisions > 0 ? .attention : nil, "\((mission.run?.pendingQuestion == nil ? 0 : 1) + decisions) needs you"),
               (nil, "\(stations.filter { $0.kind == .check || $0.kind == .validator }.count) checks")]
        return HStack(spacing: NW.Space.l) {
            let items = items.filter { !$0.1.hasPrefix("0 ") }
            if !done { Text("frontier").nwText(.micro).textCase(.uppercase).foregroundStyle(Color.nw.textTertiary) }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: NW.Space.xs) {
                    if let state = item.0 { NWStatusDot(state) }
                    Text(item.1).nwText(.micro).foregroundStyle(Color.nw.textSecondary)
                }
            }
        }
        .padding(.horizontal, NW.Space.l).frame(height: NW.Height.controlM)
        .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.s)
        .accessibilityElement(children: .combine)
    }

    private var legend: some View {
        HStack(spacing: NW.Space.xl) {
            HStack(spacing: NW.Space.s) {
                Capsule().fill(Color.nw.lineStrong).frame(width: AppLayout.missionLegendSwatch, height: AppLayout.missionWireWidth)
                Text("flow").nwText(.micro)
            }
            HStack(spacing: NW.Space.s) {
                Path { path in path.move(to: .zero); path.addLine(to: CGPoint(x: AppLayout.missionLegendSwatch, y: 0)) }
                    .stroke(Color.nw.synKeyword, style: StrokeStyle(lineWidth: AppLayout.missionWireWidth, dash: AppLayout.missionDataDash))
                    .frame(width: AppLayout.missionLegendSwatch, height: AppLayout.missionWireWidth)
                Text("data").nwText(.micro)
            }
        }
        .foregroundStyle(Color.nw.textTertiary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Solid lines are flow, dashed lines are data")
    }

    private var plannerInput: some View {
        HStack(spacing: NW.Space.m) {
            NWGlyph.mission.image.foregroundStyle(Color.nw.textTertiary)
            TextField("Ask the planner to change the map…", text: $feedback)
                .textFieldStyle(.plain).nwText(.body).focused($asking)
                .onSubmit(send)
                .accessibilityLabel("Ask the planner to change the map")
            Button(action: send) { Image(systemName: "arrow.up") }
                .buttonStyle(.nwIcon(tint: feedback.isEmpty ? nil : Color.nw.lanternText))
                .disabled(busy || feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send to the planner")
        }
        .padding(.horizontal, NW.Space.l)
        .frame(maxWidth: AppLayout.missionFloatingInputWidth).frame(height: NW.Height.controlL + NW.Space.m)
        .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(Color.nw.lineStrong, radius: NW.Radius.m)
        .nwFocusRing(asking, radius: NW.Radius.m)
    }

    private func send() {
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        action(.plan(text)); feedback = ""
    }
}

// MARK: Inspectors

/// The inspector's header: the station's glyph, name, kind and lane, More and Close.
struct MissionInspectorHead<Menu: View>: View {
    let symbol: String
    let title: String
    let tag: String?
    let pill: (AgentState, String)?
    let lane: String?
    var subtitle: String? = nil
    /// Stations are named in mono; Done's summary title is prose (MXDone).
    var mono = true
    let close: () -> Void
    @ViewBuilder let menu: () -> Menu

    var body: some View {
        HStack(alignment: .top, spacing: NW.Space.l) {
            Image(systemName: symbol).font(.nw(.headline)).foregroundStyle(Color.nw.textSecondary)
                .frame(width: NW.Height.controlL, height: NW.Height.controlL)
                .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.s))
                .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.s)
            VStack(alignment: .leading, spacing: NW.Space.xs) {
                HStack(spacing: NW.Space.m) {
                    Text(title).font(mono ? .nwMono(NWTextStyle.title.size, .semibold) : .nw(.title)).lineLimit(1).accessibilityAddTraits(.isHeader)
                    if let tag { NWTag(tag, mono: true) }
                    if let pill { NWStatusPill(pill.0, label: pill.1) }
                }
                if let subtitle {
                    Text(subtitle).nwText(.caption).foregroundStyle(Color.nw.textTertiary)
                } else {
                    HStack(spacing: NW.Space.s) {
                        Text("lane").nwText(.caption).foregroundStyle(Color.nw.textTertiary)
                        if let lane { MissionLaneChip(name: lane) } else { Text("mission orchestration").nwText(.caption).foregroundStyle(Color.nw.textSecondary) }
                    }
                }
            }
            Spacer(minLength: 0)
            menu()
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.nwIcon)
                .keyboardShortcut(.cancelAction).accessibilityLabel("Close inspector")
        }
        .padding(NW.Space.xl)
        .overlay(alignment: .bottom) { NWHairline() }
    }
}

struct MissionInspectorSection<Content: View>: View {
    let title: String
    var meta: String?
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                NWPageSectionLabel(title)
                Spacer()
                if let meta { Text(meta).nwText(.micro).foregroundStyle(Color.nw.textTertiary) }
            }
            content()
        }
        .padding(NW.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { NWHairline() }
    }
}

struct MissionFactRow<Value: View>: View {
    let label: String
    @ViewBuilder let value: () -> Value
    var body: some View {
        HStack {
            Text(label).nwText(.ui).fontWeight(.regular).foregroundStyle(Color.nw.textSecondary)
            Spacer(minLength: NW.Space.m)
            value()
        }.frame(minHeight: NW.Height.controlM)
    }
}

/// A wire into or out of a station: its output name and the other end.
struct MissionWireRow: View {
    let artifact: String
    let other: String
    let incoming: Bool
    let state: AgentState?
    var body: some View {
        HStack(spacing: NW.Space.m) {
            Image(systemName: state == .done ? "circle.fill" : "circle").font(.nw(.micro)).foregroundStyle(Color.nw.synKeyword)
            Text(artifact).nwText(.mono).fontWeight(.semibold).lineLimit(1)
            Spacer(minLength: NW.Space.m)
            Text("\(incoming ? "←" : "→") \(other)").nwText(.micro).foregroundStyle(Color.nw.textTertiary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MissionStationInspector: View {
    let mission: Mission
    let station: MissionStation
    let layout: MissionMapLayout
    let models: [String]
    let busy: Bool
    let editable: Bool
    let openThread: (AgentID) -> Void
    let close: () -> Void
    let edit: () -> Void
    let apply: (MissionPlan, String?) -> Void

    private var plan: MissionPlan { mission.draft.plan ?? MissionPlan() }
    private var lane: MissionLane? { mission.lane(station.laneID) }
    private var attempt: MissionAttempt? { mission.latest(station.id) }
    private func title(_ id: MissionStationID) -> String { plan.stations.first { $0.id == id }?.title ?? "station" }
    /// A Spec Kit map is drawn from each repository's artifacts and redrawn from them: only the
    /// owner's own command checks survive, so only those are edited here.
    private var mutable: Bool { mission.mapStationsEditable(station) }

    var body: some View {
        VStack(spacing: 0) {
            MissionInspectorHead(symbol: station.kind.symbol, title: station.title,
                                 tag: station.kind == .check ? "command" : station.kind == .decision ? "you" : "agent",
                                 pill: attempt.map { ($0.status.missionState, $0.status.rawValue.capitalized) }, lane: lane?.name, close: close) {
                // No menu when it would be empty (a Spec Kit station that hasn't run).
                if mutable || attempt?.agentID != nil {
                    Menu {
                        if mutable { Button("Edit station…", action: edit).disabled(!editable) }
                        if let agent = attempt?.agentID { Button("Open thread") { openThread(agent) } }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.button).buttonStyle(.nwIcon).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("More station actions").help("More station actions")
                }
            }
            ScrollView {
                VStack(spacing: 0) {
                    MissionInspectorSection(title: "Goal") {
                        Text(station.goal).nwText(.body).lineSpacing(NW.Space.xs).textSelection(.enabled)
                    }
                    MissionInspectorSection(title: "Runs as") {
                        MissionFactRow(label: "Session") {
                            Text(station.kind == .check ? "host command" : station.kind == .decision ? "your answer" : "own agent session").nwText(.mono)
                        }
                        if station.kind == .check {
                            MissionFactRow(label: "Command") { Text(station.command ?? "").nwText(.mono).textSelection(.enabled).lineLimit(2) }
                        } else if station.kind != .decision && mission.specKit != nil {
                            // Spec Kit turns run on the mission's model; a station has none of its own.
                            MissionFactRow(label: "Model") { Text(mission.run?.model ?? "default").nwText(.mono) }
                        } else if station.kind != .decision {
                            MissionFactRow(label: "Model") {
                                let current = station.model ?? mission.run?.model ?? ""
                                Menu {
                                    ForEach(models, id: \.self) { model in
                                        Toggle(model, isOn: Binding(get: { current == model }, set: { on in
                                            guard on, var updated = plan.stations.first(where: { $0.id == station.id }) else { return }
                                            updated.model = model == mission.run?.model ? nil : model
                                            var next = plan
                                            if let index = next.stations.firstIndex(where: { $0.id == station.id }) { next.stations[index] = updated }
                                            apply(next, nil)
                                        }))
                                    }
                                } label: { MissionChipLabel(symbol: "cpu", text: current.isEmpty ? "default" : current, accessibility: "Model, \(current)") }
                                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                                    .disabled(!editable || busy || models.isEmpty)
                                    .accessibilityLabel("Model, \(current)").help("Model for this station")
                            }
                        }
                        MissionFactRow(label: "Host") { Text("This Mac").nwText(.mono) }
                        MissionFactRow(label: "Worktree") {
                            let checkout = mission.run?.checkouts.first { $0.spaceID == station.laneID }
                            Text(lane.map { "\($0.name) @ \(checkout?.branch ?? "new from \($0.baseBranch.map(MissionBranchSelection.label) ?? "base")")" } ?? "all mission worktrees, read only")
                                .nwText(.mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                    let inputs = plan.dependencies.filter { $0.target == station.id && $0.kind == .data }
                    let outputs = plan.dependencies.filter { $0.source == station.id && $0.kind == .data }
                    if !inputs.isEmpty {
                        MissionInspectorSection(title: "Inputs", meta: "data wires in") {
                            ForEach(inputs, id: \.self) { wire in
                                MissionWireRow(artifact: wire.artifact ?? "output", other: title(wire.source), incoming: true,
                                               state: mission.latest(wire.source)?.status.missionState)
                            }
                        }
                    }
                    if !outputs.isEmpty {
                        MissionInspectorSection(title: "Outputs", meta: "data wires out") {
                            ForEach(outputs, id: \.self) { wire in
                                MissionWireRow(artifact: wire.artifact ?? "output", other: title(wire.target), incoming: false, state: attempt?.status.missionState)
                            }
                        }
                    }
                    MissionInspectorSection(title: "Exits", meta: "flow wires out") { exits }
                    if !station.doneWhen.isEmpty {
                        MissionInspectorSection(title: "Station done when", meta: station.kind == .check ? "the exit status decides" : "the station sees these") {
                            ForEach(Array(station.doneWhen.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
                                    Image(systemName: attempt?.status == .succeeded ? "checkmark.square" : "square")
                                        .foregroundStyle(attempt?.status == .succeeded ? Color.nw.done : Color.nw.textTertiary)
                                    Text(item).nwText(.ui).fontWeight(.regular).textSelection(.enabled)
                                }.accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
            NWHairline()
            if !mutable {
                Text("This map is drawn from each repository's spec, plan and tasks. To change it, ask the planner below the map.")
                    .nwText(.caption).foregroundStyle(Color.nw.textTertiary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NW.Space.xl).padding(.vertical, NW.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
            HStack(spacing: NW.Space.l) {
                Button { apply(plan.bypassing(station.id), "Bypassed \(station.title).") } label: { Label("Bypass", systemImage: "arrow.turn.down.right") }
                    .buttonStyle(.nw(.ghost)).nwHelp("Remove this station and wire its inputs straight to what follows")
                Button("Remove station") { apply(plan.removing(station.id), "Removed \(station.title).") }
                    .buttonStyle(.nw(.ghost))
                Spacer()
                Menu {
                    ForEach(plan.lanes.filter { $0.id != station.laneID }) { lane in
                        Button(lane.name) { apply(plan.duplicating(station.id, to: lane.spaceID), "Duplicated \(station.title) to \(lane.name).") }
                    }
                } label: { Text("Duplicate to lane…") }
                .menuStyle(.button).buttonStyle(.nw(.secondary)).fixedSize()
                .accessibilityLabel("Duplicate to lane").help("Duplicate to lane…")
                .disabled(plan.lanes.count < (station.laneID == nil ? 1 : 2) || station.kind == .decision)
            }
            .disabled(!editable || busy)
            .padding(.horizontal, NW.Space.xl).frame(height: NWPageMetrics.headerHeight)
            }
        }
        .background(Color.nw.bgWindow)
    }

    @ViewBuilder private var exits: some View {
        let next = plan.dependencies.filter { $0.source == station.id }.map { title($0.target) }
        let retries = plan.limits.retries
        exit("done", Color.nw.done, next.isEmpty ? "review" : next.joined(separator: ", "), note: nil)
        switch station.kind {
        case .check, .validator:
            exit("failed", Color.nw.failed, "retry upstream workers ≤\(retries)", note: "then pause for you")
        case .decision:
            exit("waiting", Color.nw.lanternText, "blocks the route", note: "until the map has your answer")
        default:
            exit("failed", Color.nw.failed, "retry ×\(retries)", note: "then pause for you")
        }
        exit("budget", Color.nw.textSecondary, "pause", note: "at the mission's \(MissionFormat.tokens(plan.limits.tokens)) tok · \(MissionFormat.duration(plan.limits.seconds)) limit")
    }

    private func exit(_ tag: String, _ color: Color, _ text: String, note: String?) -> some View {
        HStack(spacing: NW.Space.m) {
            Image(systemName: "arrow.right").font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            NWTag(tag, mono: true, foreground: color)
            Text(text).nwText(.mono).fontWeight(.semibold).lineLimit(1)
            if let note { Text(note).nwText(.caption).foregroundStyle(Color.nw.textTertiary).lineLimit(1) }
        }.accessibilityElement(children: .combine)
    }
}

/// Done's inspector: the ordered pull requests, the contract with its results, and spend by lane.
private struct MissionDoneInspector: View {
    let mission: Mission
    let reviews: [MissionRepositoryReview]
    let busy: Bool
    let close: () -> Void
    let action: (MissionUIAction) -> Void

    private var checkouts: [MissionCheckout] { mission.run?.checkouts ?? [] }
    private var validated: Bool {
        let gates = mission.draft.plan?.stations.filter { $0.kind == .validator || $0.kind == .check } ?? []
        return !gates.isEmpty && gates.allSatisfy { mission.latest($0.id)?.status == .succeeded }
    }

    var body: some View {
        let run = mission.run
        let limits = mission.draft.limits
        VStack(spacing: 0) {
            MissionInspectorHead(symbol: "flag", title: "Published in order", tag: nil,
                                 pill: (mission.phase == .done ? .done : mission.phase.missionState, "\(mission.phase == .done ? "Done" : mission.phase.missionLabel) · \(MissionFormat.duration(run?.elapsedSeconds ?? 0))"),
                                 lane: nil,
                                 subtitle: "\(checkouts.filter { $0.prURL != nil }.count) PRs · \(MissionFormat.tokens(run?.tokens ?? 0)) of \(MissionFormat.tokens(limits.tokens)) tokens · \((run?.cost ?? 0).formatted(.currency(code: "USD").precision(.fractionLength(0))))",
                                 mono: false, close: close) { EmptyView() }
            ScrollView {
                VStack(spacing: 0) {
                    MissionInspectorSection(title: mission.workSummary?.title ?? "Summary") {
                        MissionProse(mission.workSummary?.text ?? mission.draft.goal)
                    }
                    let checks = mission.draft.plan?.stations.filter { $0.kind == .check } ?? []
                    let total = mission.draft.requirements.count + checks.count
                    MissionInspectorSection(title: "Contract · now visible", meta: validated ? "\(total) / \(total)" : nil) {
                        ForEach(Array(mission.draft.requirements.enumerated()), id: \.offset) { _, requirement in
                            row(validated, requirement, tag: "validator")
                        }
                        ForEach(checks) { check in
                            row(run?.latest(check.id)?.status == .succeeded, check.command ?? check.title, tag: run?.latest(check.id)?.exitCode.map { "exit \($0)" } ?? "cmd")
                        }
                        row(run?.publicationApproval != nil, "You approved the PR set", tag: "you")
                    }
                    MissionInspectorSection(title: "Published, in order") {
                        ForEach(Array(checkouts.enumerated()), id: \.element.id) { index, checkout in
                            let review = reviews.first { $0.spaceID == checkout.spaceID }
                            HStack(spacing: NW.Space.m) {
                                Text("\(index + 1)").nwText(.micro).foregroundStyle(Color.nw.textTertiary)
                                NWGlyph.gitBranch.image.foregroundStyle(Color.nw.done)
                                Text(mission.lane(checkout.spaceID)?.name ?? checkout.repo).nwText(.mono).fontWeight(.semibold).lineLimit(1)
                                if let link = checkout.prURL, let url = URL(string: link), url.scheme == "https" {
                                    Link(MissionFormat.pullNumber(link) ?? "PR", destination: url).nwText(.mono).foregroundStyle(Color.nw.running)
                                        .accessibilityLabel("Open pull request")
                                        .accessibilityValue(link)
                                } else {
                                    Text("not published").nwText(.caption).foregroundStyle(Color.nw.textTertiary)
                                }
                                if let review {
                                    NWDiffStat(added: review.files.reduce(0) { $0 + $1.addedCount }, removed: review.files.reduce(0) { $0 + $1.removedCount })
                                }
                                Spacer(minLength: NW.Space.m)
                                Text(checkout.branch).nwText(.micro).foregroundStyle(Color.nw.textTertiary).lineLimit(1).truncationMode(.head)
                            }
                        }
                    }
                    MissionInspectorSection(title: "Spend by lane") { spend }
                }
            }
            NWHairline()
            HStack {
                Button { action(.runAgain) } label: { Label("Run again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.nw(.ghost)).disabled(busy)
                    .nwHelp("Plan a new mission with the same destination, repositories, branches and model")
                Spacer()
            }.padding(.horizontal, NW.Space.xl).frame(height: NWPageMetrics.headerHeight)
        }
        .background(Color.nw.bgWindow)
    }

    private func row(_ passed: Bool, _ text: String, tag: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
            Image(systemName: passed ? "checkmark" : "circle").font(.nw(.caption, weight: .semibold))
                .foregroundStyle(passed ? Color.nw.done : Color.nw.textTertiary)
            Text(text).nwText(.ui).fontWeight(.regular).textSelection(.enabled)
            Spacer(minLength: NW.Space.m)
            Text(tag).nwText(.micro).foregroundStyle(Color.nw.textTertiary)
        }.accessibilityElement(children: .combine)
    }

    /// Tokens by lane from attempt receipts; planning and orchestration stations count as mission.
    private var spend: some View {
        let stations = Dictionary(uniqueKeysWithValues: (mission.draft.plan?.stations ?? []).map { ($0.id, $0.laneID) })
        var totals: [String: Int] = [:]
        for attempt in mission.run?.attempts ?? [] {
            let lane = attempt.stationID.flatMap { stations[$0] ?? nil }
            totals[mission.lane(lane)?.name ?? "mission", default: 0] += attempt.tokens
        }
        let names = ["mission"] + (mission.draft.plan?.lanes.map(\.name) ?? [])
        let top = max(1, totals.values.max() ?? 1)
        return VStack(spacing: NW.Space.m) {
            ForEach(names, id: \.self) { name in
                HStack(spacing: NW.Space.l) {
                    Text(name).nwText(.mono).lineLimit(1).frame(width: AppLayout.missionBriefLaneName, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.nw.lineSubtle)
                            Capsule().fill(Color.nw.textTertiary).frame(width: geometry.size.width * CGFloat(totals[name] ?? 0) / CGFloat(top))
                        }
                    }.frame(height: AppLayout.missionSpendBar)
                    Text(MissionFormat.tokens(totals[name] ?? 0)).nwText(.mono).foregroundStyle(Color.nw.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(name), \(MissionFormat.tokens(totals[name] ?? 0)) tokens")
            }
        }
    }
}

struct MissionStationEditor: View {
    @State var station: MissionStation
    let revision: UInt64
    let currentRevision: UInt64
    let busy: Bool
    let cancel: () -> Void
    let save: (MissionStation) -> Void
    @State private var checks = ""
    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            Text("Edit station").nwText(.title)
            if revision != currentRevision {
                Text("This mission changed. Your edits are kept here; cancel and reopen to edit the current station.")
                    .nwText(.caption).foregroundStyle(AgentState.attention.textColor)
            }
            Text("Title").nwText(.ui)
            TextField("Title", text: $station.title).textFieldStyle(.nw).accessibilityLabel("Station title")
            MissionTextEditor(title: "Goal", text: $station.goal)
            if station.kind == .check {
                Text("Command").nwText(.ui)
                TextField("Command", text: Binding(get: { station.command ?? "" }, set: { station.command = $0 }))
                    .textFieldStyle(.nw(mono: true)).accessibilityLabel("Command")
            }
            MissionTextEditor(title: "Done when · one per line", text: $checks)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(.nw(.ghost)).keyboardShortcut(.cancelAction)
                Button("Save station") {
                    station.doneWhen = checks.split(separator: "\n").map(String.init)
                    save(station)
                }.buttonStyle(.nw(.primary)).keyboardShortcut(.defaultAction)
                    .disabled(busy || revision != currentRevision || station.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || station.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(NW.Space.xxl).frame(width: AppLayout.missionStartWidth)
            .onAppear { checks = station.doneWhen.joined(separator: "\n") }
    }
}
