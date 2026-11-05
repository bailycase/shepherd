import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// One pull request on iPhone (MobilePRDetail, MobilePRChanges, MobilePRChecks, MobilePRStates;
/// DuoClosedPR): "#31" over "payments · Open" in the bar, the page, and the bottom bar.
struct ForgePullRequestScreen: View {
    let key: ForgeItemKey
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        VerticalBars { verticalBars in
            ForgePullRequestContent(key: key, layout: .phone(verticalBars: verticalBars)) { path in
                navigator.open(.forge(.file(host: key.host, ref: key.ref, path: path)))
            }
        }
    }
}

/// A pull request's page: state, title and branches, Summary | Changes | Checks, then Ask agent,
/// Review… and the primary action (`ForgePresentation.primaryAction`).
struct ForgePullRequestContent: View {
    let key: ForgeItemKey
    let layout: ForgeDetailLayout
    let openFile: (String) -> Void
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(ThreadStores.self) private var threads
    @State private var asking = false
    @State private var question = ""
    @State private var handing = false
    /// The worktree to remove once the merge sheet has gone (Delete Worktree's own confirmation).
    @State private var removing: AgentRef?

    init(key: ForgeItemKey, layout: ForgeDetailLayout, openFile: @escaping (String) -> Void = { _ in }) {
        self.key = key
        self.layout = layout
        self.openFile = openFile
    }

    var body: some View {
        let store = ForgeStore.of(hosts)
        let load = store.pullRequests[key]
        let model = load?.value
        let title = "#\(key.ref.number)"
        let subtitle = model?.subtitle ?? key.ref.repoName
        let tab = Binding(get: { store.tabs[key] ?? .summary }, set: { store.tabs[key] = $0 })
        let sheet = Binding(get: { store.sheet?.key == key ? store.sheet : nil }, set: { if $0 == nil { store.sheet = nil } })
        VStack(spacing: 0) {
            if layout.isPad {
                ForgePadHead(title: title, subtitle: subtitle, verticalBars: layout.verticalBars) { menu(store, model) }
            } else if layout.verticalBars {
                // The bars run down the side (iPhone Duo closed): a plain centred title (DuoClosedPR).
                ForgeTitle(title: title, subtitle: subtitle).frame(maxWidth: .infinity).padding(.vertical, SH.Space.s)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                    if let model {
                        head(model)
                        ForgeSegmented(selection: tab, options: [
                            .init(value: .summary, title: "Summary"),
                            .init(value: .changes, title: "Changes", count: model.detail.changedFiles),
                            .init(value: .checks, title: "Checks", dot: model.checksTone),
                        ])
                        if let failure = store.failure {
                            SHBanner(.failed, title: failure) {
                                Button("OK") { store.failure = nil }.buttonStyle(.sh(.secondary))
                            }
                        }
                        switch tab.wrappedValue {
                        case .summary: summary(model)
                        case .changes: ForgeChangesTab(key: key, openFile: openFile)
                        case .checks: ForgeChecksTab(key: key, model: model) { check, log in fix(check, log: log, model: model, store: store) }
                        }
                    } else if let error = load?.error {
                        ForgeErrorState(error: error) { Task { await store.loadPullRequest(key) } }
                    } else {
                        ForgeFetching(number: key.ref.number)
                    }
                }
                .padding(.horizontal, layout.isPad ? MobileLayout.padThreadGutter - SH.Space.s : MobileLayout.gutter)
                .padding(.bottom, MobileLayout.sectionSpacing)
                .frame(maxWidth: MobileLayout.forgeDetailMaxWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.sh.bgWindow)
        .safeAreaInset(edge: .bottom, spacing: 0) { bar(store, model) }
        .task(id: key) {
            Task { await store.loadPeople(host: key.host, repo: key.ref.repo) }
            await store.loadPullRequest(key)
            if store.sidebars[key.host] == nil { await store.loadSidebars() }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: layout.verticalBars || layout.isPad ? .title : nil)
        .toolbar {
            if !layout.isPad, !layout.verticalBars {
                ToolbarItem(placement: .principal) { ForgeTitle(title: title, subtitle: subtitle) }
            }
            if !layout.isPad || layout.verticalBars {
                ToolbarOverflowMenu { menu(store, model) }
            }
        }
        .sheet(item: sheet, onDismiss: {
            if let removing {
                self.removing = nil
                navigator.present(.search(.delete(removing)))
            }
        }) { sheet in
            if let model {
                switch sheet.kind {
                case .review: ForgeReviewSheet(key: key, model: model)
                case .merge: ForgeMergeSheet(key: key, model: model) { removing = $0 }
                case .comment: ForgeCommentSheet(key: key)
                }
            }
        }
        .alert("Ask about #\(key.ref.number)", isPresented: $asking) {
            TextField("Your question", text: $question)
            Button("Cancel", role: .cancel) { question = "" }
            Button("Ask") {
                let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
                question = ""
                guard let model, !text.isEmpty else { return }
                hand(ForgeBriefs.askPrompt(model.detail, question: text, repoPath: store.repoPath(key)), store: store)
            }
        } message: {
            Text(model?.thread.map { "Goes to \($0.title)." } ?? "Starts a thread in \(key.ref.repoName) on \(store.hostName(key.host)).")
        }
    }

    // MARK: Parts

    private func head(_ model: ForgePullRequestModel) -> some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                ForgeTag(text: model.badge, tone: model.badgeTone)
                Text(model.byline).font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(1)
            }
            Text(model.detail.summary.title)
                .font(.shSans(MobileLayout.forgeItemTitle, .semibold))
                .foregroundStyle(sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            Text("\(model.detail.summary.headRef) \u{2192} \(model.detail.summary.baseRef)")
                .font(.sh(.mono))
                .foregroundStyle(sh.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel("\(model.detail.summary.headRef) into \(model.detail.summary.baseRef)")
            let labels = model.detail.labels ?? []
            if !labels.isEmpty {
                SHWrapStack { ForEach(labels, id: \.name) { ForgeTag(text: $0.name, tone: ForgeRows.tone(hex: $0.color)) } }
            }
            if let assignees = model.detail.assignees, !assignees.isEmpty {
                Text("Assigned to \(assignees.joined(separator: ", "))").font(.sh(.caption)).foregroundStyle(sh.textSecondary)
            }
        }
        .padding(.top, SH.Space.s)
    }

    @ViewBuilder private func summary(_ model: ForgePullRequestModel) -> some View {
        if let note = model.note {
            ForgeNoteCard(note: note, failed: model.detail.state == .closed)
        } else if !model.status.isEmpty {
            SHListCard {
                ForEach(model.status) { line in
                    HStack(spacing: SH.Space.l) {
                        Image(systemName: line.glyph).font(.sh(.ui, weight: .medium)).foregroundStyle(line.tone.color)
                            .frame(width: SHListMetrics.leadingWidth)
                            .accessibilityHidden(true)
                        Text(line.text).font(.sh(.body)).foregroundStyle(Color.sh.textPrimary).lineLimit(2)
                        Spacer(minLength: SH.Space.m)
                        if let trailing = line.trailing {
                            Text(trailing).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, SH.Space.l)
                    .frame(maxWidth: .infinity, minHeight: SH.Height.touch, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        if model.body.isEmpty {
            Text("No description.").shText(.caption).foregroundStyle(Color.sh.textTertiary)
        } else {
            ProseView(blocks: model.body).equatable()
        }
        if !model.activity.isEmpty {
            ForgeSectionHead(title: "Activity")
            ForgeActivityList(items: model.activity)
        }
    }

    @ViewBuilder private func bar(_ store: ForgeStore, _ model: ForgePullRequestModel?) -> some View {
        let busy = store.busy.contains(key) || handing
        HStack(spacing: SH.Space.m) {
            Button("Ask agent") { asking = true }
                .buttonStyle(.shReviewBar(.secondary))
            Button("Review\u{2026}") { store.sheet = ForgeSheet(key: key, kind: .review) }
                .buttonStyle(.shReviewBar(.secondary))
                .disabled(model.map { $0.detail.state != .open && $0.detail.state != .draft } ?? true)
            if let primary = model?.primary {
                Button(primary.label) { if let model { act(primary, model: model, store: store) } }
                    .buttonStyle(.shReviewBar(.primary))
            }
        }
        .disabled(model == nil || busy)
        .padding(.horizontal, layout.isPad ? MobileLayout.padThreadGutter - SH.Space.s : MobileLayout.gutter)
        .padding(.top, SH.Space.l)
        .padding(.bottom, SH.Space.s)
        .background(Color.sh.bgWindow)
        .overlay(alignment: .top) { SHHairline() }
    }

    @ViewBuilder private func menu(_ store: ForgeStore, _ model: ForgePullRequestModel?) -> some View {
        if let model {
            let pinned = store.isPinned(key)
            Button(pinned ? "Unpin" : "Pin", systemImage: SHGlyph.pin.symbolName) {
                Task { await store.setPinned(key, title: model.detail.summary.title, pinned: !pinned) }
            }
            if let thread = model.thread {
                Button("Open thread", systemImage: "bubble.left") { navigator.open(.thread(AgentRef(host: key.host, agent: thread.agentID))) }
            }
            if let url = URL(string: key.ref.url) {
                Link(destination: url) { Label("Open on GitHub", systemImage: "safari") }
            }
            ForgeEditMenus(store: store, key: key, labels: (model.detail.labels ?? []).map(\.name), assignees: model.detail.assignees ?? [],
                           reviewers: model.detail.state == .open || model.detail.state == .draft
                               ? model.detail.reviewers.filter { !$0.isTeam && $0.state == .pending }.map(\.login) : nil)
            switch model.detail.state {
            case .open:
                Button("Convert to draft", systemImage: "pencil.line") { change(.setDraft(ref: key.ref, draft: true), store) }
                Button("Close pull request", systemImage: "minus.circle") { change(.setOpen(ref: key.ref, open: false), store) }
            case .draft:
                Button("Ready for review", systemImage: "eye") { change(.setDraft(ref: key.ref, draft: false), store) }
                Button("Close pull request", systemImage: "minus.circle") { change(.setOpen(ref: key.ref, open: false), store) }
            case .closed:
                Button("Reopen", systemImage: "arrow.uturn.backward") { change(.setOpen(ref: key.ref, open: true), store) }
            case .merged:
                EmptyView()
            }
        }
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.loadPullRequest(key) } }
    }

    // MARK: Actions

    private func change(_ request: RemoteForgeRequest, _ store: ForgeStore) {
        Task { await store.change(request, for: key) }
    }

    private func act(_ action: ForgePrimaryAction, model: ForgePullRequestModel, store: ForgeStore) {
        switch action {
        case .merge: store.sheet = ForgeSheet(key: key, kind: .merge)
        case .markReady: change(.setDraft(ref: key.ref, draft: false), store)
        case .reopen: change(.setOpen(ref: key.ref, open: true), store)
        case .deleteBranch: change(.deleteBranch(ref: key.ref), store)
        case .cleanUp:
            Task {
                // The branch on GitHub first, then the worktree through Delete Worktree's own
                // confirmation.
                if !model.detail.headBranchDeleted, !model.detail.deletesBranchOnMerge {
                    guard await store.change(.deleteBranch(ref: key.ref), for: key) else { return }
                }
                if let agent = model.thread?.agentID { navigator.present(.search(.delete(AgentRef(host: key.host, agent: agent)))) }
            }
        }
    }

    private func fix(_ check: ForgeCheck, log: String?, model: ForgePullRequestModel, store: ForgeStore) {
        hand(ForgeBriefs.fixCheckPrompt(model.detail, check: check, log: log, repoPath: store.repoPath(key)), store: store)
    }

    private func hand(_ brief: ForgeBrief, store: ForgeStore) {
        guard !handing else { return }
        handing = true
        Task {
            if let problem = await ForgeAgent.run(brief, host: key.host, hosts: hosts, threads: threads, navigator: navigator) {
                store.failure = problem
            }
            handing = false
        }
    }
}

/// The card under a draft, merged or closed pull request's title (MobilePRStates).
struct ForgeNoteCard: View {
    let note: ForgeNote
    let failed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            Text(note.title).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
            Text(note.body).shText(.caption).foregroundStyle(Color.sh.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: MobileLayout.cardRadius, fill: failed ? Color.sh.failedTint : nil, line: failed ? .clear : nil)
        .accessibilityElement(children: .combine)
    }
}

/// A page still on its way (MobilePRStates' "Loading a pasted link").
struct ForgeFetching: View {
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
            RoundedRectangle(cornerRadius: MobileLayout.cardRadius).fill(Color.sh.bgRaised)
                .frame(height: MobileLayout.rowHeight * 1.5)
            SHLoadingRows().frame(height: MobileLayout.rowHeight * 2)
            Text("Fetching #\(number) from GitHub\u{2026}")
                .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, SH.Space.l)
        .accessibilityElement(children: .combine)
    }
}

/// Changes (MobilePRChanges): "5 files +200 −8" over "2 of 5 viewed · 3 comments", then each file.
private struct ForgeChangesTab: View {
    let key: ForgeItemKey
    let openFile: (String) -> Void
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let store = ForgeStore.of(hosts)
        let load = store.files[key]
        Group {
            if let model = load?.value {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    HStack(spacing: SH.Space.m) {
                        Text(model.totals.filesText).font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary)
                        SHDiffStat(added: model.totals.added, removed: model.totals.removed, font: .sh(.micro, weight: .regular))
                    }
                    Text(model.note).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
                .padding(SH.Space.l + SH.Space.xxs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .shCard(radius: MobileLayout.cardRadius)
                .accessibilityElement(children: .combine)
                SHLazyListCard(model.summaries) { summary in
                    Button { openFile(summary.path) } label: {
                        SHReviewFileRow(SHReviewFileRow.Item(summary), showsViewed: false, showsChevron: false).equatable()
                    }
                    .buttonStyle(.shRow(radius: 0))
                }
            } else if let error = load?.error {
                ForgeErrorState(error: error) { Task { await store.loadFiles(key) } }
            } else {
                SHLoadingRows().frame(height: MobileLayout.rowHeight * 2)
            }
        }
        .task(id: key) { if store.files[key]?.value == nil { await store.loadFiles(key) } }
    }
}

/// Checks (MobilePRChecks): each check with its dot and time, then each failing job's log tail
/// with Fix with agent.
private struct ForgeChecksTab: View {
    let key: ForgeItemKey
    let model: ForgePullRequestModel
    let fix: (ForgeCheck, String?) -> Void
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let store = ForgeStore.of(hosts)
        if model.checks.isEmpty {
            Text("No checks run on this pull request.").shText(.caption).foregroundStyle(Color.sh.textTertiary)
        } else {
            SHListCard {
                ForEach(model.checks) { row in
                    HStack(spacing: SH.Space.l) {
                        Circle().fill(row.tone.color).frame(width: MobileLayout.statusDot, height: MobileLayout.statusDot)
                        Text(row.name).font(.sh(.body)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                        Spacer(minLength: SH.Space.m)
                        if let duration = row.duration {
                            Text(duration).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
                        }
                    }
                    .padding(.horizontal, SH.Space.l)
                    .frame(maxWidth: .infinity, minHeight: SH.Height.touch + SH.Space.s, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.name), \(row.check.state.rawValue)\(row.duration.map { ", \($0)" } ?? "")")
                }
            }
            ForEach(model.failing) { row in
                let log = row.check.jobID.flatMap { store.logs[ForgeStore.logKey(host: key.host, repo: key.ref.repo, jobID: $0)] }
                VStack(spacing: 0) {
                    Group {
                        if let text = log?.value {
                            Text(text.isEmpty ? "The log has no failure lines." : text)
                        } else if let error = log?.error {
                            Text(error.message)
                        } else if row.check.jobID == nil {
                            Text("\(row.name) failed. Its log isn't on GitHub Actions.")
                        } else {
                            Text("Reading the log\u{2026}")
                        }
                    }
                    .font(.sh(.mono))
                    .foregroundStyle(Color.sh.textSecondary)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SH.Space.l)
                    .textSelection(.enabled)
                    SHHairline()
                    Button { fix(row.check, log?.value) } label: {
                        Text("Fix with agent").font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.running)
                            .frame(maxWidth: .infinity, minHeight: SH.Height.touch)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.shRow(radius: 0))
                    .accessibilityHint("Hands \(row.name) and its log to an agent")
                }
                .clipShape(RoundedRectangle(cornerRadius: MobileLayout.cardRadius))
                .shCard(radius: MobileLayout.cardRadius)
                .task(id: row.check.jobID) {
                    if let job = row.check.jobID { await store.loadLog(host: key.host, repo: key.ref.repo, jobID: job) }
                }
            }
        }
    }
}
