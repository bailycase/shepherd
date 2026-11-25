import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Commit on iPhone (MobileCommit board), presented over the changes: the message drafted from
/// the diff, the files (all ticked), Push after commit or Open a pull request instead, then
/// Commit & push. Once it runs, the host's steps. Ask agent to commit sends the agent the turn
/// the review's Commit sent before, for a reviewer who would rather it did the commit.
struct CommitScreen: View {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let store = CommitStores.shared.store(for: ref, hosts: hosts)
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                switch store.stage {
                case .loading:
                    HStack(spacing: SH.Space.m) {
                        Text("Reading the changes on the host…").font(.sh(.ui)).shShimmer(active: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: SH.Height.touch * 2)
                case .unavailable(let message):
                    SHBanner(.failed, title: "Can't commit from here", message: message)
                case .form:
                    CommitNotices(store: store)
                    ReviewSectionHead(title: "Message")
                    CommitMessageCard(store: store)
                    ReviewSectionHead(title: "Files", note: store.selectionText)
                    CommitFileList(store: store)
                    CommitOptions(store: store)
                        .padding(.top, SH.Space.xs)
                case .operation:
                    CommitProgress(store: store)
                }
            }
            .disabled(store.info?.blocked != nil && store.stage == .form)
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.gutter)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.sh.bgWindow)
        .safeAreaInset(edge: .bottom, spacing: 0) { actions(store) }
        .navigationTitle(commitTitle(store))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(store.stage == .operation ? "Close" : "Cancel", systemImage: "xmark") { close(store) }
                    .labelStyle(.iconOnly)
                    .tint(Color.sh.textPrimary)
            }
        }
        .task { await store.begin() }
        .task(id: store.operationID) {
            guard store.operationID != nil else { return }
            await store.poll()
        }
    }

    @ViewBuilder private func actions(_ store: ReviewCommitStore) -> some View {
        VStack(spacing: SH.Space.s) {
            switch store.stage {
            case .loading, .unavailable:
                EmptyView()
            case .form:
                if let problem = store.problem, store.info?.blocked == nil {
                    Text(problem).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
                Button(store.actionTitle) { Task { await store.commit() } }
                    .buttonStyle(.reviewPrimaryPill)
                    .disabled(!store.canCommit)
                Button("Ask agent to commit") { askAgent() }
                    .buttonStyle(.shLink(color: Color.sh.textPrimary, font: .shSans(MobileLayout.touchBodyFont, .medium)))
                    .frame(minHeight: SH.Height.touch)
                    .accessibilityHint("Sends the agent a turn asking it to commit these changes instead")
            case .operation:
                if store.operation?.finished == true {
                    Button("Done") { close(store) }
                        .buttonStyle(.reviewPrimaryPill)
                } else {
                    Text("The commit continues on the host if you close this.")
                        .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MobileLayout.gutter)
        .padding(.top, SH.Space.l)
        .padding(.bottom, SH.Space.xs)
        .background(LinearGradient(colors: [Color.sh.bgWindow.opacity(0), Color.sh.bgWindow], startPoint: .top, endPoint: .init(x: 0.5, y: 0.2)))
    }

    /// Closing a finished commit (or one whose outcome never came back) reloads the changes, so
    /// what was committed leaves the list.
    private func close(_ store: ReviewCommitStore) {
        navigator.dismissPresented()
        let succeeded = if case .succeeded = store.outcome { true } else { false }
        if store.closed(), !succeeded || !navigator.finishQueuedReview(ref, hosts: hosts) {
            Task { await ReviewStores.shared.store(for: ref).load(hosts: hosts) }
        }
    }

    private func askAgent() {
        let review = ReviewStores.shared.store(for: ref)
        Task {
            if await review.commit(hosts: hosts) {
                navigator.dismissPresented()
                navigator.finishQueuedReview(ref, hosts: hosts)
            } else {
                CommitStores.shared.store(for: ref, hosts: hosts).error = review.actionError
            }
        }
    }
}
