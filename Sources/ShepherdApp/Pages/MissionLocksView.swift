import SwiftUI
import ShepherdCore
import ShepherdUI

// MARK: Path locks (MXLocks)

extension Mission {
    /// Lanes another mission holds that keep their stations waiting.
    var heldLanes: [SpaceID] { (draft.plan?.lanes ?? []).map(\.spaceID).filter { run?.held?[$0]?.blocks == true } }
    /// Run shows the locks while another mission holds any of this one's repositories.
    var locksShown: Bool { [.running, .paused].contains(phase) && !(run?.held ?? [:]).isEmpty }
}

/// Run while a repository is held: when each mission holds what, the paths both plan to write, the queue,
/// and the choice for the held repository. `others` are the host's other missions.
struct MissionLocksPage<Route: View>: View {
    let mission: Mission
    let others: [Mission]
    let busy: Bool
    let action: (MissionUIAction) -> Void
    @ViewBuilder let route: () -> Route
    @State private var showingRoute = false
    @State private var selected: SpaceID?

    private var lanes: [MissionLane] { mission.draft.plan?.lanes ?? [] }
    private var locked: [SpaceID] { lanes.map(\.spaceID).filter { mission.run?.held?[$0] != nil } }
    private var lane: SpaceID? { selected.flatMap { locked.contains($0) ? $0 : nil } ?? locked.first }
    private var lock: MissionLaneLock? { lane.flatMap { mission.run?.held?[$0] } }
    private var holder: Mission? { lock.flatMap { lock in others.first { $0.id == lock.holder } } }

    var body: some View {
        GeometryReader { page in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        SHSegmentedPicker("Show", selection: $showingRoute, options: [(false, "Locks"), (true, "Route")]).fixedSize()
                        Spacer()
                    }
                    .padding(.horizontal, SH.Space.xl).padding(.vertical, SH.Space.m)
                    if showingRoute { route() } else { locks }
                }
                .frame(maxWidth: .infinity)
                if let lane, let lock {
                    Rectangle().fill(Color.sh.lineSubtle).frame(width: 1)
                    MissionLockInspector(mission: mission, lane: lane, lock: lock, holder: holder,
                                         position: position(lane, lock),
                                         busy: busy, action: action)
                        .id(lane)
                        .frame(width: AppLayout.missionSide(AppLayout.missionInspectorWidth, in: page.size.width))
                }
            }
        }
    }

    /// This mission's place among those waiting: 1 is next once the holder frees the paths.
    private func position(_ lane: SpaceID, _ lock: MissionLaneLock) -> Int? {
        let waiting = queue(lane, lock).filter { $0.state == .waiting }
        return waiting.firstIndex { $0.mission.id == mission.id }.map { $0 + 1 }
    }

    private func queue(_ lane: SpaceID, _ lock: MissionLaneLock) -> [(mission: Mission, state: QueueState)] {
        (others + [mission]).queue(lane, paths: lock.overlap)
    }

    private var locks: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SH.Space.xxl) {
                MissionLocksTimeline(mission: mission, holder: holder, rows: rows)
                table
                HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                    Image(systemName: "lock").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    (Text("Missions lock ") + Text("paths, not repos").fontWeight(.semibold)
                     + Text(". A mission holds the paths its stations plan to write, taken from the map. A station that writes outside its paths pauses and asks."))
                        .shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(SH.Space.l)
                .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
                if let lane, let lock { queueList(lane, lock) }
            }
            .padding(SH.Space.xl)
        }
    }

    /// Every repository this mission or the holder works in, this mission's first.
    private var rows: [MissionLane] {
        var rows = lanes
        for other in holder?.draft.plan?.lanes ?? [] where !rows.contains(where: { $0.spaceID == other.spaceID }) { rows.append(other) }
        return rows
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            SHPageSectionLabel("Paths each mission holds").padding(.bottom, SH.Space.l)
            SHTableHead(["Repo", holder?.draft.title ?? "Other mission", "This mission", "Result"], columns: AppLayout.missionLockColumns)
            ForEach(lanes) { lane in
                let theirs = holder?.holds(lane.spaceID) ?? []
                let ours = mission.writes(lane.spaceID)
                let lock = mission.run?.held?[lane.spaceID]
                Button { if lock != nil { selected = lane.spaceID } } label: {
                    SHTableColumns(AppLayout.missionLockColumns) {
                        Text(lane.name).font(.sh(.mono, weight: .semibold)).lineLimit(1)
                        Text(theirs.isEmpty ? "—" : theirs.joined(separator: "  ")).shText(.mono).foregroundStyle(Color.sh.textSecondary).lineLimit(2)
                        Text(ours.isEmpty ? "not declared" : ours.joined(separator: "  ")).shText(.mono).foregroundStyle(Color.sh.textSecondary).lineLimit(2)
                        result(lock, theirs: theirs)
                    }
                    .padding(.vertical, SH.Space.l).padding(.horizontal, SHPageMetrics.sideInset)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(lock != nil && lane.spaceID == self.lane ? Color.sh.bgRaised : Color.clear)
                .overlay(alignment: .top) { SHHairline() }
            }
        }
    }

    @ViewBuilder private func result(_ lock: MissionLaneLock?, theirs: [String]) -> some View {
        if let lock {
            let file = lock.overlap.first.map { ($0 as NSString).lastPathComponent } ?? "paths"
            let what = lock.choice == .wait ? "waits" : lock.choice == .stack ? "stacked" : "runs anyway"
            Label("\(file) overlaps · \(what)", systemImage: "lock").shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.lanternText).lineLimit(1)
        } else if theirs.isEmpty {
            Label("free", systemImage: "checkmark").shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.done)
        } else {
            Label("no overlap · both run", systemImage: "checkmark").shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.done).lineLimit(1)
        }
    }

    private func queueList(_ lane: SpaceID, _ lock: MissionLaneLock) -> some View {
        let name = mission.lane(lane)?.name ?? "repository"
        let file = lock.overlap.first.map { ($0 as NSString).lastPathComponent } ?? "paths"
        return VStack(alignment: .leading, spacing: 0) {
            SHPageSectionLabel("Queue on \(name) · \(file)").padding(.bottom, SH.Space.l)
            ForEach(Array(queue(lane, lock).enumerated()), id: \.offset) { index, entry in
                let mine = entry.mission.id == mission.id
                HStack(spacing: SH.Space.l) {
                    Text("\(index + 1)").shText(.micro).foregroundStyle(Color.sh.textTertiary).frame(width: SH.Space.xl, alignment: .leading)
                    Text(entry.mission.draft.title).shText(.headline).lineLimit(1).frame(maxWidth: AppLayout.missionLockQueueTitle, alignment: .leading)
                    Text(detail(entry, mine: mine, file: lock.overlap.first ?? "")).shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                    Spacer(minLength: SH.Space.m)
                    Text(meta(entry.state)).shText(.micro).foregroundStyle(Color.sh.textTertiary).lineLimit(1).fixedSize()
                }
                .padding(.horizontal, SH.Space.m).padding(.vertical, SH.Space.l)
                .background(mine ? Color.sh.bgRaised : Color.clear)
                .overlay(alignment: .top) { SHHairline() }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func detail(_ entry: (mission: Mission, state: QueueState), mine: Bool, file: String) -> String {
        switch entry.state {
        case .holding:
            if let train = entry.mission.run?.train, train.status != .done { return "holding · merge train, \(train.merged) of \(train.cars.count)" }
            return "holding · \(entry.mission.phase.missionLabel.lowercased())"
        case .waiting: return mine ? "this mission · waiting" : "waiting"
        case .draft: return "draft · plans to write \((file as NSString).lastPathComponent)"
        }
    }

    private func meta(_ state: QueueState) -> String {
        switch state {
        case .holding: "releases when it merges"
        case .waiting: "starts when it's free"
        case .draft: "not launched"
        }
    }
}

/// "Repos over time": each repository's row with when this mission and the holder held it, the held stretch
/// hatched, what's still planned dashed, and now.
private struct MissionLocksTimeline: View {
    let mission: Mission
    let holder: Mission?
    let rows: [MissionLane]

    private struct Bar { let lane: SpaceID; let start: Double; let end: Double; let label: String; let kind: Kind }
    private enum Kind { case mine, theirs, held, planned }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { clock in
            let now = clock.date.timeIntervalSince1970
            let bars = bars(now)
            let start = (floor(((bars.map(\.start).min() ?? now) - 1_800) / 3_600)) * 3_600
            let end = max(start + 3 * 3_600, ceil(((bars.map(\.end).max() ?? now) + 1_800) / 3_600) * 3_600)
            VStack(alignment: .leading, spacing: SH.Space.l) {
                HStack {
                    SHPageSectionLabel("Repos over time")
                    Spacer()
                    legend
                }
                GeometryReader { geometry in
                    let width = geometry.size.width - AppLayout.missionLockRowLabel
                    let x = { (t: Double) in AppLayout.missionLockRowLabel + CGFloat((t - start) / (end - start)) * width }
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(stride(from: start, through: end, by: 3_600).enumerated()), id: \.offset) { _, hour in
                            Text(Date(timeIntervalSince1970: hour).formatted(date: .omitted, time: .shortened)).shText(.micro).foregroundStyle(Color.sh.textTertiary)
                                .fixedSize().position(x: x(hour), y: SH.Space.s)
                            Rectangle().fill(Color.sh.lineSubtle).frame(width: 1, height: CGFloat(rows.count) * AppLayout.missionLockRow)
                                .offset(x: x(hour), y: SH.Space.xl)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, lane in
                            row(lane, y: SH.Space.xl + CGFloat(index) * AppLayout.missionLockRow, bars: bars.filter { $0.lane == lane.spaceID }, x: x)
                        }
                        Rectangle().fill(Color.sh.running).frame(width: 1, height: CGFloat(rows.count) * AppLayout.missionLockRow + SH.Space.l)
                            .offset(x: x(now), y: SH.Space.xl)
                        Text("now \(clock.date.formatted(date: .omitted, time: .shortened))").shText(.micro).foregroundStyle(Color.sh.running)
                            .fixedSize().position(x: x(now), y: SH.Space.xl + CGFloat(rows.count) * AppLayout.missionLockRow + SH.Space.xl)
                    }
                }
                .frame(height: SH.Space.xxl * 2 + CGFloat(rows.count) * AppLayout.missionLockRow)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("When each mission holds each repository")
        }
    }

    private func row(_ lane: MissionLane, y: CGFloat, bars: [Bar], x: @escaping (Double) -> CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: SH.Space.s) {
                SHGlyph.repository.image.font(.sh(.micro)).foregroundStyle(Color.sh.textTertiary)
                Text(lane.name).font(.sh(.mono, weight: .semibold)).lineLimit(1)
            }
            .frame(width: AppLayout.missionLockRowLabel, height: AppLayout.missionLockRow, alignment: .leading)
            Rectangle().fill(Color.sh.lineSubtle).frame(height: 1)
            ForEach(Array(bars.enumerated()), id: \.offset) { slot, bar in
                let width: CGFloat = max(SH.Space.xl, x(bar.end) - x(bar.start))
                let top: CGFloat = SH.Space.m + CGFloat(min(slot, 1)) * (AppLayout.missionLockBar + SH.Space.xs)
                barView(bar).frame(width: width, height: AppLayout.missionLockBar).offset(x: x(bar.start), y: top)
            }
        }
        .offset(y: y)
    }

    private func bars(_ now: Double) -> [Bar] {
        var bars: [Bar] = []
        func spans(_ mission: Mission, kind: Kind) {
            for lane in mission.draft.plan?.lanes ?? [] {
                let stations = Set((mission.draft.plan?.stations ?? []).filter { $0.laneID == lane.spaceID }.map(\.id))
                let attempts = (mission.run?.attempts ?? []).filter { $0.stationID.map(stations.contains) == true }
                guard let first = attempts.compactMap(\.startedAt).min() else { continue }
                let end = mission.holds(lane.spaceID).isEmpty ? (attempts.compactMap(\.endedAt).max() ?? now) : now
                let worker = (mission.draft.plan?.stations ?? []).first { $0.laneID == lane.spaceID && $0.kind == .worker }
                let short = kind == .theirs ? (mission.draft.title.split(separator: " ").first.map { $0.lowercased() } ?? "") : (worker?.title ?? lane.name)
                let path = mission.writes(lane.spaceID).first.map { " · " + ($0.replacingOccurrences(of: "/**", with: "") as NSString).lastPathComponent } ?? ""
                bars.append(Bar(lane: lane.spaceID, start: first, end: max(end, first + 60), label: short + (kind == .theirs ? path : ""), kind: kind))
            }
        }
        if let holder { spans(holder, kind: .theirs) }
        spans(mission, kind: .mine)
        let remaining = max(1_800, (mission.draft.plan?.estimate?.seconds ?? 3_600) - (mission.run?.elapsed(at: now) ?? 0))
        for (lane, lock) in mission.run?.held ?? [:] where lock.blocks {
            let file = lock.overlap.first.map { ($0 as NSString).lastPathComponent } ?? "paths"
            bars.append(Bar(lane: lane, start: lock.since, end: now, label: "held · \(file)", kind: .held))
            let worker = (mission.draft.plan?.stations ?? []).first { $0.laneID == lane && $0.kind == .worker }
            bars.append(Bar(lane: lane, start: now, end: now + remaining, label: worker?.title ?? "", kind: .planned))
        }
        return bars
    }

    @ViewBuilder private func barView(_ bar: Bar) -> some View {
        let shape = RoundedRectangle(cornerRadius: SH.Radius.xs)
        let label = Text(bar.label).shText(.micro).lineLimit(1).padding(.horizontal, SH.Space.s).frame(maxWidth: .infinity, alignment: .leading)
        switch bar.kind {
        case .theirs: label.foregroundStyle(Color.sh.textSecondary).background(Color.sh.bgSelected, in: shape)
        case .mine: label.foregroundStyle(Color.sh.running).background(Color.sh.runningTint, in: shape).overlay(shape.strokeBorder(Color.sh.running))
        case .held:
            label.foregroundStyle(Color.sh.lanternText).background(Color.sh.lanternTint, in: shape)
                .overlay(shape.strokeBorder(Color.sh.lantern, style: StrokeStyle(lineWidth: 1, dash: AppLayout.missionDataDash)))
        case .planned:
            label.foregroundStyle(Color.sh.running)
                .overlay(shape.strokeBorder(Color.sh.running, style: StrokeStyle(lineWidth: 1, dash: AppLayout.missionDataDash)))
        }
    }

    private var legend: some View {
        let shape = RoundedRectangle(cornerRadius: SH.Radius.xs)
        return HStack(spacing: SH.Space.l) {
            HStack(spacing: SH.Space.s) { shape.strokeBorder(Color.sh.running).frame(width: SH.Space.l, height: SH.Space.m); Text("this mission") }
            if let holder { HStack(spacing: SH.Space.s) { shape.fill(Color.sh.bgSelected).frame(width: SH.Space.l, height: SH.Space.m); Text(holder.draft.title) } }
            HStack(spacing: SH.Space.s) { shape.strokeBorder(Color.sh.lantern, style: StrokeStyle(lineWidth: 1, dash: AppLayout.missionDataDash)).frame(width: SH.Space.l, height: SH.Space.m); Text("held") }
            HStack(spacing: SH.Space.s) { shape.strokeBorder(Color.sh.running, style: StrokeStyle(lineWidth: 1, dash: AppLayout.missionDataDash)).frame(width: SH.Space.l, height: SH.Space.m); Text("planned") }
        }
        .shText(.caption).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
    }
}

/// The held repository: what overlaps, the three ways on, what else moves meanwhile, and the choice.
private struct MissionLockInspector: View {
    let mission: Mission
    let lane: SpaceID
    let lock: MissionLaneLock
    let holder: Mission?
    let position: Int?
    let busy: Bool
    let action: (MissionUIAction) -> Void
    @State private var choice: MissionLaneLock.Choice?

    private var name: String { mission.lane(lane)?.name ?? "repository" }
    private var chosen: MissionLaneLock.Choice { choice ?? lock.choice }

    var body: some View {
        VStack(spacing: 0) {
            MissionInspectorHead(symbol: "lock", title: "\(name) is held", tag: position.map { "queue #\($0)" }, pill: nil, lane: nil,
                                 subtitle: "by \(lock.holderTitle)", mono: false, close: nil) { EmptyView() }
            ScrollView {
                VStack(spacing: 0) {
                    MissionInspectorSection(title: "The overlap", meta: "\(lock.overlap.count) path\(lock.overlap.count == 1 ? "" : "s")") {
                        VStack(alignment: .leading, spacing: SH.Space.m) {
                            ForEach(lock.overlap, id: \.self) { Text($0).font(.sh(.mono, weight: .semibold)).textSelection(.enabled) }
                            Text(overlapProse).shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(SH.Space.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
                    }
                    MissionInspectorSection(title: "What next") {
                        option(.wait, "Wait for it to merge", tag: "suggested", meta: "when it frees",
                               "Starts from \(base) after \(lock.holderTitle)'s pull request merges, so your change lands on top of theirs.")
                        option(.stack, "Stack on its branch", meta: "starts now",
                               "Starts now from \(holderBranch) and keeps its changes in your branch. If it changes these paths again, merge it again.")
                        option(.runAnyway, "Run anyway", meta: "likely conflict", warning: true,
                               "Both missions edit \(file) at once. Whichever merges second conflicts, and its merge train pauses on it.")
                    }
                    MissionInspectorSection(title: "Meanwhile") { meanwhile }
                }
            }
            SHHairline()
            HStack(spacing: SH.Space.l) {
                Text(chosen == .wait ? "You'll get a notification when \(name) starts." : chosen == .stack ? "Merges \(holderBranch) into your worktree first." : "Starts \(name)'s stations now.")
                    .shText(.caption).foregroundStyle(Color.sh.textTertiary).lineLimit(2)
                Spacer(minLength: SH.Space.m)
                Button(chosen == .wait ? "Wait in queue" : chosen == .stack ? "Stack on its branch" : "Run anyway") { action(.laneLock(lane, chosen)) }
                    .buttonStyle(.sh(.primary)).disabled(busy)
            }
            .padding(.horizontal, SH.Space.xl).frame(height: SHPageMetrics.headerHeight)
        }
        .background(Color.sh.bgWindow)
    }

    private var base: String { mission.run?.checkouts.first { $0.spaceID == lane }?.base ?? "main" }
    private var file: String { lock.overlap.first.map { ($0 as NSString).lastPathComponent } ?? "these paths" }
    private var holderBranch: String { holder?.run?.checkouts.first { $0.spaceID == lane }?.branch ?? "its branch" }
    private var overlapProse: String {
        let theirs = holder.map { holder in (holder.draft.plan?.stations ?? []).filter { $0.laneID == lane && $0.kind == .worker && !MissionPaths.overlap($0.paths ?? [], lock.overlap).isEmpty }.map(\.title) } ?? []
        let ours = (mission.draft.plan?.stations ?? []).filter { $0.laneID == lane && $0.kind == .worker && !MissionPaths.overlap($0.paths ?? [], lock.overlap).isEmpty }.map(\.title)
        return "\(lock.holderTitle) writes it\(theirs.isEmpty ? "" : " in \(theirs.joined(separator: ", "))"). This mission plans to write it\(ours.isEmpty ? "" : " in \(ours.joined(separator: ", "))")."
    }

    private func option(_ value: MissionLaneLock.Choice, _ title: String, tag: String? = nil, meta: String, warning: Bool = false, _ text: String) -> some View {
        let on = chosen == value
        return Button { choice = value } label: {
            HStack(alignment: .top, spacing: SH.Space.m) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").font(.sh(.headline))
                    .foregroundStyle(on ? Color.sh.lanternText : Color.sh.textTertiary)
                VStack(alignment: .leading, spacing: SH.Space.s) {
                    HStack(spacing: SH.Space.m) {
                        Text(title).shText(.headline)
                        if let tag { SHTag(tag, mono: true, foreground: Color.sh.lanternText) }
                        Spacer(minLength: SH.Space.s)
                        Text(meta).shText(.micro).foregroundStyle(warning ? Color.sh.failed : Color.sh.textTertiary)
                    }
                    Text(text).shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(SH.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color.sh.lanternTint : Color.clear, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            .shBorder(on ? Color.sh.lantern : Color.sh.lineSubtle, radius: SH.Radius.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var meanwhile: some View {
        VStack(spacing: SH.Space.xs) {
            ForEach(mission.draft.plan?.lanes ?? []) { other in
                let held = other.spaceID == lane
                let stations = (mission.draft.plan?.stations ?? []).filter { $0.laneID == other.spaceID }
                let latest = stations.compactMap { station in mission.latest(station.id).map { (station, $0) } }.max { ($0.1.startedAt ?? 0) < ($1.1.startedAt ?? 0) }
                HStack(spacing: SH.Space.m) {
                    Group {
                        if held { Image(systemName: "lock").foregroundStyle(Color.sh.lanternText) }
                        else if latest?.1.status == .running { ProgressView().progressViewStyle(.shSpinner(size: 12)) }
                        else if latest?.1.status == .succeeded { Image(systemName: "checkmark").foregroundStyle(Color.sh.done) }
                        else { Image(systemName: "circle").foregroundStyle(Color.sh.textTertiary) }
                    }
                    .font(.sh(.caption)).frame(width: SH.Space.l)
                    Text(other.name).font(.sh(.mono, weight: .semibold)).lineLimit(1).frame(width: AppLayout.missionBriefLaneName, alignment: .leading)
                    Text(held ? "held" : latest.map { "\($0.0.title) · \($0.1.status == .running ? "writing" : $0.1.status.rawValue)" } ?? "waiting")
                        .shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                    Spacer(minLength: SH.Space.m)
                    Text(held ? position.map { "queue #\($0)" } ?? "" : latest?.1.status == .succeeded ? "done" : "")
                        .shText(.micro).foregroundStyle(Color.sh.textTertiary)
                }
                .padding(.horizontal, SH.Space.m).frame(height: SH.Height.controlL)
                .background(held ? Color.sh.bgRaised : Color.clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                .accessibilityElement(children: .combine)
            }
        }
    }
}
