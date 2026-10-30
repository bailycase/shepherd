import SwiftUI
import ShepherdCore
import ShepherdUI

/// The only controller-reading layer. The individual surfaces render immutable mission receipts.
/// `controller` is This Mac's `MissionController` or a host's `RemoteMissionDriver`.
struct MissionsDestination<Driver: MissionDriving>: View {
    @Bindable var controller: Driver
    var chrome = PageHeaderChrome()
    @State private var creating = false
    @State private var busy = false
    @Environment(\.missionInitialPanes) private var seed

    private var selected: Mission? { controller.records.first { $0.id == controller.selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            if creating {
                MissionStartView(spaces: controller.availableSpaces, models: controller.availableModels,
                                 defaultModel: controller.defaultModel, branchChoices: controller.branchChoices,
                                 defaultBranches: controller.defaultBranches, busy: busy, chrome: chrome,
                                 goal: seed.startGoal, selected: seed.startSpaces,
                                 cancel: { creating = false }) { goal, spaces, model, branches in
                    perform {
                        let id = try await controller.create(goal: goal, spaces: spaces, model: model, branches: branches)
                        controller.selectedID = id
                        creating = false
                    }
                }
            } else if let selected {
                MissionWorkspace(mission: selected, output: controller.liveOutput[selected.id] ?? "",
                                 attemptOutput: controller.attemptOutput,
                                 specKitReports: controller.specKitReports[selected.id] ?? [:],
                                 reviews: controller.reviews[selected.id] ?? [], models: controller.availableModels,
                                 viewed: Binding(get: { controller.viewed[selected.id] ?? [] }, set: { controller.viewed[selected.id] = $0 }),
                                 busy: busy, chrome: chrome,
                                 back: { controller.selectedID = nil }, openThread: controller.openThread,
                                 threads: MissionThreads(source: { controller.thread(for: $0) }, report: { controller.error = $0 },
                                                         isLive: { controller.isLive($0) }),
                                 send: { action in await submit(action, mission: selected).value },
                                 action: { action in submit(action, mission: selected) })
                    .id(selected.id)
            } else {
                MissionsPage(records: controller.records, chrome: chrome,
                             select: { controller.selectedID = $0 }, create: { creating = true })
            }
        }
        .overlay(alignment: .bottom) {
            if let error = controller.error {
                MissionErrorBanner(message: error) { controller.error = nil }
                    .padding(SH.Space.xl)
            }
        }
        .background(Color.sh.bgWindow)
        .foregroundStyle(Color.sh.textPrimary)
        .task { await controller.refreshModels() }
        .task(id: controller.selectedID) { if let id = controller.selectedID { await controller.opened(id) } }
        .onAppear { if seed.creating { creating = true }; takeStartRequest() }
        // The sidebar's New mission.
        .onChange(of: controller.startRequested) { _, _ in takeStartRequest() }
    }

    /// Claims the one-operation slot NOW, on the press, so the page disables its controls in the same
    /// update; the work then runs in a task. A press while another operation holds the slot does
    /// nothing (its control is already disabled). A failure lands in the banner; the task's value is
    /// true only when the operation finished, so composers keep the person's words otherwise.
    /// `clearsError`: a person's action replaces the banner; the page's own refresh never hides one
    /// (a refused steer's reason must outlive the refresh a phase change starts).
    private func start(clearsError: Bool = true, _ operation: @escaping @MainActor () async throws -> Void) -> Task<Bool, Never> {
        guard !busy else { return Task { false } }
        busy = true
        if clearsError { controller.error = nil }
        return Task { @MainActor in
            defer { busy = false }
            do { try await operation(); return true }
            catch { controller.error = String(describing: error); return false }
        }
    }

    private func takeStartRequest() {
        guard controller.startRequested else { return }
        controller.startRequested = false
        creating = true
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        _ = start(operation)
    }

    /// Everything before the work is synchronous with the press: the displayed revision, the
    /// publication guard and the slot.
    @discardableResult
    private func submit(_ action: MissionUIAction, mission: Mission) -> Task<Bool, Never> {
        // All approvals capture the displayed revision before any suspension, never reread it after an await.
        let id = mission.id, revision = mission.revision
        // Publication can await repository/network work. Stop must not wait for that UI task.
        if case .stop = action {
            return Task { @MainActor in
                do { try await controller.perform(action, id: id, revision: revision); return true }
                catch { controller.error = String(describing: error); return false }
            }
        }
        if controller.records.first(where: { $0.id == id })?.run?.publicationApproval != nil {
            switch action {
            case .plan, .answer, .save, .launch, .revalidate, .changes, .specKitConsent, .specKitSetUp, .acceptConvergence:
                controller.error = "Publication was already authorized. These receipts cannot be reused for new work."
                return Task { false }
            default: break
            }
        }
        let automatic: Bool = if case .refresh = action { true } else { false }
        return start(clearsError: !automatic) {
            if case .save(_, let editedRevision) = action, controller.records.first(where: { $0.id == id })?.revision != editedRevision {
                throw MissionError("stale_mission", "This mission changed while you were editing. Reopen the editor to use the current draft.")
            }
            try await controller.perform(action, id: id, revision: revision)
        }
    }
}

/// A station's own thread for Run, from the controller: its source (nil when the agent is gone)
/// and where a refused steer is reported. Steering goes only through the source's `send`.
struct MissionThreads {
    var source: (UUID) -> MissionThreadSource? = { _ in nil }
    var report: (String) -> Void = { _ in }
    /// The agent is in the app's state, so its thread store is the one the app keeps. Until then any
    /// store made for it is pruned and stopped with the next state change (`NativeThreadStores.prune`).
    var isLive: (AgentID) -> Bool = { _ in false }
}

/// Where mission pages first open: the New mission page, the narrow toggles' side pane, the
/// map's wires, and Review's drafts and open contract item. Previews and tests set it to show
/// those states in the real shell; the app never does, so every page opens on its default.
struct MissionInitialPanes: Equatable {
    var creating = false
    var startGoal = ""
    var startSpaces: [SpaceID] = []
    var side = false
    var wires: MissionWireFilter?
    var comments: [MissionReviewComment] = []
    var openContractItem: Int?
}

extension EnvironmentValues {
    @Entry var missionInitialPanes = MissionInitialPanes()
    /// The host whose missions the page shows: This Mac, or a connected host's name.
    @Entry var missionHostName = "This Mac"
}

enum MissionUIAction {
    case plan(String), answer(String, choice: String?, replyTo: UUID?)
    /// Stock Spec Kit, behind the planner: the owner's grant for one repository's files as read (and,
    /// said on the button, whether planning continues), and acceptance of a completion report.
    case specKitConsent(SpaceID, String, continuePlanning: Bool), acceptConvergence(UUID)
    /// Stock `specify init` / `specify integration install pi` in that repository's mission worktree.
    case specKitSetUp(SpaceID)
    case save(MissionDraft, UInt64), launch, pause, stop, changes(String)
    case publish(MissionPublishApproval), refresh, revalidate, runAgain
}

struct MissionPublishApproval: Equatable {
    let id: MissionID
    let revision: UInt64
    let fingerprint: String
}

/// A failed operation's message, floated over the page until dismissed (it says how to recover).
private struct MissionErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: SH.Space.l) {
            SHStateGlyph(.failed)
            Text(message).shText(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: dismiss).buttonStyle(.sh(.ghost, size: .s))
        }
        .padding(SH.Space.l)
        .frame(maxWidth: AppLayout.missionStartWidth)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(Color.sh.failed, radius: SH.Radius.m)
        .shPopover()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: Shared presentation

extension MissionRun.Phase {
    var missionLabel: String {
        switch self {
        case .planning: "Planning"
        case .map: "Draft"
        case .running: "Running"
        case .paused: "Paused"
        case .review: "Review · needs you"
        case .publishing: "Publishing PRs"
        case .done: "PRs published"
        case .stopped: "Stopped"
        }
    }
    var missionState: AgentState {
        switch self {
        case .planning, .running, .publishing: .running
        case .paused, .review: .attention
        case .done: .done
        case .map, .stopped: .idle
        }
    }
}

extension Mission {
    var phase: MissionRun.Phase { run?.phase ?? .map }
    /// The list's pill: a pending question is the board's "Needs you".
    var pill: (state: AgentState, label: String) {
        if run?.pendingQuestion != nil, phase == .map { return (.attention, "Needs you") }
        // A completion report waits for your acceptance (or appended tasks for approval): that is not a draft.
        if phase == .map, run?.specKit?.lanes.contains(where: { $0.convergence?.accepted == false }) == true { return (.attention, "Needs you") }
        return (phase.missionState, phase.missionLabel)
    }
    var stationAttempts: [MissionAttempt] { run?.attempts.filter { $0.stationID != nil } ?? [] }
    func lane(_ id: SpaceID?) -> MissionLane? { id.flatMap { id in draft.plan?.lanes.first { $0.spaceID == id } } }
    /// The planner's latest words, the closest thing to its summary.
    var plannerSummary: String? { run?.messages.last { $0.role == .assistant }?.text }
}

extension MissionAttempt.Status {
    var missionState: AgentState {
        switch self {
        case .running: .running
        case .succeeded: .done
        case .failed: .failed
        case .interrupted: .attention
        case .superseded: .queued
        }
    }
}

extension MissionStation.Kind {
    var symbol: String {
        switch self {
        case .research: "magnifyingglass"
        case .worker: "sparkle"
        case .check: "terminal"
        case .decision: "questionmark.circle"
        case .validator: "checkmark.shield"
        }
    }
    var word: String {
        switch self {
        case .research: "research"
        case .worker: "worker"
        case .check: "check"
        case .decision: "you"
        case .validator: "validator"
        }
    }
}

enum MissionFormat {
    /// "2.3M", "900k", "—" for nothing yet.
    static func tokens(_ value: Int, dash: Bool = false) -> String {
        if dash && value == 0 { return "—" }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))).replacingOccurrences(of: "K", with: "k")
    }
    /// "38m", "1h12", "4h".
    static func duration(_ seconds: Double, dash: Bool = false) -> String {
        if dash && seconds < 1 { return "—" }
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 60 { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h" + String(format: "%02d", rest)
    }
    /// "#318" from a pull request URL.
    static func pullNumber(_ url: String?) -> String? {
        guard let url, let last = url.split(separator: "/").last, Int(last) != nil else { return nil }
        return "#\(last)"
    }
}

/// The host chip every mission header ends with: the Mac the mission runs on.
struct MissionHostChip: View {
    @Environment(\.missionHostName) private var host
    var body: some View {
        HStack(spacing: SH.Space.s) {
            Image(systemName: "desktopcomputer").font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
            Text(host).shText(.mono)
            SHStatusDot(.done)
        }
        .padding(.horizontal, SH.Space.m)
        .frame(height: SH.Height.controlM)
        .shBorder(Color.sh.lineStrong, radius: SH.Radius.s)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Runs on \(host)")
    }
}

/// A repository chip (NavMissions' lanes, the map's inspector).
struct MissionLaneChip: View {
    let name: String
    var body: some View {
        HStack(spacing: SH.Space.xs) {
            SHGlyph.repository.image.font(.shSans(AppLayout.missionChipGlyph)).foregroundStyle(Color.sh.textTertiary)
            Text(name).shText(.micro).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, SH.Space.s)
        .frame(height: AppLayout.missionChipHeight)
        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Repository \(name)")
    }
}

// MARK: List (NavMissions)

enum MissionListFilter: String, CaseIterable {
    case all = "All", needsYou = "Needs you", running = "Running", drafts = "Drafts", done = "Done"
    func includes(_ mission: Mission) -> Bool {
        let phase = mission.phase
        switch self {
        case .all: return true
        case .needsYou: return phase == .paused || phase == .review || mission.run?.pendingQuestion != nil
        case .running: return phase.active
        case .drafts: return phase == .map
        case .done: return phase == .done || phase == .stopped
        }
    }
}

struct MissionsPage: View {
    let records: [Mission]
    var chrome = PageHeaderChrome()
    let select: (MissionID) -> Void
    let create: () -> Void
    @State private var filter = ""
    @State private var category = MissionListFilter.all
    /// A narrow window drops the secondary Lanes and Host columns so names keep their room.
    @State private var narrow = false
    @Environment(\.missionHostName) private var host
    private var columns: [SHTableColumns.Column] { narrow ? AppLayout.missionNarrowColumns : AppLayout.missionColumns }

    private var rows: [Mission] {
        records.filter { category.includes($0) && (filter.isEmpty || $0.draft.title.localizedStandardContains(filter) || $0.draft.goal.localizedStandardContains(filter)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            DestinationPageHeader(title: host == EnvironmentValues().missionHostName ? "Missions" : "Missions on \(host)", chrome: chrome) {
                // With no missions the empty state carries the one New mission.
                if !records.isEmpty {
                    SHPageFilterField("Filter missions", text: $filter)
                    Button(action: create) { Label("New mission", systemImage: "plus") }
                        .buttonStyle(.sh(.primary))
                }
            }
            if records.isEmpty {
                SHEmptyState(Text("Give your agents a destination"),
                             message: "Describe an end state across your repositories. The planner drafts a map you approve, independent validation checks the work, and you publish the pull requests.") {
                    Button(action: create) { Label("New mission", systemImage: "plus") }.buttonStyle(.sh(.primary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MissionStateTabs(records: records, selection: $category)
                SHTableHead(narrow ? ["Mission", "Route", "Spend"] : ["Mission", "Lanes", "Route", "Spend", "Host"], columns: columns)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { mission in
                            MissionListRow(mission: mission, narrow: narrow) { select(mission.id) }
                        }
                        if rows.isEmpty {
                            VStack(spacing: SH.Space.m) {
                                Text("No \(category.rawValue.lowercased()) missions\(filter.isEmpty ? "" : " match “\(filter)”")").shText(.headline)
                                Button("Show all missions") { category = .all; filter = "" }.buttonStyle(.sh(.secondary))
                            }.padding(SH.Space.xxxl)
                        }
                    }
                }
            }
        }
        .background(Color.sh.bgWindow)
        .onGeometryChange(for: Bool.self) { $0.size.width < AppLayout.missionNarrowWidth } action: { narrow = $0 }
    }
}

/// The state tabs (pages.md › State tabs): label in 12.5 and a mono count.
private struct MissionStateTabs: View {
    let records: [Mission]
    @Binding var selection: MissionListFilter
    var body: some View {
        HStack(spacing: SH.Space.xxs) {
            ForEach(MissionListFilter.allCases, id: \.self) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    HStack(spacing: SH.Space.s) {
                        Text(tab.rawValue).font(.sh(.ui, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.sh.textPrimary : Color.sh.textSecondary)
                        Text("\(records.filter(tab.includes).count)").shText(.micro).foregroundStyle(Color.sh.textTertiary)
                    }
                    .padding(.horizontal, AppLayout.missionTabPadding)
                    .frame(height: AppLayout.missionTabHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.shRow(selected: selected))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, SHPageMetrics.sideInset)
        .padding(.top, SH.Space.xl).padding(.bottom, SH.Space.l)
    }
}

private struct MissionListRow: View {
    let mission: Mission
    let narrow: Bool
    let select: () -> Void
    @Environment(\.missionHostName) private var host
    private var plan: MissionPlan? { mission.draft.plan }
    private var route: [AgentState?] {
        (plan?.stations ?? []).map { station -> AgentState? in
            if station.kind == .decision && mission.latest(station.id) == nil { return .attention }
            guard let attempt = mission.latest(station.id), attempt.status != .superseded else { return nil }
            return attempt.status.missionState
        }
    }
    private var completed: Int { route.filter { $0 == .done }.count }
    private var needsYou: Bool { mission.pill.state == .attention }

    /// The line under the name: the question while it needs you, else what it is doing or how it ended.
    private var detail: String {
        if let question = mission.run?.pendingQuestion { return question }
        let elapsed = MissionFormat.duration(mission.run?.elapsed(at: Date().timeIntervalSince1970) ?? 0)
        switch mission.phase {
        case .planning: return "planner reading \(plan?.lanes.count ?? 0) repos · \(elapsed)"
        case .running:
            let active = mission.stationAttempts.filter { $0.status == .running }.compactMap { attempt in plan?.stations.first { $0.id == attempt.stationID } }
            return (active.map { $0.command ?? $0.title } + [elapsed]).joined(separator: " · ")
        case .map: return plan?.stations.isEmpty == false ? "map drafted · \(plan?.stations.count ?? 0) stations" : "planning"
        case .done:
            let count = mission.run?.checkouts.filter { $0.prURL != nil }.count ?? 0
            return "\(count) PR\(count == 1 ? "" : "s") published · \(elapsed)"
        case .review: return "validated · approve to publish"
        default: return mission.run?.notice ?? mission.draft.goal
        }
    }

    var body: some View {
        Button(action: select) {
            SHTableColumns(narrow ? AppLayout.missionNarrowColumns : AppLayout.missionColumns) {
                HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                    SHGlyph.mission.image.font(.shSans(AppLayout.missionGlyph))
                        .foregroundStyle(needsYou ? Color.sh.lanternText : Color.sh.textSecondary)
                    VStack(alignment: .leading, spacing: SH.Space.s) {
                        // The pill drops under the name before the name gives up its room.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: SH.Space.m) {
                                Text(mission.draft.title).shText(.headline).lineLimit(1).fixedSize()
                                SHStatusPill(mission.pill.state, label: mission.pill.label).fixedSize()
                            }
                            VStack(alignment: .leading, spacing: SH.Space.xs) {
                                Text(mission.draft.title).shText(.headline).lineLimit(1)
                                SHStatusPill(mission.pill.state, label: mission.pill.label).fixedSize()
                            }
                        }
                        Text(detail).shText(.ui).fontWeight(.regular).lineLimit(1)
                            .foregroundStyle(mission.run?.pendingQuestion != nil ? Color.sh.lanternText : Color.sh.textTertiary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !narrow {
                    SHFlowLayout(spacing: SH.Space.xs) {
                        ForEach(plan?.lanes ?? []) { MissionLaneChip(name: $0.name) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: SH.Space.s) {
                    SHStepStrip(route.isEmpty ? [nil] : route)
                        .frame(width: AppLayout.missionRouteWidth)
                    Text("\(completed) of \(route.count) stations").shText(.micro).foregroundStyle(Color.sh.textTertiary)
                }
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    let limits = mission.draft.limits
                    Text("\(MissionFormat.tokens(mission.run?.tokens ?? 0, dash: true)) / \(MissionFormat.tokens(limits.tokens)) tok")
                        .shText(.mono).foregroundStyle(Color.sh.textSecondary)
                    Text("\(MissionFormat.duration(mission.run?.elapsedSeconds ?? 0, dash: true)) / \(MissionFormat.duration(limits.seconds))")
                        .shText(.mono).foregroundStyle(Color.sh.textTertiary)
                }
                if !narrow { Text(host).shText(.mono).foregroundStyle(Color.sh.textSecondary) }
            }
            .padding(.horizontal, SHPageMetrics.sideInset).padding(.vertical, SH.Space.l + SH.Space.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.shRow(radius: 0))
        // NavMissions lifts the rows that wait on you.
        .background(needsYou ? Color.sh.bgRaised : Color.clear)
        .overlay(alignment: .top) { SHHairline() }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the mission")
    }
}

// MARK: Start (MXStart)

struct MissionStartView: View {
    let spaces: [Space]
    let models: [String]
    let defaultModel: String?
    let branchChoices: [SpaceID: [String]]
    let defaultBranches: [SpaceID: String]
    let busy: Bool
    var chrome = PageHeaderChrome()
    let cancel: () -> Void
    let create: (String, [SpaceID], String, [SpaceID: String]) -> Void
    @State private var goal = ""
    @State private var selectedSpaces: [SpaceID] = []
    @State private var selectedBranches: [SpaceID: String] = [:]
    @State private var model = ""
    @FocusState private var focused: Bool

    init(spaces: [Space], models: [String], defaultModel: String?, branchChoices: [SpaceID: [String]], defaultBranches: [SpaceID: String],
         busy: Bool, chrome: PageHeaderChrome = PageHeaderChrome(), goal: String = "", selected: [SpaceID] = [],
         cancel: @escaping () -> Void, create: @escaping (String, [SpaceID], String, [SpaceID: String]) -> Void) {
        self.spaces = spaces; self.models = models; self.defaultModel = defaultModel
        self.branchChoices = branchChoices; self.defaultBranches = defaultBranches
        self.busy = busy; self.chrome = chrome; self.cancel = cancel; self.create = create
        // A restored or previewed draft: its words and chosen repositories.
        _goal = State(initialValue: goal); _selectedSpaces = State(initialValue: selected)
    }

    private var trimmed: String { goal.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var blocker: String? {
        if spaces.isEmpty { return "Add a Git repository as a Space to plan a mission." }
        if selectedSpaces.isEmpty { return "Choose at least one repository." }
        if !MissionBranchSelection.ready(selected: Set(selectedSpaces), choices: branchChoices, selections: selectedBranches) { return "Choose a starting branch for each repository." }
        if model.isEmpty { return "Choose a model in Settings ▸ Agents." }
        if trimmed.isEmpty { return "Describe where you want to end up." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            MissionHeader(title: "New mission", pill: (.idle, "New"), steps: MissionSteps(current: .goal, reached: 0, available: [.goal]),
                          chrome: chrome, back: cancel, select: { _ in }) { compact in
                if !compact { MissionHostChip() }
            }
            ScrollView {
                VStack(spacing: SH.Space.xxl) {
                    VStack(spacing: SH.Space.l) {
                        Text("Where do you want to end up?").shText(.display).accessibilityAddTraits(.isHeader)
                        Text("Describe the end state, like you would to any agent. The planner reads the repositories you pick, finds the context and the checks, and only asks what it can't work out.")
                            .shText(.body).foregroundStyle(Color.sh.textSecondary).multilineTextAlignment(.center)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ZStack(alignment: .topLeading) {
                            if goal.isEmpty {
                                Text("Add checkout funnel analytics so product can see drop-off at every step…")
                                    .shText(.body).foregroundStyle(Color.sh.textTertiary)
                                    .padding(.horizontal, SH.Space.xs).accessibilityHidden(true)
                            }
                            TextEditor(text: $goal)
                                .focused($focused).shText(.body)
                                .scrollContentBackground(.hidden)
                                .accessibilityLabel("Mission goal")
                        }
                        .padding(.horizontal, SH.Space.l).padding(.top, SH.Space.l)
                        HStack(spacing: SH.Space.s) {
                            MissionRepositoryPicker(spaces: spaces, selected: $selectedSpaces, branchChoices: branchChoices, branches: $selectedBranches)
                            MissionModelChip(models: models, model: $model)
                            Spacer(minLength: SH.Space.m)
                            Button { submit() } label: { Image(systemName: busy ? "ellipsis" : "arrow.up") }
                                .buttonStyle(.shIcon(bordered: true, tint: blocker == nil ? Color.sh.lanternText : nil))
                                .disabled(busy || blocker != nil)
                                .keyboardShortcut(.return, modifiers: .command)
                                .shHelp(blocker ?? "Plan the mission", shortcut: "⌘↩")
                                .accessibilityLabel(busy ? "Starting planner" : "Plan the mission")
                        }.padding(SH.Space.m)
                    }
                    .frame(height: AppLayout.missionComposerHeight)
                    .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                    .shBorder(Color.sh.lineStrong, radius: SH.Radius.m)
                    // MXStart's neutral ring; textSecondary keeps it above 3:1 in both appearances.
                    .shFocusRing(focused, radius: SH.Radius.m, color: Color.sh.textSecondary)
                    MissionRepositoryToggles(spaces: spaces, selected: $selectedSpaces)
                    (Text(blocker.map { $0 + " " } ?? "").foregroundStyle(Color.sh.textSecondary)
                        + Text("Each repository gets a fresh worktree from the branch you pick; your checkouts are not edited. Context and code go to \(model.isEmpty ? "the selected model's provider" : model). Runs belong to this app: quitting stops active work."))
                        .shText(.caption).foregroundStyle(Color.sh.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: AppLayout.missionStartWidth)
                .padding(SH.Space.xxxl)
                .frame(maxWidth: .infinity, minHeight: AppLayout.missionStartWidth)
            }
        }
        .background(Color.sh.bgWindow)
        .onAppear { chooseDefaultModel(); chooseDefaultBranches(); focused = true }
        .onChange(of: spaces.map(\.id)) { _, ids in
            if selectedSpaces.isEmpty, ids.count == 1 { selectedSpaces = ids }
        }
        .onChange(of: branchChoices) { _, _ in chooseDefaultBranches() }
        .onChange(of: defaultBranches) { _, _ in chooseDefaultBranches() }
        .onChange(of: models) { _, _ in chooseDefaultModel() }
        .onChange(of: defaultModel) { _, _ in chooseDefaultModel() }
    }

    private func submit() {
        guard blocker == nil, !busy else { return }
        create(trimmed, selectedSpaces, model, selectedBranches.filter { selectedSpaces.contains($0.key) })
    }

    private func chooseDefaultBranches() {
        selectedBranches = MissionBranchSelection.applyingDefaults(defaultBranches, choices: branchChoices, to: selectedBranches)
        if selectedSpaces.isEmpty, spaces.count == 1 { selectedSpaces = spaces.map(\.id) }
    }

    private func chooseDefaultModel() {
        if model.isEmpty { model = defaultModel.flatMap { models.contains($0) ? $0 : nil } ?? models.first ?? "" }
    }
}

/// A composer chip that opens a menu: glyph, value and chevron.
struct MissionChipLabel: View {
    let symbol: String
    let text: String
    var attention = false
    var accessibility: String? = nil
    var body: some View {
        HStack(spacing: SH.Space.xs) {
            Image(systemName: symbol).font(.sh(.caption)).foregroundStyle(attention ? Color.sh.lanternText : Color.sh.textTertiary)
                .accessibilityHidden(true)
            Text(text).shText(.mono).foregroundStyle(attention ? Color.sh.lanternText : Color.sh.textSecondary).lineLimit(1)
            SHChipChevron()
        }
        .padding(.horizontal, SH.Space.m)
        .frame(height: SH.Height.controlS)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.s))
        .shBorder(attention ? Color.sh.lantern : Color.sh.lineStrong, radius: SH.Radius.s)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility ?? text)
    }
}

/// One chip per chosen repository ("checkout-svc @ main"), each choosing its branch or removing it.
private struct MissionRepositoryPicker: View {
    let spaces: [Space]
    @Binding var selected: [SpaceID]
    let branchChoices: [SpaceID: [String]]
    @Binding var branches: [SpaceID: String]

    var body: some View {
        ForEach(selected, id: \.self) { id in
            if let space = spaces.first(where: { $0.id == id }) {
                let branch = branches[id] ?? ""
                let unavailable = branch.isEmpty || branchChoices[id]?.contains(branch) != true
                Menu {
                    Section("Start from") {
                        ForEach(branchChoices[id] ?? [], id: \.self) { ref in
                            Toggle(MissionBranchSelection.label(ref), isOn: Binding(get: { branch == ref }, set: { if $0 { branches[id] = ref } }))
                        }
                    }
                    if branchChoices[id]?.isEmpty != false { Text("Loading branches…") }
                    Divider()
                    Button("Remove \(space.name)") { selected.removeAll { $0 == id } }
                } label: {
                    MissionChipLabel(symbol: SHGlyph.repository.symbolName,
                                     text: unavailable ? "\(space.name) @ choose branch" : "\(space.name) @ \(MissionBranchSelection.label(branch))",
                                     attention: unavailable,
                                     accessibility: "\(space.name), starting branch \(unavailable ? "not chosen" : MissionBranchSelection.label(branch))")
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                // A native menu button names itself by its tooltip.
                .accessibilityLabel("\(space.name), starting branch \(unavailable ? "not chosen" : MissionBranchSelection.label(branch))")
                .help("\(space.name), starting branch \(unavailable ? "not chosen" : MissionBranchSelection.label(branch))")
            }
        }
    }
}

/// Every repository you can plan in, as toggles under the composer. Only chosen ones are read.
private struct MissionRepositoryToggles: View {
    let spaces: [Space]
    @Binding var selected: [SpaceID]
    var body: some View {
        if !spaces.isEmpty {
            VStack(alignment: .leading, spacing: SH.Space.m) {
                SHPageSectionLabel("Repositories the planner may read")
                SHFlowLayout(spacing: SH.Space.s) {
                    ForEach(spaces) { space in
                        let on = selected.contains(space.id)
                        Button {
                            if on { selected.removeAll { $0 == space.id } } else { selected.append(space.id) }
                        } label: {
                            HStack(spacing: SH.Space.xs) {
                                Image(systemName: on ? "checkmark" : "plus").font(.sh(.micro, weight: .bold))
                                    .foregroundStyle(on ? Color.sh.done : Color.sh.textTertiary)
                                Text(space.name).shText(.mono).foregroundStyle(on ? Color.sh.textPrimary : Color.sh.textSecondary)
                            }
                            .padding(.horizontal, SH.Space.m).frame(height: SH.Height.controlS)
                            .background(on ? Color.sh.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                            .shBorder(on ? Color.sh.lineStrong : Color.sh.lineSubtle, radius: SH.Radius.s)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(space.path)
                        .accessibilityLabel(space.name)
                        .accessibilityValue(on ? "chosen" : "not chosen")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MissionModelChip: View {
    let models: [String]
    @Binding var model: String
    var body: some View {
        Menu {
            ForEach(models, id: \.self) { value in
                Toggle(value, isOn: Binding(get: { model == value }, set: { if $0 { model = value } }))
            }
        } label: {
            MissionChipLabel(symbol: "cpu", text: model.isEmpty ? "No model" : model, attention: model.isEmpty,
                             accessibility: "Model, \(model.isEmpty ? "none available" : model)")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(models.isEmpty)
        .accessibilityLabel("Model, \(model.isEmpty ? "none available" : model)")
        .help("Model, \(model.isEmpty ? "none available" : model)")
    }
}

/// Preserve full refs for launch; shortening is presentation only. Late catalog refreshes never
/// replace a person's choice, including a branch that disappeared and must be chosen again.
enum MissionBranchSelection {
    static func label(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }

    static func applyingDefaults(_ defaults: [SpaceID: String], choices: [SpaceID: [String]],
                                 to selections: [SpaceID: String]) -> [SpaceID: String] {
        var result = selections
        for (space, branch) in defaults where result[space] == nil && choices[space]?.contains(branch) == true {
            result[space] = branch
        }
        return result
    }

    static func ready(selected: Set<SpaceID>, choices: [SpaceID: [String]], selections: [SpaceID: String]) -> Bool {
        !selected.isEmpty && selected.allSatisfy { space in
            guard let branch = selections[space], !branch.isEmpty else { return false }
            return choices[space]?.contains(branch) == true
        }
    }
}

/// A labeled native editor, shared by the brief editor.
struct MissionTextEditor: View {
    let title: String
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            Text(title).shText(.ui)
            TextEditor(text: $text)
                .focused($focused).shText(.body)
                .scrollContentBackground(.hidden)
                .frame(height: AppLayout.missionEditorHeight)
                .padding(SH.Space.m)
                .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                .shBorder(Color.sh.lineStrong, radius: SH.Radius.m)
                .shFocusRing(focused, radius: SH.Radius.m)
                .accessibilityLabel(title)
        }
    }
}

