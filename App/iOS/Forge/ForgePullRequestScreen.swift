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
                        ReviewSegmented(selection: tab, options: [
                            .init(value: .summary, title: "Summary"),
                            .init(value: .changes, title: "Changes", note: "\(model.detail.changedFiles)"),
                            .init(value: .checks, title: "Checks", note: Self.checksNote(model)),
                        ])
                        if let failure = store.failure {
                            SHBanner(.failed, title: failure) {
                                Button("OK") { store.failure = nil }.buttonStyle(.sh(.secondary))
                            }
                        }
                        switch tab.wrappedValue {
                        case .summary: summary(model, tab: tab)
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
        let summary = model.detail.summary
        // "Open · baily · 2h ago", then "agent/refund-events into main" (beside it on iPad).
        let branches = Text(summary.headRef).font(.shMono(MobileLayout.touchDetailFont - 1))
            + Text(" into ").font(.shSans(MobileLayout.touchDetailFont))
            + Text(summary.baseRef).font(.shMono(MobileLayout.touchDetailFont - 1))
        return VStack(alignment: .leading, spacing: SH.Space.xs) {
            Text(summary.title)
                .font(.shSans(MobileLayout.forgeItemTitle, .bold))
                .foregroundStyle(sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if layout.isPad {
                (Text("\(model.badge) \u{00B7} \(model.byline) \u{00B7} ").font(.shSans(MobileLayout.touchDetailFont)) + branches)
                    .foregroundStyle(sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            } else {
                Text("\(model.badge) \u{00B7} \(model.byline)")
                    .font(.shSans(MobileLayout.touchDetailFont))
                    .foregroundStyle(sh.textSecondary)
                branches
                    .foregroundStyle(sh.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("\(summary.headRef) into \(summary.baseRef)")
            }
            let labels = model.detail.labels ?? []
            if !labels.isEmpty {
                SHWrapStack { ForEach(labels, id: \.name) { ForgeTag(text: $0.name) } }
                    .padding(.top, SH.Space.xs)
            }
            if let assignees = model.detail.assignees, !assignees.isEmpty {
                Text("Assigned to \(assignees.joined(separator: ", "))")
                    .font(.shSans(MobileLayout.touchDetailFont)).foregroundStyle(sh.textSecondary)
            }
        }
        .padding(.horizontal, SH.Space.xs)
    }

    /// "1 failed", "running", or how many ran: what follows Checks in the switch.
    private static func checksNote(_ model: ForgePullRequestModel) -> String? {
        if !model.failing.isEmpty { return "\(model.failing.count) failed" }
        if model.checksTone == .running { return "running" }
        return model.checks.isEmpty ? nil : "\(model.checks.count)"
    }

    @ViewBuilder private func summary(_ model: ForgePullRequestModel, tab: Binding<ForgeTab>) -> some View {
        let sh = Color.sh
        if let note = model.note, model.detail.state == .closed {
            ForgeNoteCard(note: note)
        }
        if let note = model.note, model.detail.state != .closed {
            Text("\(note.title). \(note.body)")
                .font(.shSans(MobileLayout.touchDetailFont))
                .foregroundStyle(sh.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SH.Space.xs)
        }
        if model.detail.state != .closed, !model.status.isEmpty {
            ReviewCard {
                ForEach(model.status) { line in
                    let failing = line.id == "checks" ? model.failing.first : nil
                    let row = HStack(spacing: SH.Space.l) {
                        Image(systemName: Self.glyph(line.glyph))
                            .font(.shSans(MobileLayout.touchBodyFont + 3))
                            .foregroundStyle(sh.textSecondary)
                            .frame(width: MobileLayout.touchGlyphColumn)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: SH.Space.xxs) {
                            Text(line.text).font(.shSans(MobileLayout.touchBodyFont, .medium)).foregroundStyle(sh.textPrimary).lineLimit(2)
                            if let failing {
                                Text("\(failing.name) failed").font(.shSans(MobileLayout.touchDetailFont)).foregroundStyle(sh.failed).lineLimit(1)
                            }
                        }
                        Spacer(minLength: SH.Space.m)
                        if line.id == "checks" {
                            Image(systemName: "chevron.right")
                                .font(.shSans(MobileLayout.touchDetailFont, .medium))
                                .foregroundStyle(sh.textTertiary)
                                .accessibilityHidden(true)
                        } else if let trailing = line.trailing {
                            Text(trailing).font(.shSans(MobileLayout.touchDetailFont)).foregroundStyle(sh.textTertiary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, MobileLayout.gutter)
                    .padding(.vertical, SH.Space.m + SH.Space.xxs)
                    .frame(maxWidth: .infinity, minHeight: MobileLayout.touchRowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                    if line.id == "checks" {
                        Button { tab.wrappedValue = .checks } label: { row }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityHint("Shows the checks")
                    } else {
                        row.accessibilityElement(children: .combine)
                    }
                }
            }
        }
        if model.body.isEmpty {
            Text("No description.").shText(.caption).foregroundStyle(sh.textTertiary).padding(.horizontal, SH.Space.xs)
        } else {
            ProseView(prose: model.body).equatable().padding(.horizontal, SH.Space.xs)
        }
        if !model.activity.isEmpty {
            ReviewSectionHead(title: "Activity")
            ForgeActivityList(items: model.activity)
        }
    }

    /// The status line's glyph, in the boards' outlined set.
    private static func glyph(_ name: String) -> String {
        switch name {
        case ForgeRows.changesGlyph: "bubble.left"
        case ForgeRows.failedGlyph: SHGlyph.failedStep.symbolName
        case ForgeRows.passedGlyph: SHGlyph.resolved.symbolName
        default: name
        }
    }

    @ViewBuilder private func bar(_ store: ForgeStore, _ model: ForgePullRequestModel?) -> some View {
        let busy = store.busy.contains(key) || handing
        ReviewGlassBar(horizontalInset: layout.isPad ? MobileLayout.padThreadGutter - SH.Space.s : MobileLayout.gutter) {
            ReviewGlassBarItem(title: "Ask agent") { asking = true }
            // A merged or closed pull request takes no review.
            if model.map({ $0.detail.state == .open || $0.detail.state == .draft }) ?? true {
                ReviewGlassBarItem(title: "Review\u{2026}") { store.sheet = ForgeSheet(key: key, kind: .review) }
                    .disabled(model == nil)
            }
            if let primary = model?.primary {
                ReviewGlassBarItem(title: primary.label, emphasis: .main) { if let model { act(primary, model: model, store: store) } }
            }
        }
        .disabled(model == nil || busy)
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

/// The card under a closed pull request's title (MobilePRStates' "Closed without merging"): the
/// glyph, the words, and what stays.
struct ForgeNoteCard: View {
    let note: ForgeNote

    var body: some View {
        let sh = Color.sh
        ReviewCard {
            HStack(spacing: SH.Space.l) {
                Image(systemName: SHGlyph.failedStep.symbolName)
                    .font(.shSans(MobileLayout.touchBodyFont + 3))
                    .foregroundStyle(sh.textSecondary)
                    .frame(width: MobileLayout.touchGlyphColumn)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(note.title).font(.shSans(MobileLayout.touchBodyFont, .medium)).foregroundStyle(sh.textPrimary)
                    Text(note.body).font(.shSans(MobileLayout.touchDetailFont)).foregroundStyle(sh.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.vertical, SH.Space.m + SH.Space.xxs)
            .frame(maxWidth: .infinity, minHeight: MobileLayout.touchRowHeight, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

/// A page still on its way (MobilePRStates' "Loading a pasted link").
struct ForgeFetching: View {
    let number: Int

    var body: some View {
        Text("Fetching #\(number) from GitHub\u{2026}")
            .font(.shSans(MobileLayout.touchDetailFont))
            .foregroundStyle(Color.sh.textTertiary)
            .shShimmer(active: true)
            .frame(maxWidth: .infinity, minHeight: MobileLayout.touchRowHeight * 4)
            .accessibilityLabel("Fetching #\(number) from GitHub")
    }
}

/// Changes (MobilePRChanges): "5 files +15 −2" over "0 of 5 viewed · 1 comment", then each file.
private struct ForgeChangesTab: View {
    let key: ForgeItemKey
    let openFile: (String) -> Void
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let store = ForgeStore.of(hosts)
        let load = store.files[key]
        Group {
            if let model = load?.value {
                HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                    Text(model.totals.filesText).font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary)
                    SHDiffStat(added: model.totals.added, removed: model.totals.removed, font: .shSans(MobileLayout.touchBodyFont))
                    Spacer(minLength: SH.Space.m)
                    Text(model.note)
                        .font(.shSans(MobileLayout.touchDetailFont))
                        .foregroundStyle(Color.sh.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, SH.Space.xs)
                .accessibilityElement(children: .combine)
                ReviewLazyCard(model.summaries) { summary in
                    Button { openFile(summary.path) } label: {
                        SHReviewFileRow(SHReviewFileRow.Item(summary)).equatable()
                    }
                    .buttonStyle(.plain)
                }
            } else if let error = load?.error {
                ForgeErrorState(error: error) { Task { await store.loadFiles(key) } }
            } else {
                SHBusyLabel("Loading the files\u{2026}")
                    .frame(maxWidth: .infinity, minHeight: SH.Height.touch * 2)
            }
        }
        .task(id: key) { if store.files[key]?.value == nil { await store.loadFiles(key) } }
    }
}

/// Checks (MobilePRChecks): the failed ones, each a card with its log tail and Fix with agent,
/// then the rest by how they ended.
private struct ForgeChecksTab: View {
    let key: ForgeItemKey
    let model: ForgePullRequestModel
    let fix: (ForgeCheck, String?) -> Void
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let store = ForgeStore.of(hosts)
        if model.checks.isEmpty {
            Text("No checks run on this pull request.").shText(.caption).foregroundStyle(Color.sh.textTertiary)
                .padding(.horizontal, SH.Space.xs)
        } else {
            if !model.failing.isEmpty {
                ReviewSectionHead(title: "Failed", count: "\(model.failing.count)")
                ForEach(model.failing) { row in failed(row, store: store) }
            }
            group("Running", model.checks.filter { $0.check.state == .running })
            group("Passed", model.checks.filter { $0.check.state == .passed })
            group("Skipped", model.checks.filter { $0.check.state == .skipped })
        }
    }

    @ViewBuilder private func group(_ title: String, _ rows: [ForgeCheckRow]) -> some View {
        if !rows.isEmpty {
            ReviewSectionHead(title: title, count: "\(rows.count)")
            ReviewCard {
                ForEach(rows) { row in
                    HStack(spacing: SH.Space.l) {
                        Text(row.name).font(.shSans(MobileLayout.touchBodyFont, .medium)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                        Spacer(minLength: SH.Space.m)
                        if let duration = row.duration {
                            Text(duration).font(.shSans(MobileLayout.touchDetailFont)).foregroundStyle(Color.sh.textTertiary)
                        }
                    }
                    .padding(.horizontal, MobileLayout.gutter)
                    .frame(maxWidth: .infinity, minHeight: MobileLayout.touchRowHeight, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.name), \(row.check.state.rawValue)\(row.duration.map { ", \($0)" } ?? "")")
                }
            }
        }
    }

    private func failed(_ row: ForgeCheckRow, store: ForgeStore) -> some View {
        let sh = Color.sh
        let log = row.check.jobID.flatMap { store.logs[ForgeStore.logKey(host: key.host, repo: key.ref.repo, jobID: $0)] }
        return VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.l) {
                Text(row.name).font(.shSans(MobileLayout.touchBodyFont, .medium)).foregroundStyle(sh.textPrimary).lineLimit(1)
                Spacer(minLength: SH.Space.m)
                if let duration = row.duration {
                    Text(duration).font(.shSans(MobileLayout.touchDetailFont)).foregroundStyle(sh.textTertiary)
                }
            }
            Group {
                if let text = log?.value {
                    Text(text.isEmpty ? "The log has no failure lines." : text)
                } else if let error = log?.error {
                    Text(error.message)
                } else if row.check.jobID == nil {
                    Text("\(row.name) failed. Its log isn't on GitHub Actions.")
                } else {
                    Text("Reading the log\u{2026}").shShimmer(active: true)
                }
            }
            .font(.shMono(MobileLayout.touchDetailFont - 1))
            .foregroundStyle(sh.textSecondary)
            .lineLimit(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SH.Space.l)
            .padding(.vertical, SH.Space.m + SH.Space.xxs)
            .background(sh.bgHover, in: RoundedRectangle(cornerRadius: SH.Radius.l))
            .textSelection(.enabled)
            HStack(spacing: SH.Space.xl + SH.Space.xs) {
                Button("Fix with agent") { fix(row.check, log?.value) }
                    .buttonStyle(.shLink(color: sh.textPrimary, font: .shSans(MobileLayout.touchBodyFont, .medium)))
                    .accessibilityHint("Hands \(row.name) and its log to an agent")
                if let link = row.check.detailsURL.flatMap(URL.init(string:)) {
                    Link("Open on GitHub", destination: link)
                        .font(.shSans(MobileLayout.touchBodyFont))
                        .foregroundStyle(sh.textSecondary)
                }
            }
            .frame(minHeight: SH.Height.touch - SH.Space.m)
        }
        .padding(.horizontal, MobileLayout.gutter)
        .padding(.top, SH.Space.l + SH.Space.xxs)
        .padding(.bottom, SH.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: MobileLayout.touchCardRadius, lift: true)
        .task(id: row.check.jobID) {
            if let job = row.check.jobID { await store.loadLog(host: key.host, repo: key.ref.repo, jobID: job) }
        }
    }
}
