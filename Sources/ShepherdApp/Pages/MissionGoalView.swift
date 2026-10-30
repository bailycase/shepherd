import SwiftUI
import ShepherdCore
import ShepherdUI

/// One mission: the header, then Goal, Map, Run (with Review) or Done. Navigation within the
/// mission never touches the mounted agent layout deck.
struct MissionWorkspace: View {
    let mission: Mission
    let output: String
    /// Each running attempt's own live text, so parallel stations never share one transcript.
    var attemptOutput: [UUID: String] = [:]
    /// Each repository's Spec Kit files as last read (a Spec Kit mission only).
    var specKitReports: [SpaceID: SpecKitPreflight] = [:]
    let reviews: [MissionRepositoryReview]
    var models: [String] = []
    var viewed: Binding<Set<String>> = .constant([])
    let busy: Bool
    var chrome = PageHeaderChrome()
    let back: () -> Void
    let openThread: (AgentID) -> Void
    var threads = MissionThreads()
    /// The same actions, awaited: true only when the controller accepted it (composers clear on that).
    var send: (MissionUIAction) async -> Bool = { _ in false }
    let action: (MissionUIAction) -> Void
    @State private var page: MissionWorkspacePage?

    private var phase: MissionRun.Phase { mission.phase }
    private var displayed: MissionWorkspacePage { MissionWorkspacePage.resolve(mission: mission, preferred: page) }
    private var steps: MissionSteps {
        MissionSteps(current: displayed, reached: MissionWorkspacePage.reached(mission),
                     available: Set(MissionWorkspacePage.allCases.filter { $0.available(for: mission) }))
    }
    private var editable: Bool { mission.run?.publicationApproval == nil && [.map, .paused, .stopped].contains(phase) }

    var body: some View {
        VStack(spacing: 0) {
            MissionHeader(title: mission.draft.title, pill: mission.pill, steps: steps, chrome: chrome, back: back,
                          select: { page = $0 == .run && MissionWorkspacePage.review.available(for: mission) ? .review : $0 }) { compact in
                trailing(compact: compact)
            }
            if [.paused, .stopped].contains(phase), let notice = mission.run?.notice {
                HStack(spacing: SH.Space.m) {
                    SHStatusDot(phase.missionState)
                    Text(notice).shText(.ui).fontWeight(.regular).textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, SH.Space.xxl).padding(.vertical, SH.Space.m)
                .background(Color.sh.lanternTint)
                .overlay(alignment: .bottom) { SHHairline() }
            }
            Group {
                switch displayed {
                case .goal:
                    MissionGoalView(mission: mission, output: output, specKitReports: specKitReports, busy: busy, openThread: openThread, send: send, action: action,
                                    showMap: { page = .map })
                case .map, .done:
                    MissionMapPage(mission: mission, done: displayed == .done, models: models, reviews: reviews,
                                   busy: busy, editable: editable, openThread: openThread, action: action)
                case .run:
                    MissionRunPage(mission: mission, output: output, attemptOutput: attemptOutput, reviews: reviews, openThread: openThread,
                                   threads: threads)
                case .review:
                    MissionReviewView(mission: mission, repositories: reviews, viewed: viewed, busy: busy, openThread: openThread, action: action)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.sh.bgWindow)
        .onChange(of: phase) { _, _ in page = nil }
        .task(id: phase) {
            if phase == .review || ([.paused, .stopped, .done].contains(phase) && mission.run?.reviewFingerprint != nil) { action(.refresh) }
        }
    }

    /// The phase's one action, with the budget beside it.
    @ViewBuilder private func trailing(compact: Bool) -> some View {
        let limits = mission.draft.limits
        if !compact {
            if phase == .map || (phase == .planning && mission.stationAttempts.isEmpty) {
                Text("budget \(MissionFormat.tokens(limits.tokens)) tok · \(MissionFormat.duration(limits.seconds))")
                    .shText(.mono).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
            } else {
                MissionMeters(mission: mission)
            }
            MissionHostChip()
        }
        if let stop = stopLabel {
            Menu {
                Button(stop, role: .destructive) { action(.stop) }
                if let planner = mission.run?.plannerID { Button("Open planner thread") { openThread(planner) } }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).buttonStyle(.shIcon).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More mission actions").help("More mission actions")
        }
        switch phase {
        case .planning, .running:
            Button { action(.pause) } label: { Label("Pause", systemImage: "pause.fill") }
                .buttonStyle(.sh(.secondary)).disabled(busy || mission.run?.publicationApproval != nil)
        case .map, .paused, .stopped:
            let needsPlan = mission.draft.plan?.stations.isEmpty != false || (phase != .map && mission.approvedPlanRevision == nil && mission.stationAttempts.isEmpty)
            let blocked = mission.run?.pendingQuestion != nil
            // Goal's own footer drafts the map; the header launches only a map you can approve.
            // Stock Spec Kit: only after every repository's grant and specify → plan → tasks; a finished
            // converge report waits for the owner's explicit acceptance instead.
            let specKitBlocked = mission.specKit != nil && (!mission.specKitConsented || mission.specKitNext != nil)
            if mission.run?.publicationApproval == nil, !blocked, let pending = mission.specKitAwaitingAcceptance {
                Button { action(.acceptConvergence(pending.attempt)) } label: {
                    Label("Accept \(pending.lane)'s completion report", systemImage: "checkmark")
                }
                .buttonStyle(.sh(.primary)).disabled(busy)
                .shHelp("You read the /speckit.converge report and accept it. An acknowledgement, not test evidence; work continues once no other report waits for you.")
            } else if mission.run?.publicationApproval == nil && !blocked && !specKitBlocked && !(phase == .map && needsPlan) {
                Button { action(needsPlan ? .plan("") : .launch) } label: {
                    Label(needsPlan ? "Resume planning" : phase == .map ? "Launch" : "Resume", systemImage: needsPlan ? SHGlyph.mission.symbolName : "play.fill")
                }
                .buttonStyle(.sh(.primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(busy)
                .shHelp(needsPlan ? "Continue planning" : mission.specKit != nil
                        ? "Approve each repository's spec, plan and tasks as they are now, then run /speckit.implement and /speckit.converge"
                        : "Approve this map and start work", shortcut: "⌘↩")
            }
        default: EmptyView()
        }
    }

    private var stopLabel: String? {
        switch phase {
        case .planning: "Stop planning"
        case .running, .paused: "Stop mission"
        case .publishing: "Stop publishing"
        default: nil
        }
    }
}

/// Tokens and time against their limits, each over a 2pt bar (MXRun's header).
struct MissionMeters: View {
    let mission: Mission
    var body: some View {
        TimelineView(.periodic(from: .now, by: AppLayout.missionBudgetRefresh)) { clock in
            let limits = mission.draft.limits
            let tokens = mission.run?.tokens ?? 0
            let elapsed = mission.run?.elapsed(at: clock.date.timeIntervalSince1970) ?? 0
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SH.Space.xl) {
                    meter("tokens", "\(MissionFormat.tokens(tokens)) / \(MissionFormat.tokens(limits.tokens))", Double(tokens) / Double(limits.tokens))
                    meter("time", "\(MissionFormat.duration(elapsed)) / \(MissionFormat.duration(limits.seconds))", elapsed / limits.seconds)
                }
                EmptyView()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(MissionFormat.tokens(tokens)) of \(MissionFormat.tokens(limits.tokens)) tokens, \(MissionFormat.duration(elapsed)) of \(MissionFormat.duration(limits.seconds))")
        }
    }

    private func meter(_ label: String, _ value: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.xxs) {
            HStack(spacing: SH.Space.s) {
                Text(label).shText(.micro).foregroundStyle(Color.sh.textTertiary)
                Text(value).shText(.micro).foregroundStyle(Color.sh.textSecondary)
            }.lineLimit(1).fixedSize()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.sh.lineSubtle)
                    Capsule().fill(mission.phase == .done ? Color.sh.done : fraction >= 1 ? Color.sh.failed : Color.sh.running)
                        .frame(width: geometry.size.width * min(1, max(0, fraction)))
                }
            }.frame(width: AppLayout.missionMeterWidth, height: AppLayout.missionMeterBar)
        }
    }
}

// MARK: Header and steps

struct MissionSteps: Equatable {
    let current: MissionWorkspacePage
    /// The furthest step the mission has reached: 0 Goal … 3 Done.
    let reached: Int
    let available: Set<MissionWorkspacePage>
}

/// The mission header (MXStart…MXReview): the breadcrumb with its pill, Goal › Map › Run › Done
/// in the middle, and the phase's controls.
struct MissionHeader<Trailing: View>: View {
    let title: String
    let pill: (state: AgentState, label: String)
    let steps: MissionSteps
    let chrome: PageHeaderChrome
    let back: () -> Void
    let select: (MissionWorkspacePage) -> Void
    @ViewBuilder let trailing: (_ compact: Bool) -> Trailing

    var body: some View {
        // A narrow window drops the meters, the host and the step names before anything clips.
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
        .padding(.leading, SH.Space.xl + chrome.leadingInset)
        .padding(.trailing, SHPageMetrics.headerTrailing)
        .frame(height: SHPageMetrics.headerHeight)
        .frame(maxWidth: .infinity)
        .background(Color.sh.bgWindow)
        .overlay(alignment: .bottom) { SHHairline() }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: SHPageMetrics.headerSpacing) {
            HStack(spacing: SH.Space.m) {
                if let sidebar = chrome.showSidebar {
                    Button(action: sidebar) { Image(systemName: "sidebar.left") }
                        .buttonStyle(.shIcon)
                        .shHelp("Show sidebar", shortcut: KeybindingsStore.shared.display(.toggleSidebar))
                        .accessibilityLabel("Show sidebar")
                }
                Button(action: back) {
                    HStack(spacing: SH.Space.s) {
                        SHGlyph.mission.image
                        if !compact { Text("Missions") }
                    }
                }
                .buttonStyle(.shLink(color: Color.sh.textTertiary, font: .sh(.ui, weight: .regular)))
                .accessibilityLabel("All missions")
                Text("/").shText(.ui).foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
                Text(title).shText(.headline).lineLimit(1).truncationMode(.tail)
                    .fixedSize(horizontal: !compact, vertical: false)
                    .accessibilityAddTraits(.isHeader)
                SHStatusPill(pill.state, label: pill.label)
            }
            Spacer(minLength: SH.Space.m)
            MissionStepBar(steps: steps, compact: compact, select: select)
            Spacer(minLength: SH.Space.m)
            HStack(spacing: SH.Space.m) { trailing(compact) }.fixedSize()
        }
    }
}

private struct MissionStepBar: View {
    let steps: MissionSteps
    var compact = false
    let select: (MissionWorkspacePage) -> Void
    private let items: [(MissionWorkspacePage, String)] = [(.goal, "Goal"), (.map, "Map"), (.run, "Run"), (.done, "Done")]

    var body: some View {
        HStack(spacing: SH.Space.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.sh(.micro)).foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
                }
                let page = item.0
                let current = steps.current == page || (page == .run && steps.current == .review)
                let complete = index < steps.reached && !current
                let enabled = steps.available.contains(page) || (page == .run && steps.available.contains(.review))
                Button { select(page) } label: {
                    HStack(spacing: SH.Space.s) {
                        if complete {
                            Image(systemName: "checkmark").font(.sh(.micro, weight: .bold)).foregroundStyle(Color.sh.done)
                        } else {
                            Text("\(index + 1)").shText(.micro).foregroundStyle(current ? Color.sh.lanternText : Color.sh.textTertiary)
                        }
                        if current || !compact {
                            Text(item.1).font(.sh(.ui, weight: current ? .semibold : .regular))
                                .foregroundStyle(current ? Color.sh.textPrimary : complete ? Color.sh.textSecondary : Color.sh.textTertiary)
                        }
                    }
                    .padding(.horizontal, SH.Space.m)
                    .frame(height: SH.Height.controlM)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.shRow(selected: current))
                .disabled(!enabled)
                .accessibilityLabel("Step \(index + 1), \(item.1)\(complete ? ", complete" : "")")
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }.fixedSize()
    }
}

enum MissionWorkspacePage: String, CaseIterable {
    case goal, map, run, review, done
    init(phase: MissionRun.Phase) {
        switch phase {
        case .planning: self = .goal
        case .map: self = .map
        case .running, .paused, .stopped: self = .run
        case .review, .publishing: self = .review
        case .done: self = .done
        }
    }

    /// The page a mission opens on. Paused or stopped work shows where it was: review evidence if
    /// it reached review, the run if any station ran, else the map or the planning conversation.
    static func resolve(mission: Mission, preferred: Self? = nil) -> Self {
        let phase = mission.phase
        let noMap = mission.draft.plan?.stations.isEmpty != false
        if phase == .map && (noMap || (mission.run?.pendingQuestion != nil && preferred == nil)) { return .goal }
        // Stock Spec Kit opens on Goal, where the brief holds each repository's consent and the next stock
        // command, until every repository is allowed and has its tasks. Choosing Map still shows the map.
        if phase == .map && preferred == nil && mission.specKit != nil && mission.approvedPlanRevision == nil
            && (!mission.specKitConsented || mission.specKitNext != nil) { return .goal }
        if let preferred, preferred.available(for: mission) { return preferred }
        if [.paused, .stopped].contains(phase) {
            if mission.run?.reviewFingerprint != nil && Self.review.available(for: mission) { return .review }
            if !mission.stationAttempts.isEmpty { return .run }
            return noMap ? .goal : .map
        }
        return Self(phase: phase)
    }

    /// 0 Goal, 1 Map, 2 Run, 3 Done: earlier steps draw a check.
    static func reached(_ mission: Mission) -> Int {
        switch mission.phase {
        case .planning: mission.draft.plan?.stations.isEmpty == false ? 1 : 0
        case .map: mission.draft.plan?.stations.isEmpty == false && mission.run?.pendingQuestion == nil ? 1 : 0
        case .paused, .stopped: mission.stationAttempts.isEmpty ? (mission.draft.plan?.stations.isEmpty == false ? 1 : 0) : 2
        case .running, .review, .publishing: 2
        case .done: 3
        }
    }

    func available(for mission: Mission) -> Bool {
        let phase = mission.phase
        switch self {
        case .goal: return true
        case .map: return mission.draft.plan?.stations.isEmpty == false
        case .run: return !mission.stationAttempts.isEmpty
        case .review: return [.review, .publishing, .done].contains(phase) || ([.paused, .stopped].contains(phase) && mission.run?.reviewFingerprint != nil && (phase == .paused || mission.run?.publicationApproval != nil))
        case .done: return phase == .done
        }
    }
}

// MARK: Goal (MXGoal)

struct MissionGoalView: View {
    let mission: Mission
    var output = ""
    var specKitReports: [SpaceID: SpecKitPreflight] = [:]
    let busy: Bool
    let openThread: (AgentID) -> Void
    var send: (MissionUIAction) async -> Bool = { _ in false }
    let action: (MissionUIAction) -> Void
    let showMap: () -> Void
    @State private var reply = ""
    /// A reply or an answer on its way: the composer and the choices wait, and keep the words until it lands.
    @State private var sending = false
    @FocusState private var replying: Bool
    @State private var showsBrief = false
    @Environment(\.missionInitialPanes) private var seed

    /// Sends and waits; `accepted` runs only when the controller took it, so a failure keeps the draft.
    private func deliver(_ value: MissionUIAction, accepted: @escaping () -> Void = {}) {
        guard !sending else { return }
        sending = true
        Task { @MainActor in
            if await send(value) { accepted() }
            sending = false
        }
    }

    /// The planner message that asked the open question, when it carries the receipt (older records don't).
    private var asked: UUID? {
        guard mission.run?.pendingQuestion != nil else { return nil }
        return mission.run?.messages.last { $0.role == .assistant && $0.question != nil }?.id
    }
    private var canReply: Bool { mission.run?.publicationApproval == nil && [.map, .paused, .stopped].contains(mission.phase) }
    private var messages: [MissionChatMessage] {
        let values = mission.run?.messages ?? []
        return values.isEmpty ? [MissionChatMessage(role: .user, text: mission.draft.goal)] : values
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < AppLayout.missionNarrowWidth {
                // A narrow window shows the conversation or the brief, as Review shows diff or contract.
                VStack(spacing: 0) {
                    SHSegmentedPicker("Show", selection: $showsBrief, options: [(false, "Conversation"), (true, "Brief")])
                        .fixedSize().padding(SH.Space.m)
                    SHHairline()
                    if showsBrief { brief } else { conversation(narrow: true) }
                }
            } else {
                HStack(spacing: 0) {
                    conversation(narrow: false).frame(maxWidth: .infinity)
                    Rectangle().fill(Color.sh.lineSubtle).frame(width: 1)
                    brief.frame(width: AppLayout.missionSide(AppLayout.missionBriefWidth, in: geometry.size.width))
                }
            }
        }
        .onAppear { if seed.side { showsBrief = true } }
    }

    private var brief: some View {
        MissionBrief(mission: mission, specKitReports: specKitReports, busy: busy, editable: canReply, action: action, showMap: showMap)
    }

    private func conversation(narrow: Bool) -> some View {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: SH.Space.xl) {
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                if message.role == .user, message.choice != nil, message.replyTo != nil {
                                    // A picked suggestion shows as the checked choice on its question.
                                    EmptyView()
                                } else if message.role == .user {
                                    Text(message.text).shText(.body).textSelection(.enabled)
                                        .padding(.horizontal, SH.Space.xl).padding(.vertical, SH.Space.l)
                                        .background(Color.sh.bgBubble, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                                        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                        .padding(.leading, SH.Space.xxxl * 2)
                                } else {
                                    if index == messages.firstIndex(where: { $0.role == .assistant }) {
                                        plannerActivity
                                        // As the board's activity rows: what the planner did, above its words. A summary
                                        // of its steps (each with its own thread), not interleaved by time.
                                        if mission.specKit != nil, !mission.specKitActivity.isEmpty {
                                            MissionPlannerActivity(rows: mission.specKitActivity, openThread: openThread)
                                        }
                                    }
                                    MissionProse(message.prose)
                                    if let question = message.question, let reply = messages.first(where: { $0.replyTo == message.id }) {
                                        MissionAnsweredQuestion(question: question, choices: message.choices ?? [], picked: reply.choice)
                                    }
                                }
                            }
                            if mission.specKit != nil {
                                // The planner runs each repository's own Spec Kit steps; you see what it did,
                                // and it asks here for each repository's project files before it uses them.
                                // No planner words yet: its steps so far stand on their own.
                                if !messages.contains(where: { $0.role == .assistant }), !mission.specKitActivity.isEmpty {
                                    MissionPlannerActivity(rows: mission.specKitActivity, openThread: openThread)
                                }
                                let lanes = mission.draft.plan?.lanes ?? []
                                let trusts = lanes.map { MissionTrust(lane: mission.specKit?[$0.spaceID], report: specKitReports[$0.spaceID]) }
                                let waiting = trusts.filter { if case .allowed = $0 { false } else { true } }.count
                                ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                                    if trusts[index].asksYou {
                                        MissionTrustCard(name: lane.name, space: lane.spaceID, trust: trusts[index], last: waiting == 1,
                                                         enabled: canReply && !busy && !sending, action: action)
                                    }
                                }
                            }
                            if narrow, mission.specKit != nil, mission.phase != .planning, mission.run?.pendingQuestion == nil,
                               mission.specKitNext != nil || !mission.specKitConsented, !mission.specKitAwaitingTrust(specKitReports) {
                                // The brief's footer is off screen in a narrow window: its one action, here.
                                HStack(spacing: SH.Space.m) {
                                    Text(mission.specKitStartNote(specKitReports) ?? "The planner stopped. Continue when you're ready.")
                                        .shText(.caption).foregroundStyle(Color.sh.textTertiary).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: SH.Space.m)
                                    Button { action(.plan("")) } label: { Label("Continue planning", systemImage: SHGlyph.mission.symbolName) }
                                        .buttonStyle(.sh(.secondary)).disabled(busy || !canReply || sending)
                                }
                            }
                            if mission.phase == .planning {
                                HStack(alignment: .top, spacing: SH.Space.m) {
                                    ProgressView().progressViewStyle(.shSpinner())
                                    Text(output.isEmpty ? "Reading \(mission.draft.plan?.lanes.count ?? 0) repositories…" : String(output.suffix(600)))
                                        .shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textSecondary).lineLimit(4)
                                }
                            }
                            if let question = mission.run?.pendingQuestion {
                                MissionQuestionCard(question: question, choices: mission.run?.pendingChoices ?? [],
                                                    enabled: canReply && !busy && !sending, answer: { choice in deliver(.answer(choice, choice: choice, replyTo: asked)) },
                                                    other: { replying = true })
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .frame(maxWidth: AppLayout.missionTranscriptWidth, alignment: .leading)
                        .padding(SH.Space.xxl)
                        .frame(maxWidth: .infinity)
                    }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: messages.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                MissionReplyComposer(text: $reply, focused: $replying,
                                     prompt: mission.phase == .planning ? "The planner is working. You can reply once it answers." : "Reply to the planner, or tell it what to change…",
                                     enabled: canReply && !busy && !sending) {
                    // While a question is open your words answer it (linked by receipt); otherwise they steer the plan.
                    let words = reply
                    deliver(mission.run?.pendingQuestion != nil ? .answer(words, choice: nil, replyTo: asked) : .plan(words)) {
                        if reply == words { reply = "" }
                    }
                }
                .frame(maxWidth: AppLayout.missionTranscriptWidth)
                .padding(.horizontal, SH.Space.xxl).padding(.bottom, SH.Space.xl)
            }
    }

    /// The planner turn as an activity row that opens its thread, where every read and search lives.
    @ViewBuilder private var plannerActivity: some View {
        if let planner = mission.run?.plannerID {
            Button { openThread(planner) } label: {
                HStack(spacing: SH.Space.m) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.sh.textTertiary)
                    Text("Explored \(mission.draft.plan?.lanes.count ?? 0) repositories").shText(.ui).fontWeight(.regular)
                    Text("planner thread").shText(.mono).foregroundStyle(Color.sh.textTertiary)
                    Image(systemName: "chevron.right").font(.sh(.micro)).foregroundStyle(Color.sh.textTertiary)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the planner thread")
        }
    }
}

/// Planner prose with inline code set in mono, as the thread draws it.
struct MissionProse: View {
    let text: String
    /// Streaming output changes every poll: it skips the markup cache and fills code flush.
    var live = false
    init(_ text: String, live: Bool = false) { self.text = text; self.live = live }
    var body: some View {
        Group {
            if live {
                Text(SHInlineMarkup.attributed(text, codeSize: SHTextStyle.code.size)).shText(.body)
            } else {
                // Settled words (messages, the brief, summaries): code as the boards' rounded chips.
                SHMarkupText(text, size: SHTextStyle.body.size, codeSize: SHTextStyle.code.size, lineHeight: SHTextStyle.body.lineHeight)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The planner's open question with its suggested answers. Picking one sends it as the reply;
/// "Something else" moves to the composer.
extension MissionChatMessage {
    /// The words without a question the planner also asked as a receipt (its card shows it).
    var prose: String {
        guard let question, text.hasSuffix(question) else { return text }
        return String(text.dropLast(question.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A question you already answered, from its receipts: the suggestion you picked checked, the
/// others dimmed; a free-text answer stays in the conversation as your message.
private struct MissionAnsweredQuestion: View {
    let question: String
    let choices: [String]
    let picked: String?
    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                Image(systemName: "questionmark.circle").foregroundStyle(Color.sh.lanternText)
                VStack(alignment: .leading, spacing: SH.Space.xs) {
                    Text(question).shText(.headline).textSelection(.enabled)
                    Text(picked == nil ? "You answered in your own words." : "You answered.").shText(.caption).foregroundStyle(Color.sh.textTertiary)
                }
            }
            if !choices.isEmpty {
                SHFlowLayout(spacing: SH.Space.m) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                        let chosen = choice == picked
                        HStack(spacing: SH.Space.s) {
                            if chosen { Image(systemName: "checkmark").font(.sh(.caption, weight: .semibold)) }
                            Text(choice).shText(.ui)
                        }
                        .foregroundStyle(chosen ? Color.sh.lanternText : Color.sh.textTertiary)
                        .padding(.horizontal, SH.Space.l).frame(height: SH.Height.controlM)
                        .background(chosen ? Color.sh.lanternTint : Color.clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                        .shBorder(chosen ? Color.sh.lantern : Color.sh.lineSubtle, radius: SH.Radius.s)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(choice)
                        .accessibilityValue(chosen ? "your answer" : "not chosen")
                    }
                }.padding(.leading, SH.Space.xl + SH.Space.xs)
            }
        }
        .padding(SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(Color.sh.lineStrong, radius: SH.Radius.m)
        .accessibilityElement(children: .contain)
    }
}

private struct MissionQuestionCard: View {
    let question: String
    let choices: [String]
    let enabled: Bool
    let answer: (String) -> Void
    let other: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                Image(systemName: "questionmark.circle").foregroundStyle(Color.sh.lanternText)
                VStack(alignment: .leading, spacing: SH.Space.xs) {
                    Text(question).shText(.headline).textSelection(.enabled)
                    Text("The map waits for this answer.").shText(.caption).foregroundStyle(Color.sh.textTertiary)
                }
            }
            SHFlowLayout(spacing: SH.Space.m) {
                ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                    Button(choice) { answer(choice) }
                        .buttonStyle(.sh(index == 0 ? .raised : .secondary, tint: index == 0 ? Color.sh.lanternText : nil))
                        .disabled(!enabled)
                }
                Button(choices.isEmpty ? "Answer below" : "Something else", action: other).buttonStyle(.sh(.ghost)).disabled(!enabled)
            }.padding(.leading, SH.Space.xl + SH.Space.xs)
        }
        .padding(SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(Color.sh.lineStrong, radius: SH.Radius.m)
        .accessibilityElement(children: .contain)
    }
}

/// The bottom composer of Goal and of the map's planner input.
struct MissionReplyComposer: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let prompt: String
    let enabled: Bool
    let send: () -> Void
    private var ready: Bool { enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(prompt).shText(.body).foregroundStyle(Color.sh.textTertiary).padding(.horizontal, SH.Space.xs).accessibilityHidden(true)
                }
                TextEditor(text: $text).focused(focused).shText(.body).scrollContentBackground(.hidden)
                    .disabled(!enabled).accessibilityLabel(prompt)
            }.padding([.horizontal, .top], SH.Space.l)
            HStack {
                Spacer()
                Button(action: send) { Image(systemName: "arrow.up") }
                    .buttonStyle(.shIcon(tint: ready ? Color.sh.lanternText : nil))
                    .disabled(!ready)
                    .keyboardShortcut(.return, modifiers: .command)
                    .shHelp("Send to the planner", shortcut: "⌘↩")
                    .accessibilityLabel("Send to the planner")
            }.padding(SH.Space.s)
        }
        .frame(height: AppLayout.missionReplyHeight)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(Color.sh.lineStrong, radius: SH.Radius.m)
        .shFocusRing(focused.wrappedValue, radius: SH.Radius.m)
    }
}

// MARK: Brief

private enum BriefField: Hashable { case destination, context, contract, size }

/// The mission brief: every section edits in place while the mission is not running.
struct MissionBrief: View {
    @Environment(\.missionHostName) private var missionHost
    let mission: Mission
    var specKitReports: [SpaceID: SpecKitPreflight] = [:]
    let busy: Bool
    let editable: Bool
    let action: (MissionUIAction) -> Void
    let showMap: () -> Void
    @State private var editing: BriefField?
    @State private var text = ""
    @State private var title = ""
    @State private var limits = MissionLimits()
    @State private var editedRevision: UInt64 = 0

    private var plan: MissionPlan? { mission.draft.plan }
    private var hasMap: Bool { plan?.stations.isEmpty == false }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: SH.Space.xs) {
                        Text("Mission brief").shText(.title).accessibilityAddTraits(.isHeader)
                        HStack(spacing: SH.Space.s) {
                            if mission.phase == .planning { ProgressView().progressViewStyle(.shSpinner(size: 10)) }
                            Text(editable ? "built by the planner as you talk · click a section to change it" : "built by the planner as you talk")
                                .shText(.caption).foregroundStyle(Color.sh.textTertiary)
                        }
                    }.padding(SH.Space.xl)
                    SHHairline()
                    section(.destination, "Destination", meta: "from your message") {
                        MissionProse(mission.draft.goal)
                    }
                    lanes
                    section(.context, "Context", meta: mission.draft.context.isEmpty ? nil : "\(mission.draft.context.count) found") {
                        if mission.draft.context.isEmpty {
                            Text("The planner lists the docs and files it relies on here.").shText(.caption).foregroundStyle(Color.sh.textTertiary)
                        } else {
                            SHFlowLayout(spacing: SH.Space.s) {
                                ForEach(Array(mission.draft.context.enumerated()), id: \.offset) { _, entry in
                                    HStack(spacing: SH.Space.xs) {
                                        SHGlyph.document.image.font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                                        Text(entry).shText(.mono).lineLimit(1).truncationMode(.middle)
                                    }
                                    .padding(.horizontal, SH.Space.m).frame(height: SH.Height.controlS)
                                    .shBorder(Color.sh.lineSubtle, radius: SH.Radius.xs)
                                    .help(entry)
                                }
                            }
                        }
                    }
                    section(.contract, "Validation contract", meta: "independent validator") { contract }
                    section(.size, "Size", meta: nil) { size }
                    if let question = mission.run?.pendingQuestion {
                        VStack(alignment: .leading, spacing: SH.Space.m) {
                            SHPageSectionLabel("Still open")
                            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                                Image(systemName: "cloud").foregroundStyle(Color.sh.textTertiary)
                                Text(question).shText(.ui).fontWeight(.regular).lineLimit(3)
                                Spacer(minLength: SH.Space.m)
                                Text("answer in the conversation").shText(.micro).foregroundStyle(Color.sh.textTertiary)
                            }
                        }.padding(SH.Space.xl)
                    }
                }
            }
            SHHairline()
            HStack(spacing: SH.Space.m) {
                Text(mission.specKitStartNote(specKitReports) ?? "Nothing writes code until you launch.").shText(.caption).foregroundStyle(Color.sh.textTertiary)
                Spacer()
                if mission.specKit != nil, mission.specKitNext != nil || !hasMap {
                    // The planner runs the steps; this only resumes it (re-reading each repository's files first).
                    Button { action(.plan("")) } label: {
                        Label(mission.phase == .planning ? "Planning…" : "Continue planning", systemImage: SHGlyph.mission.symbolName)
                    }
                    .buttonStyle(.sh(.primary))
                    .disabled(busy || !editable || mission.run?.pendingQuestion != nil || awaitingTrust)
                    .shHelp(mission.run?.pendingQuestion != nil ? "Answer the open question first"
                            : awaitingTrust ? "Allow each repository's project files first"
                            : "Re-reads each repository's project files and continues where the planner stopped. Nothing runs until every repository is allowed.")
                } else {
                    Button {
                        if hasMap { showMap() } else { action(.plan("")) }
                    } label: {
                        Label(mission.phase == .planning ? "Drafting the map…" : hasMap ? "Review the map" : "Draft the map", systemImage: SHGlyph.mission.symbolName)
                    }
                    .buttonStyle(.sh(.primary))
                    .disabled(mission.run?.pendingQuestion != nil || (!hasMap && (busy || !editable)))
                    .shHelp(mission.run?.pendingQuestion != nil ? "Answer the open question first" : hasMap ? "Open the map" : "Ask the planner for the map")
                }
            }.padding(.horizontal, SH.Space.xl).frame(height: SHPageMetrics.headerHeight)
        }
        .background(Color.sh.bgWindow)
        .onChange(of: mission.revision) { _, revision in
            if editing != nil && revision != editedRevision { editing = nil }
        }
    }

    /// A repository read as needing your OK right now. Unread or unready repositories keep Continue
    /// planning available: it re-reads their files (after you fix a setup, for one).
    private var awaitingTrust: Bool { mission.specKitAwaitingTrust(specKitReports) }

    private var lanes: some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            sectionHead("Lanes · \(plan?.lanes.count ?? 0) repos", meta: "chosen by you")
            ForEach(plan?.lanes ?? []) { lane in
                let work = plan?.stations.filter { $0.laneID == lane.id && $0.kind == .worker }.map(\.title) ?? []
                // A Spec Kit lane says where its trust stands until the planner maps work there.
                let trust = mission.specKit.map { _ in MissionTrust(lane: mission.specKit?[lane.spaceID], report: specKitReports[lane.spaceID]) }
                HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                    SHGlyph.repository.image.foregroundStyle(Color.sh.textTertiary)
                    Text(lane.name).shText(.mono).fontWeight(.semibold).lineLimit(1).frame(width: AppLayout.missionBriefLaneName, alignment: .leading)
                    Text(!work.isEmpty ? work.joined(separator: ", ") : trust?.word ?? "no work mapped yet").shText(.ui).fontWeight(.regular)
                        .foregroundStyle(trust?.asksYou == true && work.isEmpty ? Color.sh.lanternText : work.isEmpty ? Color.sh.textTertiary : Color.sh.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: SH.Space.m)
                    Text(lane.baseBranch.map(MissionBranchSelection.label) ?? "—").shText(.micro).foregroundStyle(Color.sh.textTertiary)
                }
            }
        }.padding(SH.Space.xl).overlay(alignment: .bottom) { SHHairline() }
    }

    @ViewBuilder private var contract: some View {
        let checks = plan?.stations.filter { $0.kind == .check } ?? []
        VStack(alignment: .leading, spacing: SH.Space.m) {
            if mission.draft.requirements.isEmpty && checks.isEmpty {
                Text("The validator's checks appear as the planner drafts them.").shText(.caption).foregroundStyle(Color.sh.textTertiary)
            }
            ForEach(Array(mission.draft.requirements.enumerated()), id: \.offset) { _, requirement in
                contractRow("checkmark.shield", requirement, tag: "validator")
            }
            ForEach(checks) { check in contractRow("terminal", check.command ?? check.title, tag: "cmd", mono: true) }
        }
    }

    private func contractRow(_ symbol: String, _ text: String, tag: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            Image(systemName: symbol).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            Text(text).font(mono ? .sh(.mono) : .sh(.ui, weight: .regular)).textSelection(.enabled)
            Spacer(minLength: SH.Space.m)
            Text(tag).shText(.micro).foregroundStyle(Color.sh.textTertiary)
        }
    }

    private var size: some View {
        let limits = mission.draft.limits
        return VStack(spacing: SH.Space.m) {
            fact("Limits", "\(MissionFormat.tokens(limits.tokens)) · \(MissionFormat.duration(limits.seconds)) · \(limits.dollars.formatted(.currency(code: "USD").precision(.fractionLength(0))))",
                 note: "\(limits.concurrentStations) at once · \(limits.retries) retries")
            fact("Model", mission.run?.model ?? "—", note: nil)
            fact("Runs on", missionHost, note: "fresh worktrees")
        }
    }

    private func fact(_ label: String, _ value: String, note: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).shText(.ui).fontWeight(.regular).foregroundStyle(Color.sh.textSecondary)
            Spacer(minLength: SH.Space.m)
            Text(value).shText(.mono)
            if let note { Text(note).shText(.micro).foregroundStyle(Color.sh.textTertiary) }
        }
    }

    private func sectionHead(_ title: String, meta: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            SHPageSectionLabel(title)
            Spacer()
            if let meta { Text(meta).shText(.micro).foregroundStyle(Color.sh.textTertiary) }
        }
    }

    /// A section that becomes its editor when clicked.
    @ViewBuilder private func section<Content: View>(_ field: BriefField, _ title: String, meta: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            sectionHead(title, meta: meta)
            if editing == field { editor(field) } else {
                Button { begin(field) } label: { content().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .disabled(!editable || busy)
                    .accessibilityHint(editable ? "Edit \(title.lowercased())" : "")
            }
        }
        .padding(SH.Space.xl)
        .overlay(alignment: .bottom) { SHHairline() }
    }

    @ViewBuilder private func editor(_ field: BriefField) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            switch field {
            case .destination:
                TextField("Title", text: $title).textFieldStyle(.sh).accessibilityLabel("Mission title")
                editorText("Destination")
            case .context: editorText("Context · one reference per line")
            case .contract: editorText("Validation requirements · one per line")
            case .size:
                SHStepper("Tokens (millions)", value: Binding(get: { max(1, limits.tokens / 1_000_000) }, set: { limits.tokens = $0 * 1_000_000 }), in: 1...100) { "\($0)M" }
                SHStepper("Time (hours)", value: Binding(get: { max(1, Int(limits.seconds / 3600)) }, set: { limits.seconds = Double($0) * 3600 }), in: 1...48) { "\($0)h" }
                SHStepper("Spend (USD)", value: Binding(get: { Int(limits.dollars) }, set: { limits.dollars = Double($0) }), in: 1...1000) { "$\($0)" }
                SHStepper("At once", value: $limits.concurrentStations, in: 1...16)
                SHStepper("Retries", value: $limits.retries, in: 0...10)
            }
            HStack {
                Text("Changes need a fresh map approval.").shText(.caption).foregroundStyle(Color.sh.textTertiary)
                Spacer()
                Button("Cancel") { editing = nil }.buttonStyle(.sh(.ghost, size: .s)).keyboardShortcut(.cancelAction)
                Button("Save") { save(field) }.buttonStyle(.sh(.secondary, size: .s)).disabled(busy || mission.revision != editedRevision)
            }
        }
    }

    private func editorText(_ label: String) -> some View {
        TextEditor(text: $text).shText(.body).scrollContentBackground(.hidden)
            .frame(height: AppLayout.missionEditorHeight).padding(SH.Space.s)
            .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .shBorder(Color.sh.lineStrong, radius: SH.Radius.s)
            .accessibilityLabel(label)
    }

    private func begin(_ field: BriefField) {
        editedRevision = mission.revision
        title = mission.draft.title
        limits = mission.draft.limits
        switch field {
        case .destination: text = mission.draft.goal
        case .context: text = mission.draft.context.joined(separator: "\n")
        case .contract: text = mission.draft.requirements.joined(separator: "\n")
        case .size: text = ""
        }
        editing = field
    }

    private func save(_ field: BriefField) {
        var draft = mission.draft
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        switch field {
        case .destination: draft.goal = text.trimmingCharacters(in: .whitespacesAndNewlines); draft.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        case .context: draft.context = lines
        case .contract: draft.requirements = lines
        case .size:
            if draft.plan == nil { draft.plan = MissionPlan(limits: limits) } else { draft.plan?.limits = limits }
        }
        action(.save(draft, editedRevision))
        editing = nil
    }
}
