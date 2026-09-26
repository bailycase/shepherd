import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// An agent's changes on iPhone (MobileChanges board): "Changes" over the scope ("Branch · vs
/// main ⌄", the scope menu), the summary with the branch and viewed progress, the file list
/// (each opens its diff), your comments, then Send 1 comment and Commit…, which send the agent
/// its next turn or commit on the host. A worktree agent's summary offers Finalize.
struct ChangesScreen: View {
    let ref: AgentRef
    let file: String?
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let store = ReviewStores.shared.store(for: ref)
        let host = hosts.host(ref.host)
        let agent = host?.agent(ref.agent)
        let highlighted = store.entry(matching: file)?.id
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MobileLayout.reviewCardSpacing) {
                    if let error = store.loadError, store.loaded {
                        NWBanner(.failed, title: "Couldn't refresh the changes", message: error)
                    }
                    let branch = store.overview?.branch ?? agent?.worktreeBranch
                    if !store.entries.isEmpty || branch != nil {
                        ReviewSummaryCard(totals: store.totals, branch: branch,
                                          onFinalize: ReviewFinalizeGate.available(host: host, agent: agent)
                                            ? { navigator.present(.review(.finalize(ref))) } : nil)
                    }
                    ReviewLoadState(store: store) { store.refresh() }
                    if !store.entries.isEmpty {
                        ReviewSectionHead(title: "Files", note: "tap to read the diff")
                        VStack(spacing: 0) {
                            ForEach(store.summaries) { summary in
                                Button { navigator.open(.review(.diff(ref, path: summary.path))) } label: {
                                    NWReviewFileRow(NWReviewFileRow.Item(summary), selected: summary.id == highlighted).equatable()
                                }
                                .buttonStyle(.plain)
                                .id(summary.id)
                                if summary.id != store.summaries.last?.id { NWHairline() }
                            }
                        }
                        .nwCard(radius: MobileLayout.cardRadius)
                        if !store.comments.isEmpty {
                            ReviewSectionHead(title: "Your comments", note: "\(store.comments.count)")
                                .padding(.top, NW.Space.s)
                            ForEach(store.comments) { comment in
                                ReviewCommentCard(comment: comment, showsFile: true,
                                                  onEdit: { open(comment, store: store) },
                                                  onDelete: { store.deleteComment(fileID: comment.fileID, lineID: comment.lineID) })
                            }
                        }
                    }
                }
                .padding(MobileLayout.gutter - NW.Space.xxs)
            }
            .onChange(of: store.summaries.count, initial: true) { _, _ in
                if let highlighted { proxy.scrollTo(highlighted, anchor: .center) }
            }
        }
        .background(Color.nw.bgBase)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ReviewActionBar(store: store, commitDirectly: CommitHooks.available(host: host)
                            ? { navigator.present(.review(.commit(ref))) } : nil) { sent in if sent { dismiss() } }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("Changes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChangesTitle(store: store) { store.pickingBase = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ReviewOptionsMenu(store: store, finalize: ReviewFinalizeGate.available(host: host, agent: agent)
                                  ? { navigator.present(.review(.finalize(ref))) } : nil,
                                  askAgentToCommit: CommitHooks.available(host: host) ? { dismiss() } : nil)
            }
        }
        .sheet(isPresented: Binding(get: { store.pickingBase }, set: { store.pickingBase = $0 })) {
            ChangesBasePicker(store: store) { store.pickingBase = false }
        }
        .task(id: host?.session) { await store.loadIfNeeded(hosts: hosts) }
        .onChange(of: store.pullRequest) { _, _ in store.refresh() }
    }

    /// A comment in the list opens its file's diff with its line selected.
    private func open(_ comment: ReviewComment, store: ReviewStore) {
        store.select(fileID: comment.fileID, lineID: comment.lineID)
        navigator.open(.review(.diff(ref, path: comment.filePath)))
    }
}

/// Send 1 comment and Commit… (MobileChanges board), with why a send failed above them. Where
/// the host commits from review, Commit… opens the commit (MobileCommit board) and asking the
/// agent moves to the options menu.
struct ReviewActionBar: View {
    let store: ReviewStore
    /// Opens the commit sheet; nil where the host only takes Commit as a turn.
    var commitDirectly: (() -> Void)? = nil
    /// Called with whether the host took the review.
    let finished: (Bool) -> Void
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: NW.Space.m) {
            if let error = store.actionError {
                NWBanner(.failed, title: "Couldn't send the review", message: error) {
                    Button("Dismiss") { store.actionError = nil }.buttonStyle(.nw(.ghost, size: .s))
                }
            }
            // Side by side, or stacked where an accessibility text size would cut the labels.
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: NW.Space.m)) : AnyLayout(HStackLayout(spacing: NW.Space.m))
            layout {
                Button(store.sendTitle) {
                    Task { finished(await store.sendComments(hosts: hosts)) }
                }
                .buttonStyle(.nwReviewBar(.secondary))
                .disabled(!store.canSend)
                .accessibilityHint(store.comments.isEmpty ? "Tap a line in a diff to comment on it" : "Sends your comments as the agent's next message")
                if let commitDirectly {
                    Button("Commit\u{2026}", action: commitDirectly)
                        .buttonStyle(.nwReviewBar(.primary))
                        .disabled(!store.canCommit)
                        .accessibilityHint("Choose the files and message, then commit on the host")
                } else {
                    Button("Commit") {
                        Task { finished(await store.commit(hosts: hosts)) }
                    }
                    .buttonStyle(.nwReviewBar(.primary))
                    .disabled(!store.canCommit)
                    .accessibilityHint("Asks the agent to commit these changes")
                }
            }
        }
        .padding(.horizontal, MobileLayout.gutter - NW.Space.xxs)
        .padding(.top, NW.Space.l)
        .padding(.bottom, NW.Space.s)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .top) { NWHairline() }
    }
}

/// The review's options: refresh, Discard comments, Ask agent to commit where Commit… commits
/// directly (`askAgentToCommit` runs once the agent took it), and Finalize for a worktree agent.
/// What to compare is the title's menu.
struct ReviewOptionsMenu: View {
    @Bindable var store: ReviewStore
    let finalize: (() -> Void)?
    var askAgentToCommit: (() -> Void)? = nil
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        Menu {
            Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }
            if !store.comments.isEmpty {
                Button("Discard comments", systemImage: "trash", role: .destructive) { store.discardComments() }
            }
            if let askAgentToCommit {
                Button("Ask agent to commit", systemImage: "text.bubble") {
                    Task { if await store.commit(hosts: hosts) { askAgentToCommit() } }
                }
                .disabled(!store.canCommit)
            }
            if let finalize {
                Button("Finalize worktree…", systemImage: "checkmark.seal", action: finalize)
            }
        } label: {
            Label("Review options", systemImage: "ellipsis")
        }
    }
}

/// Finalize is offered for a worktree agent on a host that runs it remotely.
enum ReviewFinalizeGate {
    @MainActor static func available(host: MobileHost?, agent: Agent?) -> Bool {
        guard let host, agent?.worktreeBranch != nil else { return false }
        return host.supports(RemoteProtocol.worktreeActionsCapability) && host.supports(RemoteProtocol.worktreeSetupCapability)
    }
}
