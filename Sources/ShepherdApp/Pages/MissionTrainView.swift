import SwiftUI
import ShepherdCore
import ShepherdUI

// MARK: Merge train (MXTrain)

extension Mission {
    /// The repositories whose pull requests the train can merge, in the map's lane order.
    var publishedLanes: [SpaceID] { (draft.plan?.lanes ?? []).map(\.spaceID).filter { lane in run?.checkouts.contains { $0.spaceID == lane && $0.prURL != nil } == true } }
    /// A published mission's merge train is what Run shows until it finishes.
    var trainShown: Bool { phase == .done && !publishedLanes.isEmpty }
}

/// Run for a published mission: the merge train, or the map it came from.
struct MissionTrainPage<Map: View>: View {
    let mission: Mission
    let reviews: [MissionRepositoryReview]
    let busy: Bool
    let action: (MissionUIAction) -> Void
    @ViewBuilder let map: () -> Map
    @State private var showingMap = false
    /// The order and rules shown before Start, and while a paused train is changed.
    @State private var order: [SpaceID] = []
    @State private var rules = MissionTrain.Rules()
    @State private var refusal: String?

    private var train: MissionTrain? { mission.run?.train }
    private var plan: MissionPlan { mission.draft.plan ?? MissionPlan() }
    /// Before Start and while paused the owner arranges the train; running, it is the record.
    private var editable: Bool { train == nil || train?.status == .paused }
    private var proposal: MissionTrainOrder {
        let sizes = Dictionary(uniqueKeysWithValues: reviews.map { ($0.spaceID, $0.files.reduce(0) { $0 + $1.addedCount + $1.removedCount }) })
        return MissionTrainOrder(plan: plan, sizes: sizes)
    }
    private var shownOrder: [SpaceID] { train.map { $0.cars.map(\.spaceID) } ?? order }

    var body: some View {
        GeometryReader { page in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    toolbar
                    if showingMap { map() } else { cars }
                }
                .frame(maxWidth: .infinity)
                Rectangle().fill(Color.sh.lineSubtle).frame(width: 1)
                MissionTrainInspector(mission: mission, order: shownOrder, rules: $rules, editable: editable, busy: busy,
                                      changed: { if train?.status == .paused { action(.changeTrain(shownOrder, $0)) } },
                                      start: { action(.startTrain(order, rules)) }, action: action)
                    .frame(width: AppLayout.missionSide(AppLayout.missionInspectorWidth, in: page.size.width))
            }
        }
        .onAppear(perform: seed)
        .onChange(of: train?.rules) { _, _ in if let train { rules = train.rules } }
    }

    private func seed() {
        let published = Set(mission.publishedLanes)
        order = proposal.lanes.filter(published.contains)
        if let train { rules = train.rules }
    }

    private var toolbar: some View {
        HStack(spacing: SH.Space.l) {
            SHSegmentedPicker("Show", selection: $showingMap, options: [(true, "Map"), (false, "Train")]).fixedSize()
            Spacer(minLength: SH.Space.m)
            if !showingMap {
                Text(refusal ?? (editable ? "Drag a card to change the order. The planner checks it against the data wires." : "One pull request at a time, in this order."))
                    .shText(.caption).foregroundStyle(refusal == nil ? Color.sh.textTertiary : Color.sh.failed).lineLimit(1)
            }
        }
        .padding(.horizontal, SH.Space.xl).padding(.vertical, SH.Space.m)
    }

    private var cars: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SH.Space.xl) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: SH.Space.m) {
                        ForEach(Array(shownOrder.enumerated()), id: \.element) { index, lane in
                            if index > 0 {
                                Image(systemName: "arrow.right").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                                    .padding(.top, AppLayout.missionTrainArrowTop).accessibilityHidden(true)
                            }
                            card(index, lane)
                        }
                    }
                    .padding(.horizontal, SH.Space.xl).padding(.vertical, SH.Space.xxs)
                }
                VStack(alignment: .leading, spacing: SH.Space.xl) {
                    if let notice = train?.notice {
                        banner(notice, glyph: "pause.circle")
                    } else if let fix = autoFix {
                        banner(fix, glyph: "checkmark")
                    }
                    reasons
                }
                .padding(.horizontal, SH.Space.xl)
            }
            .padding(.vertical, SH.Space.m)
        }
    }

    @ViewBuilder private func card(_ index: Int, _ lane: SpaceID) -> some View {
        let car = train?.cars.first { $0.spaceID == lane } ?? MissionTrain.Car(spaceID: lane, steps: MissionTrain.steps(rules))
        let current = train?.current.map { train?.cars[$0].spaceID == lane } ?? false
        let movable = editable && !car.steps.contains { $0.status != .pending }
        MissionTrainCard(index: index, name: mission.lane(lane)?.name ?? "repository",
                         pull: MissionFormat.pullNumber(mission.run?.checkouts.first { $0.spaceID == lane }?.prURL),
                         review: reviews.first { $0.spaceID == lane }, role: role(lane), car: car, current: current && train?.status == .running,
                         soakMinutes: rules.soakMinutes)
            .draggable(lane.rawValue) { Text(mission.lane(lane)?.name ?? "").shText(.mono).padding(SH.Space.m) }
            .dropDestination(for: String.self) { items, _ in
                guard movable, let dragged = items.first.map({ SpaceID(rawValue: $0) }), dragged != lane, shownOrder.contains(dragged) else { return false }
                move(dragged, before: lane)
                return true
            }
    }

    /// Moves a car that hasn't started; the data wires decide whether the order is safe.
    private func move(_ lane: SpaceID, before target: SpaceID) {
        var next = shownOrder
        next.removeAll { $0 == lane }
        next.insert(lane, at: next.firstIndex(of: target) ?? next.count)
        guard MissionTrainOrder.allows(next, plan: plan) else {
            refusal = "\(mission.lane(lane)?.name ?? "That repository") can't go there: it takes output from a repository that would merge after it."
            return
        }
        refusal = nil
        if train?.status == .paused { action(.changeTrain(next, rules)) } else { order = next }
    }

    /// "shared protos", "consumer", "producer": what the lane's data wires make it.
    private func role(_ lane: SpaceID) -> String? {
        let laneOf = Dictionary(uniqueKeysWithValues: plan.stations.map { ($0.id, $0.laneID) })
        let cross = plan.dependencies.filter { $0.kind == .data }.compactMap { wire -> (SpaceID, SpaceID, String?)? in
            guard let from = laneOf[wire.source] ?? nil, let to = laneOf[wire.target] ?? nil, from != to else { return nil }
            return (from, to, wire.artifact)
        }
        let out = Set(cross.filter { $0.0 == lane }.map(\.1)), into = cross.contains { $0.1 == lane }
        if !into, out.count > 1 { return "shared \(cross.first { $0.0 == lane }?.2 ?? "output")" }
        if !out.isEmpty { return "producer" }
        return into ? "consumer" : nil
    }

    /// MXTrain's note when the train fixed something on its own: what, when, and which rule let it.
    private var autoFix: String? {
        guard let train, let fix = train.log.last(where: { $0.by == "auto · rule" && $0.subject == "rebase-fix" }),
              let car = train.cars.first(where: { $0.steps.contains { $0.status == .fixed } }) else { return nil }
        let name = mission.lane(car.spaceID)?.name ?? "A repository"
        let base = mission.run?.checkouts.first { $0.spaceID == car.spaceID }?.base ?? "main"
        let at = Date(timeIntervalSince1970: fix.at).formatted(date: .omitted, time: .shortened)
        return "\(base) moved before \(at), and \(name) stopped updating cleanly. The train regenerated \(fix.text.replacingOccurrences(of: " regenerated", with: "")) without asking, because lockfile conflicts are on your fix automatically list. A code conflict would have paused here."
    }

    private func banner(_ text: String, glyph: String) -> some View {
        HStack(alignment: .top, spacing: SH.Space.l) {
            Image(systemName: glyph).font(.sh(.caption, weight: .semibold)).foregroundStyle(Color.sh.lanternText)
            Text(text).shText(.ui).fontWeight(.regular).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(SH.Space.l)
        .background(Color.sh.lanternTint, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(Color.sh.lantern, radius: SH.Radius.m)
    }

    private var reasons: some View {
        let reasons = proposal.reasons
        return VStack(alignment: .leading, spacing: SH.Space.l) {
            HStack {
                SHPageSectionLabel("Why this order")
                Spacer()
                Text("worked out from the data wires, not guessed").shText(.micro).foregroundStyle(Color.sh.textTertiary)
            }
            if reasons.isEmpty {
                Text("No repository takes another's output, so any order is safe. The smaller diff goes first.")
                    .shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textSecondary)
            }
            ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                HStack(alignment: .firstTextBaseline, spacing: SH.Space.l) {
                    Text(reason.lanes.compactMap { lane in shownOrder.firstIndex(of: lane).map { "\($0 + 1)" } }.joined(separator: " · "))
                        .shText(.mono).foregroundStyle(Color.sh.textTertiary).frame(width: AppLayout.missionTrainReasonNumber, alignment: .leading)
                    Text(reason.title).shText(.ui).frame(width: AppLayout.missionTrainReasonTitle, alignment: .leading)
                    Text(reason.text).shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
    }
}

/// One pull request in the train: its place, size and role, its state, and each step's receipt.
private struct MissionTrainCard: View {
    let index: Int
    let name: String
    let pull: String?
    let review: MissionRepositoryReview?
    let role: String?
    let car: MissionTrain.Car
    let current: Bool
    let soakMinutes: Int

    private var state: (AgentState, String) {
        if car.merged && car.finished { return (.done, "Merged") }
        if current { return (.running, "In the train") }
        if car.steps.contains(where: { $0.status == .failed }) { return (.failed, "Stopped") }
        if car.merged { return (.done, "Merged") }
        return (.idle, "Waiting")
    }

    var body: some View {
        let waiting = state.1 == "Waiting"
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SH.Space.s) {
                HStack(spacing: SH.Space.m) {
                    Text("\(index + 1)").shText(.micro).foregroundStyle(Color.sh.textSecondary)
                        .frame(width: AppLayout.missionTrainNumber, height: AppLayout.missionTrainNumber)
                        .overlay(Circle().strokeBorder(Color.sh.lineStrong))
                    Text(name).font(.sh(.mono, weight: .semibold)).lineLimit(1)
                }
                HStack(spacing: SH.Space.s) {
                    if let pull { Text(pull).shText(.mono).foregroundStyle(Color.sh.running) }
                    if let review {
                        SHDiffStat(added: review.files.reduce(0) { $0 + $1.addedCount }, removed: review.files.reduce(0) { $0 + $1.removedCount })
                    }
                    if let role { Text(role).shText(.caption).foregroundStyle(Color.sh.textTertiary).lineLimit(1) }
                }
                SHStatusPill(state.0, label: state.1).fixedSize()
            }
            .padding(SH.Space.l)
            SHHairline()
            VStack(alignment: .leading, spacing: SH.Space.l) {
                ForEach(Array(car.steps.enumerated()), id: \.offset) { _, step in
                    MissionTrainStepRow(step: step, soakMinutes: soakMinutes)
                }
                if let soak = car.steps.first(where: { $0.kind == .soak && $0.note != nil }), let note = soak.note {
                    Text(note).shText(.micro).foregroundStyle(Color.sh.textSecondary)
                        .padding(SH.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                        .textSelection(.enabled)
                }
            }
            .padding(SH.Space.l)
        }
        .frame(width: AppLayout.missionTrainCardWidth, alignment: .leading)
        .foregroundStyle(waiting ? Color.sh.textTertiary : Color.sh.textPrimary)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .overlay {
            RoundedRectangle(cornerRadius: SH.Radius.m)
                .strokeBorder(current ? Color.sh.running : Color.sh.lineSubtle, lineWidth: current ? AppLayout.missionSelectedBorder : 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(index + 1), \(name), \(state.1)")
    }
}

private struct MissionTrainStepRow: View {
    let step: MissionTrain.Step
    let soakMinutes: Int

    private var label: String {
        let done = [.done, .fixed].contains(step.status)
        switch step.kind {
        case .update: return done ? "Updated from main" : step.status == .failed ? "Update from main" : "Update from main"
        case .ci: return done ? "CI green" : "CI"
        case .merge: return done ? "Merged" : "Merge"
        case .staging: return done ? "Deployed to staging" : "Deploy to staging"
        case .soak: return "Soak \(soakMinutes)m"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: SH.Space.m) {
            glyph.frame(width: SH.Space.l, height: AppLayout.missionTrainStepLine)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(label).shText(.ui).fontWeight(.regular)
                    .foregroundStyle(step.status == .pending ? Color.sh.textTertiary : Color.sh.textPrimary)
                if step.status == .failed, let note = step.note, step.kind != .soak {
                    Text(note).shText(.caption).foregroundStyle(Color.sh.textTertiary).lineLimit(2)
                }
            }
            Spacer(minLength: SH.Space.s)
            trailing.frame(height: AppLayout.missionTrainStepLine)
        }
    }

    @ViewBuilder private var glyph: some View {
        switch step.status {
        case .done: Image(systemName: "checkmark").font(.sh(.caption, weight: .semibold)).foregroundStyle(Color.sh.done)
        case .fixed: Image(systemName: "checkmark").font(.sh(.caption, weight: .semibold)).foregroundStyle(Color.sh.lanternText)
        case .failed: Image(systemName: "xmark").font(.sh(.caption, weight: .semibold)).foregroundStyle(Color.sh.failed)
        case .running: ProgressView().progressViewStyle(.shSpinner(size: 12))
        case .skipped: Image(systemName: "arrow.right").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
        case .pending: Image(systemName: "circle").font(.sh(.micro)).foregroundStyle(Color.sh.textTertiary)
        }
    }

    @ViewBuilder private var trailing: some View {
        if step.status == .fixed {
            Text("auto").shText(.micro).foregroundStyle(Color.sh.lanternText)
        } else if step.status == .running, step.kind == .soak, let at = step.at {
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                let left = max(0, Double(soakMinutes) * 60 - (clock.date.timeIntervalSince1970 - at))
                Text("\(MissionFormat.duration(left)) left").shText(.micro).foregroundStyle(Color.sh.textTertiary)
            }
        } else if let at = step.at, step.status != .pending {
            Text(Date(timeIntervalSince1970: at).formatted(date: .omitted, time: .shortened)).shText(.micro).foregroundStyle(Color.sh.textTertiary)
        }
    }
}

/// The train's inspector: what it is, its rules, its log, and Skip soak with Start, Pause or Resume.
private struct MissionTrainInspector: View {
    let mission: Mission
    let order: [SpaceID]
    @Binding var rules: MissionTrain.Rules
    let editable: Bool
    let busy: Bool
    let changed: (MissionTrain.Rules) -> Void
    let start: () -> Void
    let action: (MissionUIAction) -> Void

    private var train: MissionTrain? { mission.run?.train }

    var body: some View {
        VStack(spacing: 0) {
            MissionInspectorHead(symbol: SHGlyph.gitBranch.symbolName, title: "Merge train",
                                 tag: "\(train?.merged ?? 0) of \(order.count) merged", pill: nil, lane: nil,
                                 subtitle: train.map { "one PR at a time · started \(Date(timeIntervalSince1970: $0.startedAt).formatted(date: .omitted, time: .shortened))" }
                                    ?? "one PR at a time · not started",
                                 mono: false, close: nil) { EmptyView() }
            ScrollView {
                VStack(spacing: 0) {
                    MissionInspectorSection(title: "Rules", meta: "for this mission") {
                        rule("Between services", rules.between, [(.mergeOnly, "merge only"), (.soak, "\(rules.soakMinutes)m soak"), (.stagingSoak, "staging + \(rules.soakMinutes)m soak")]) { rules.between = $0 }
                        rule("Lockfile conflicts", rules.lockfiles, [(.fix, "fix automatically"), (.pause, "pause and ask")]) { rules.lockfiles = $0 }
                        MissionFactRow(label: "Code conflicts") { MissionChipLabel(symbol: "hand.raised", text: "pause and ask") }
                        rule("Red CI after merge", rules.redCI, [(.revertPause, "revert, then pause"), (.pause, "pause")]) { rules.redCI = $0 }
                        rule("Merge window", rules.window, [(.anyTime, "any time"), (.weekdays, "weekdays 9–4")]) { rules.window = $0 }
                        if rules.between != .mergeOnly {
                            ForEach(order, id: \.self) { lane in commands(lane) }
                        }
                    }
                    if let log = train?.log, !log.isEmpty {
                        MissionInspectorSection(title: "Log") {
                            ForEach(Array(log.enumerated()), id: \.offset) { _, entry in
                                HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                                    Text(Date(timeIntervalSince1970: entry.at).formatted(date: .omitted, time: .shortened)).shText(.micro).foregroundStyle(Color.sh.textTertiary)
                                    Text(entry.subject).font(.sh(.mono, weight: .semibold)).lineLimit(1)
                                    Image(systemName: "arrow.right").font(.sh(.micro)).foregroundStyle(Color.sh.textTertiary)
                                    Text(entry.text).shText(.ui).fontWeight(.regular).lineLimit(1)
                                    Spacer(minLength: SH.Space.m)
                                    Text(entry.by).shText(.micro).foregroundStyle(Color.sh.textTertiary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
            SHHairline()
            HStack(spacing: SH.Space.l) {
                let soaking = train.flatMap { train in train.current.map { train.cars[$0].steps.contains { $0.kind == .soak && $0.status == .running } } } ?? false
                Button("Skip soak") { action(.skipSoak) }.buttonStyle(.sh(.ghost)).disabled(busy || !soaking)
                Spacer()
                switch train?.status {
                case nil:
                    Button(action: start) { Label("Start train", systemImage: "play.fill") }
                        .buttonStyle(.sh(.primary)).disabled(busy || order.isEmpty)
                        .shHelp("Merge these pull requests one at a time, in this order, under these rules")
                case .running?:
                    Button { action(.pauseTrain) } label: { Label("Pause train", systemImage: "pause.fill") }.buttonStyle(.sh(.secondary)).disabled(busy)
                case .paused?:
                    Button { action(.resumeTrain) } label: { Label("Resume train", systemImage: "play.fill") }.buttonStyle(.sh(.primary)).disabled(busy)
                case .done?:
                    EmptyView()
                }
            }
            .padding(.horizontal, SH.Space.xl).frame(height: SHPageMetrics.headerHeight)
        }
        .background(Color.sh.bgWindow)
    }

    private func rule<Value: Hashable>(_ label: String, _ value: Value, _ options: [(Value, String)], set: @escaping (Value) -> Void) -> some View {
        MissionFactRow(label: label) {
            Menu {
                ForEach(options, id: \.0) { option in
                    Toggle(option.1, isOn: Binding(get: { value == option.0 }, set: { if $0 { set(option.0); changed(rules) } }))
                }
            } label: { MissionChipLabel(symbol: "slider.horizontal.3", text: options.first { $0.0 == value }?.1 ?? "", accessibility: "\(label), \(options.first { $0.0 == value }?.1 ?? "")") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .disabled(!editable || busy)
                .accessibilityLabel(label).help(label)
        }
    }

    /// Each repository's staging deploy and soak health commands, run in its mission worktree.
    @ViewBuilder private func commands(_ lane: SpaceID) -> some View {
        let name = mission.lane(lane)?.name ?? "repository"
        VStack(alignment: .leading, spacing: SH.Space.s) {
            Text(name).font(.sh(.mono, weight: .semibold))
            if rules.between == .stagingSoak {
                field("Staging deploy", name, Binding(get: { rules.staging[lane] ?? "" }, set: { rules.staging[lane] = $0.isEmpty ? nil : $0 }))
            }
            field("Health check after the soak (optional)", name, Binding(get: { rules.health[lane] ?? "" }, set: { rules.health[lane] = $0.isEmpty ? nil : $0 }))
        }
        .padding(.top, SH.Space.s)
    }

    private func field(_ title: String, _ name: String, _ text: Binding<String>) -> some View {
        TextField(title, text: text, prompt: Text(title))
            .textFieldStyle(.plain).shText(.mono)
            .padding(.horizontal, SH.Space.m).frame(height: SH.Height.controlM)
            .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .shBorder(Color.sh.lineStrong, radius: SH.Radius.s)
            .disabled(!editable || busy)
            .onSubmit { changed(rules) }
            .accessibilityLabel("\(title) for \(name)")
    }
}
