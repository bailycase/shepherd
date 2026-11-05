import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// One issue on iPhone (MobileIssue): "#34" over "payments · Issue" in the bar.
struct ForgeIssueScreen: View {
    let key: ForgeItemKey

    var body: some View {
        VerticalBars { verticalBars in ForgeIssueContent(key: key, layout: .phone(verticalBars: verticalBars)) }
    }
}

/// An issue's page (MobileIssue, iPadIssue, DuoBookIssue): its state and labels, title, who
/// opened it, the body, Hand it to an agent, the comments; Comment and Start a thread
/// (`ForgeBriefs.issueThreadPrompt`, a new worktree named after the issue).
struct ForgeIssueContent: View {
    let key: ForgeItemKey
    let layout: ForgeDetailLayout
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(ThreadStores.self) private var threads
    @State private var handing = false

    var body: some View {
        let store = ForgeStore.of(hosts)
        let load = store.issues[key]
        let model = load?.value
        let title = "#\(key.ref.number)"
        let subtitle = model?.subtitle ?? "\(key.ref.repoName) · Issue"
        VStack(spacing: 0) {
            if layout.isPad {
                ForgePadHead(title: title, subtitle: subtitle, verticalBars: layout.verticalBars) { menu(store, model) }
            } else if layout.verticalBars {
                ForgeTitle(title: title, subtitle: subtitle).frame(maxWidth: .infinity).padding(.vertical, SH.Space.s)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                    if let model {
                        page(model, store: store)
                    } else if let error = load?.error {
                        ForgeErrorState(error: error) { Task { await store.loadIssue(key) } }
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
            await store.loadIssue(key)
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
        .sheet(item: Binding(get: { store.sheet?.key == key ? store.sheet : nil }, set: { if $0 == nil { store.sheet = nil } })) { _ in
            ForgeCommentSheet(key: key)
        }
    }

    @ViewBuilder private func page(_ model: ForgeIssueModel, store: ForgeStore) -> some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.m) {
            // Tags wrap where a narrow column can't hold them in one line.
            SHWrapStack {
                ForgeTag(text: model.badge, tone: model.badgeTone)
                ForEach(model.labels) { label in ForgeTag(text: label.name, tone: label.tone) }
            }
            Text(model.detail.summary.title)
                .font(.shSans(MobileLayout.forgeItemTitle, .semibold))
                .foregroundStyle(sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            Text(model.byline).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
            // The byline already says "assigned to you"; name the others.
            let viewer = model.detail.viewer?.lowercased()
            let others = model.detail.summary.assignees.filter { $0.lowercased() != viewer }
            if !others.isEmpty {
                Text("Assigned to \(((model.detail.summary.assignedToViewer ? ["you"] : []) + others).joined(separator: ", "))")
                    .font(.sh(.caption)).foregroundStyle(sh.textSecondary)
            }
        }
        .padding(.top, SH.Space.s)
        if let failure = store.failure {
            SHBanner(.failed, title: failure) {
                Button("OK") { store.failure = nil }.buttonStyle(.sh(.secondary))
            }
        }
        if model.body.isEmpty {
            Text("No description.").shText(.caption).foregroundStyle(sh.textTertiary)
        } else {
            ProseView(blocks: model.body).equatable()
        }
        if model.detail.summary.state == .open {
            handOff(model, store: store)
        }
        if !model.comments.isEmpty {
            ForgeSectionHead(title: "Comments")
            ForgeActivityList(items: model.comments)
        }
    }

    /// Hand it to an agent: what Start a thread does, and where it runs.
    @ViewBuilder private func handOff(_ model: ForgeIssueModel, store: ForgeStore) -> some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.m) {
            if let thread = model.thread {
                Text("An agent has it").font(.sh(.headline)).foregroundStyle(sh.textPrimary)
                Text("\(thread.title) works on this issue\(thread.branch.map { " on \($0)" } ?? "").")
                    .shText(.caption).foregroundStyle(sh.textSecondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Hand it to an agent").font(.sh(.headline)).foregroundStyle(sh.textPrimary)
                Text("Starts a thread on a new worktree with this issue as the brief. The PR it opens links back here.")
                    .shText(.caption).foregroundStyle(sh.textSecondary).fixedSize(horizontal: false, vertical: true)
                SHWrapStack {
                    SHTag(store.hostName(key.host), mono: true)
                    SHTag("new worktree", mono: true)
                }
            }
        }
        .padding(SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: MobileLayout.cardRadius)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func bar(_ store: ForgeStore, _ model: ForgeIssueModel?) -> some View {
        HStack(spacing: SH.Space.m) {
            Button("Comment") { store.sheet = ForgeSheet(key: key, kind: .comment) }
                .buttonStyle(.shReviewBar(.secondary))
                .frame(maxWidth: SH.Height.touch * 3)
            if let thread = model?.thread {
                Button("Open thread") { navigator.open(.thread(AgentRef(host: key.host, agent: thread.agentID))) }
                    .buttonStyle(.shReviewBar(.primary))
            } else if model?.detail.summary.state == .open {
                Button("Start a thread") { if let model { start(model, store: store) } }
                    .buttonStyle(.shReviewBar(.primary))
                    .disabled(handing)
                    .accessibilityHint("Starts a thread on \(store.hostName(key.host)) on a new worktree for this issue")
            } else if model?.detail.summary.state == .closed {
                Button("Reopen") { Task { await store.change(.setOpen(ref: key.ref, open: true), for: key) } }
                    .buttonStyle(.shReviewBar(.primary))
            }
        }
        .disabled(model == nil || store.busy.contains(key))
        .padding(.horizontal, layout.isPad ? MobileLayout.padThreadGutter - SH.Space.s : MobileLayout.gutter)
        .padding(.top, SH.Space.l)
        .padding(.bottom, SH.Space.s)
        .background(Color.sh.bgWindow)
        .overlay(alignment: .top) { SHHairline() }
    }

    @ViewBuilder private func menu(_ store: ForgeStore, _ model: ForgeIssueModel?) -> some View {
        if let model {
            let pinned = store.isPinned(key)
            Button(pinned ? "Unpin" : "Pin", systemImage: SHGlyph.pin.symbolName) {
                Task { await store.setPinned(key, title: model.detail.summary.title, pinned: !pinned) }
            }
            if let url = URL(string: key.ref.url) {
                Link(destination: url) { Label("Open on GitHub", systemImage: "safari") }
            }
            ForgeEditMenus(store: store, key: key, labels: model.detail.summary.labels.map(\.name),
                           assignees: model.detail.summary.assignees, reviewers: nil)
            if model.detail.summary.state == .open {
                Button("Close issue", systemImage: "minus.circle") { Task { await store.change(.setOpen(ref: key.ref, open: false), for: key) } }
            } else {
                Button("Reopen", systemImage: "arrow.uturn.backward") { Task { await store.change(.setOpen(ref: key.ref, open: true), for: key) } }
            }
        }
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.loadIssue(key) } }
    }

    private func start(_ model: ForgeIssueModel, store: ForgeStore) {
        guard !handing else { return }
        handing = true
        Task {
            let brief = ForgeBriefs.issueThreadPrompt(model.detail, repoPath: store.repoPath(key))
            if let problem = await ForgeAgent.run(brief, host: key.host, hosts: hosts, threads: threads, navigator: navigator) {
                store.failure = problem
            }
            handing = false
        }
    }
}
