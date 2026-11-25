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
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            Text(model.detail.summary.title)
                .font(.shSans(MobileLayout.forgeItemTitle, .bold))
                .foregroundStyle(sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            // "Open · mara opened 1h ago · assigned to you"
            Text("\(model.badge) \u{00B7} \(model.byline)").font(.shSans(MobileLayout.touchDetailFont)).foregroundStyle(sh.textSecondary)
            // The byline already says "assigned to you"; name the others.
            let viewer = model.detail.viewer?.lowercased()
            let others = model.detail.summary.assignees.filter { $0.lowercased() != viewer }
            if !others.isEmpty {
                Text("Assigned to \(((model.detail.summary.assignedToViewer ? ["you"] : []) + others).joined(separator: ", "))")
                    .font(.shSans(MobileLayout.touchDetailFont)).foregroundStyle(sh.textSecondary)
            }
            // Labels wrap where a narrow column can't hold them in one line.
            if !model.labels.isEmpty {
                SHWrapStack { ForEach(model.labels) { label in ForgeTag(text: label.name) } }
                    .padding(.top, SH.Space.s)
            }
        }
        .padding(.horizontal, SH.Space.xs)
        if let failure = store.failure {
            SHBanner(.failed, title: failure) {
                Button("OK") { store.failure = nil }.buttonStyle(.sh(.secondary))
            }
        }
        if model.body.isEmpty {
            Text("No description.").shText(.caption).foregroundStyle(sh.textTertiary).padding(.horizontal, SH.Space.xs)
        } else {
            ProseView(prose: model.body).equatable().padding(.horizontal, SH.Space.xs)
        }
        if model.detail.summary.state == .open {
            handOff(model, store: store)
        }
        if !model.comments.isEmpty {
            ReviewSectionHead(title: "Comments", count: "\(model.comments.count)")
            ForgeActivityList(items: model.comments)
        }
    }

    /// Hand it to an agent: what Start a thread does, and where it runs.
    @ViewBuilder private func handOff(_ model: ForgeIssueModel, store: ForgeStore) -> some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.s) {
            if let thread = model.thread {
                Text("An agent has it").font(.shSans(MobileLayout.touchBodyFont + 2, .semibold)).foregroundStyle(sh.textPrimary)
                Text("\(thread.title) works on this issue\(thread.branch.map { " on \($0)" } ?? "").")
                    .font(.shSans(MobileLayout.touchBodyFont)).lineSpacing(SH.Space.xxs).foregroundStyle(sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Hand it to an agent").font(.shSans(MobileLayout.touchBodyFont + 2, .semibold)).foregroundStyle(sh.textPrimary)
                Text("Starts a thread on a new worktree with this issue as the brief. The PR it opens links back here.")
                    .font(.shSans(MobileLayout.touchBodyFont)).lineSpacing(SH.Space.xxs).foregroundStyle(sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SHWrapStack {
                    ForgeTag(text: store.hostName(key.host), mono: true)
                    ForgeTag(text: "new worktree", mono: true)
                }
                .padding(.top, SH.Space.xs)
            }
        }
        .reviewCardPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: MobileLayout.touchCardRadius, lift: true)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func bar(_ store: ForgeStore, _ model: ForgeIssueModel?) -> some View {
        ReviewGlassBar(horizontalInset: layout.isPad ? MobileLayout.padThreadGutter - SH.Space.s : MobileLayout.gutter) {
            ReviewGlassBarItem(title: "Comment") { store.sheet = ForgeSheet(key: key, kind: .comment) }
            if let thread = model?.thread {
                ReviewGlassBarItem(title: "Open thread", emphasis: .main) {
                    navigator.open(.thread(AgentRef(host: key.host, agent: thread.agentID)))
                }
            } else if model?.detail.summary.state == .open {
                ReviewGlassBarItem(title: "Start a thread", emphasis: .main) { if let model { start(model, store: store) } }
                    .disabled(handing)
                    .accessibilityHint("Starts a thread on \(store.hostName(key.host)) on a new worktree for this issue")
            } else if model?.detail.summary.state == .closed {
                ReviewGlassBarItem(title: "Reopen", emphasis: .main) {
                    Task { await store.change(.setOpen(ref: key.ref, open: true), for: key) }
                }
            }
        }
        .disabled(model == nil || store.busy.contains(key))
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
