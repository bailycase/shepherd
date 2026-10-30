import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// One mission on its host (MobileMission; iPadMissionMap beside the list): what it waits on
/// (a question, a repository's OK, a completion report), its map with each station's latest
/// receipt, the planner's conversation, and the phase's controls. Every action names the revision
/// shown here; the host refuses it if the mission moved since.
struct MissionScreen: View {
    let host: UUID
    let id: MissionID
    var embedded = false
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @State private var busy = false
    @State private var failure: String?
    @State private var reply = ""
    @State private var station: MissionStationRow?
    @State private var confirmingStop = false

    var body: some View {
        let mobileHost = hosts.hosts.first { $0.id == host }
        Group {
            if let mobileHost, let mission = mobileHost.missions.record(id) {
                content(mission, on: mobileHost)
            } else {
                SHEmptyState(Text("Mission gone"), message: "This mission is no longer on its host, or the host is offline.") { EmptyView() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.sh.bgWindow)
        .navigationTitle(embedded ? "" : mobileHost?.missions.record(id)?.draft.title ?? "Mission")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: mobileHost?.missions.record(id)?.revision) {
            guard let mobileHost, mobileHost.missions.record(id)?.run?.specKit != nil else { return }
            try? await mobileHost.missions.loadSpecKit(id)
        }
        .sheet(item: $station) { row in
            MissionStationSheet(row: row, host: host, mission: id, live: row.attempt.flatMap { mobileHost?.missions.live[id]?.attempts[$0] } ?? "",
                                perform: perform)
                .presentationDetents([.medium, .large])
        }
    }

    private func content(_ mission: Mission, on mobileHost: MobileHost) -> some View {
        let controls = RemoteMissionControls(mission, reports: mobileHost.missions.specKit[id]?.reports ?? [:])
        let phase = mission.run?.phase ?? .map
        let row = MissionRowModel(mission, host: mobileHost)
        return ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                VStack(alignment: .leading, spacing: SH.Space.s) {
                    HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                        Text(mission.draft.title).shText(.title).foregroundStyle(Color.sh.textPrimary).accessibilityAddTraits(.isHeader)
                        Spacer(minLength: SH.Space.s)
                        SHStatusPill(row.state, label: row.label).fixedSize()
                    }
                    Text("Runs on \(mobileHost.name) · \(mission.run?.model ?? "no model")").shText(.mono).foregroundStyle(Color.sh.textTertiary)
                }
                if let failure {
                    SHBanner(.failed, title: failure) { Button("OK") { self.failure = nil }.buttonStyle(.sh(.secondary)) }
                }
                if !mobileHost.servesMissions {
                    SHBanner(.idle, title: "\(mobileHost.name) is offline or no longer serves missions. What shows is what it last sent.") { EmptyView() }
                }
                if [.paused, .stopped].contains(phase), let notice = mission.run?.notice {
                    SHBanner(.attention, title: notice) { EmptyView() }
                }
                if let question = controls.question { questionCard(question) }
                ForEach(controls.consents) { consent in consentCard(consent) }
                ForEach(controls.setUps) { setUp in
                    SHBanner(.attention, title: "\(setUp.name) has no Spec Kit project for pi yet.",
                             message: "Setup runs the stock specify CLI in this mission's worktree on \(mobileHost.name). Your own checkout is untouched.") {
                        Button("Set up Spec Kit in \(setUp.name)") { act(mission, .specKitSetUp(spaceID: setUp.spaceID)) }
                            .buttonStyle(.sh(.raised, tint: Color.sh.lanternText)).disabled(busy)
                    }
                }
                if let output = mobileHost.missions.live[id]?.output, !output.isEmpty, phase.active { liveCard(output) }
                map(mission)
                conversation(mission)
                if controls.message && controls.question == nil { composer(mission, placeholder: "Message the planner") }
                if controls.review {
                    Button { navigator.open(.missions(.review(host: host, mission: id))) } label: {
                        Label(phase == .done ? "Review the published changes" : "Review changes", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.sh(.secondary))
                }
            }
            .padding(MobileLayout.gutter)
            .frame(maxWidth: embedded ? MobileLayout.missionDetailMaxWidth : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: embedded ? .leading : .center)
        }
        .refreshable { await mobileHost.missions.refresh() }
        .safeAreaInset(edge: .bottom) { actions(mission, controls: controls, available: mobileHost.servesMissions) }
    }

    // MARK: What waits on you

    private func questionCard(_ question: RemoteMissionControls.Question) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            Text("The planner asks").shText(.micro).foregroundStyle(Color.sh.lanternText)
            Text(question.text).shText(.body).foregroundStyle(Color.sh.textPrimary).fixedSize(horizontal: false, vertical: true)
            ForEach(question.choices, id: \.self) { choice in
                Button { answer(choice, choice: choice, replyTo: question.replyTo) } label: {
                    Text(choice).shText(.ui).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.sh(.secondary)).disabled(busy)
            }
            composerField(placeholder: "Answer in your own words") { text in answer(text, choice: nil, replyTo: question.replyTo) }
        }
        .padding(SH.Space.l)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: MobileLayout.cardRadius))
        .shBorder(Color.sh.lantern, radius: MobileLayout.cardRadius)
    }

    private func consentCard(_ consent: RemoteMissionControls.Consent) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            Label(consent.changed ? "\(consent.name)'s planning setup changed since you allowed it." : "Allow \(consent.name)'s own Spec Kit prompts?",
                  systemImage: "lock.shield")
                .shText(.headline).foregroundStyle(Color.sh.textPrimary)
            Text("The planner loads \(consent.name)'s stock Spec Kit prompts with --prompt-template, which skips pi's project-trust prompt. Allowing binds to these files as the host read them (\(consent.fingerprint.prefix(12))…); if any change, you're asked again.")
                .shText(.caption).foregroundStyle(Color.sh.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: SH.Space.m) {
                Button(consent.last ? "Allow and continue planning" : "Allow \(consent.name)") {
                    guard let mission = record else { return }
                    act(mission, .specKitConsent(spaceID: consent.spaceID, fingerprint: consent.fingerprint, continuePlanning: consent.last))
                }
                .buttonStyle(.sh(.raised, tint: Color.sh.lanternText)).disabled(busy)
                Button("Not now") { if let mission = record { act(mission, .pause) } }.buttonStyle(.sh(.ghost)).disabled(busy)
            }
        }
        .padding(SH.Space.l)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: MobileLayout.cardRadius))
        .shBorder(Color.sh.lineStrong, radius: MobileLayout.cardRadius)
    }

    // MARK: Map and conversation

    /// What the planner or the working station is saying now, as the host's page shows it.
    private func liveCard(_ output: String) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(spacing: SH.Space.s) {
                SHStatusDot(.running, size: MobileLayout.statusDot)
                Text("Working now").shText(.micro).foregroundStyle(Color.sh.textTertiary)
            }
            Text(output).shText(.body).foregroundStyle(Color.sh.textSecondary)
                .lineLimit(MobileLayout.missionLiveLines, reservesSpace: false)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: MobileLayout.cardRadius))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func map(_ mission: Mission) -> some View {
        let rows = MissionStationRow.rows(mission)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                SHListHeader("Map", count: rows.count)
                SHStepStrip(rows.map(\.state))
                SHListCard {
                    ForEach(rows) { row in
                        Button { station = row } label: {
                            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                                SHStatusDot(row.state ?? .idle, size: MobileLayout.statusDot)
                                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                                    Text(row.title).shText(.ui).foregroundStyle(Color.sh.textPrimary).lineLimit(2)
                                    Text(([row.kind] + [row.lane].compactMap { $0 }).joined(separator: " · ")).shText(.micro).foregroundStyle(Color.sh.textTertiary)
                                }
                                Spacer(minLength: SH.Space.s)
                                Text(row.status).shText(.micro).foregroundStyle(row.state?.textColor ?? Color.sh.textTertiary)
                            }
                            .padding(SH.Space.l)
                            .frame(maxWidth: .infinity, minHeight: MobileLayout.rowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.shRow(radius: 0))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    @ViewBuilder private func conversation(_ mission: Mission) -> some View {
        let messages = (mission.run?.messages ?? []).filter { !$0.text.isEmpty }.suffix(6)
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                SHListHeader("Conversation", count: nil)
                ForEach(Array(messages)) { message in
                    VStack(alignment: .leading, spacing: SH.Space.xs) {
                        Text(message.role == .user ? "You" : "Planner").shText(.micro).foregroundStyle(Color.sh.textTertiary)
                        Text(message.choice ?? message.text).shText(.body).foregroundStyle(Color.sh.textPrimary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    .padding(SH.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(message.role == .user ? Color.sh.bgRaised : Color.clear, in: RoundedRectangle(cornerRadius: MobileLayout.cardRadius))
                }
            }
        }
    }

    private func composer(_ mission: Mission, placeholder: String) -> some View {
        composerField(placeholder: placeholder) { text in answer(text, choice: nil, replyTo: nil) }
    }

    private func composerField(placeholder: String, send: @escaping (String) -> Void) -> some View {
        HStack(alignment: .bottom, spacing: SH.Space.m) {
            TextField(placeholder, text: $reply, axis: .vertical)
                .shText(.body).lineLimit(1...6)
                .padding(SH.Space.m)
                .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            Button { send(reply.trimmingCharacters(in: .whitespacesAndNewlines)) } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.shIcon(bordered: true, tint: Color.sh.lanternText))
                .disabled(busy || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
        }
    }

    // MARK: Controls

    private func actions(_ mission: Mission, controls: RemoteMissionControls, available: Bool) -> some View {
        HStack(spacing: SH.Space.m) {
            if let stop = controls.stop {
                Button(stop, role: .destructive) { confirmingStop = true }
                    .buttonStyle(.sh(.ghost)).disabled(busy || !available)
                    .confirmationDialog("\(stop)?", isPresented: $confirmingStop, titleVisibility: .visible) {
                        Button(stop, role: .destructive) { act(mission, .stop) }
                    } message: {
                        Text("Its agents stop. Worktrees and receipts stay on the host; nothing resumes on its own.")
                    }
            }
            Spacer(minLength: SH.Space.s)
            if controls.runAgain {
                Button("Run again", systemImage: "arrow.clockwise") { act(mission, .runAgain) }
                    .buttonStyle(.sh(.secondary)).disabled(busy || !available)
            }
            if controls.pause {
                Button("Pause", systemImage: "pause.fill") { act(mission, .pause) }
                    .buttonStyle(.sh(.secondary)).disabled(busy || !available)
            }
            if let primary = controls.primary {
                Button { act(mission, wire(primary)) } label: { Text(title(primary)).lineLimit(1) }
                    .buttonStyle(.sh(.primary)).disabled(busy || !available)
            }
        }
        .padding(.horizontal, MobileLayout.gutter)
        .padding(.vertical, SH.Space.m)
        .background(Color.sh.bgWindow)
        .overlay(alignment: .top) { SHHairline() }
    }

    private func title(_ primary: RemoteMissionControls.Primary) -> String {
        switch primary {
        case .launch: "Launch"
        case .resume: "Resume"
        case .resumePlanning: "Continue planning"
        case .accept(_, let lane): "Accept \(lane)'s report"
        }
    }

    private func wire(_ primary: RemoteMissionControls.Primary) -> RemoteMissionAction {
        switch primary {
        case .launch, .resume: .launch
        case .resumePlanning: .plan(feedback: "")
        case .accept(let attempt, _): .acceptConvergence(attemptID: attempt)
        }
    }

    private var record: Mission? { hosts.hosts.first { $0.id == host }?.missions.record(id) }

    private func answer(_ text: String, choice: String?, replyTo: UUID?) {
        guard let mission = record, !text.isEmpty else { return }
        act(mission, .answer(text: text, choice: choice, replyTo: replyTo)) { reply = "" }
    }

    /// Runs one action against the revision on screen now; the host's refusal shows in the banner.
    private func act(_ mission: Mission, _ action: RemoteMissionAction, done: @escaping () -> Void = {}) {
        let task = perform(action, mission.revision)
        Task { if await task.value { done() } }
    }

    private func perform(_ action: RemoteMissionAction, _ revision: UInt64) -> Task<Bool, Never> {
        guard !busy, let missions = hosts.hosts.first(where: { $0.id == host })?.missions else { return Task { false } }
        busy = true
        failure = nil
        return Task { @MainActor in
            defer { busy = false }
            do {
                if let made = try await missions.perform(id, revision: revision, action) {
                    MissionsHooks.open(host: host, mission: made, navigator: navigator)
                }
                return true
            } catch {
                failure = RemoteMissions.describe(error)
                return false
            }
        }
    }
}

/// One station: its latest receipt, its thread on the host, and a steer while its turn works.
private struct MissionStationSheet: View {
    let row: MissionStationRow
    let host: UUID
    let mission: MissionID
    /// What its working turn is saying now.
    let live: String
    let perform: (RemoteMissionAction, UInt64) -> Task<Bool, Never>
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss
    @State private var steer = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                SHFactRow("Kind", value: row.kind)
                if let lane = row.lane { SHFactRow("Repository", value: lane, mono: true) }
                SHFactRow("Latest", value: row.status)
                if !live.isEmpty {
                    Text(live).shText(.body).foregroundStyle(Color.sh.textSecondary)
                        .lineLimit(MobileLayout.missionLiveLines, reservesSpace: false)
                }
                if let agent = row.agent {
                    Button("Open its thread", systemImage: "text.bubble") {
                        dismiss()
                        navigator.open(.thread(AgentRef(host: host, agent: agent)))
                    }
                    .buttonStyle(.sh(.secondary))
                }
                if row.steerable, let attempt = row.attempt {
                    VStack(alignment: .leading, spacing: SH.Space.s) {
                        TextField("Steer \(row.title) — delivered before its next turn", text: $steer, axis: .vertical)
                            .shText(.body).lineLimit(1...6)
                            .padding(SH.Space.m)
                            .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                        Button("Steer") {
                            guard let current = hosts.hosts.first(where: { $0.id == host })?.missions.record(mission) else { return }
                            let text = steer
                            Task { if await perform(.steer(attemptID: attempt, text: text), current.revision).value { steer = "" } }
                        }
                        .buttonStyle(.sh(.primary)).disabled(steer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("Your words stay here until the agent reads them.").shText(.caption).foregroundStyle(Color.sh.textTertiary)
                    }
                }
                Spacer()
            }
            .padding(MobileLayout.gutter)
            .navigationTitle(row.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
