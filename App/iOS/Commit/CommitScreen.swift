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
                    HStack(spacing: NW.Space.m) {
                        ProgressView().progressViewStyle(NWSpinnerStyle())
                        Text("Reading the changes on the host…").font(.nw(.ui)).foregroundStyle(Color.nw.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: NW.Height.touch * 2)
                case .unavailable(let message):
                    NWBanner(.failed, title: "Can't commit from here", message: message)
                case .form:
                    CommitNotices(store: store)
                    ReviewSectionHead(title: "Message", note: nil)
                    CommitMessageCard(store: store)
                    ReviewSectionHead(title: "Files", note: store.selectionText)
                        .padding(.top, NW.Space.xs)
                    CommitFileList(store: store)
                        .nwCard(radius: MobileLayout.cardRadius)
                    VStack(spacing: 0) { CommitOptions(store: store) }
                        .nwCard(radius: MobileLayout.cardRadius)
                        .padding(.top, NW.Space.xs)
                case .operation:
                    CommitProgress(store: store)
                }
            }
            .disabled(store.info?.blocked != nil && store.stage == .form)
            .padding(MobileLayout.gutter)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.nw.bgBase)
        .safeAreaInset(edge: .bottom, spacing: 0) { actions(store) }
        .navigationTitle(commitTitle(store))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(store.stage == .operation ? "Close" : "Cancel") { close(store) }
            }
        }
        .task { await store.begin() }
        .task(id: store.operationID) {
            guard store.operationID != nil else { return }
            await store.poll()
        }
    }

    @ViewBuilder private func actions(_ store: ReviewCommitStore) -> some View {
        VStack(spacing: NW.Space.s) {
            switch store.stage {
            case .loading, .unavailable:
                EmptyView()
            case .form:
                if let problem = store.problem, store.info?.blocked == nil {
                    Text(problem).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                }
                Button(store.actionTitle) { Task { await store.commit() } }
                    .buttonStyle(.nwReviewBar(.primary))
                    .disabled(!store.canCommit)
                Button("Ask agent to commit") { askAgent() }
                    .buttonStyle(.nwLink(font: .nw(.ui)))
                    .nwTouchTarget(height: NW.Height.controlS)
                    .accessibilityHint("Sends the agent a turn asking it to commit these changes instead")
            case .operation:
                if store.operation?.finished == true {
                    Button("Done") { close(store) }
                        .buttonStyle(.nwReviewBar(.primary))
                } else {
                    Text("The commit continues on the host if you close this.")
                        .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MobileLayout.gutter)
        .padding(.top, NW.Space.l)
        .padding(.bottom, NW.Space.s)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .top) { NWHairline() }
    }

    /// Closing a finished commit (or one whose outcome never came back) reloads the changes, so
    /// what was committed leaves the list.
    private func close(_ store: ReviewCommitStore) {
        navigator.dismissPresented()
        if store.closed() {
            Task { await ReviewStores.shared.store(for: ref).load(hosts: hosts) }
        }
    }

    private func askAgent() {
        let review = ReviewStores.shared.store(for: ref)
        Task {
            if await review.commit(hosts: hosts) {
                navigator.dismissPresented()
            } else {
                CommitStores.shared.store(for: ref, hosts: hosts).error = review.actionError
            }
        }
    }
}
