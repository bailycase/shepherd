import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

extension View {
    /// Commit on iPad (iPadCommit board): a popover from the Commit… it is attached to, open
    /// while this window's `MobileNavigator.commitPopover` is this thread. `arrowEdge` is the side of the anchor the
    /// arrow points from: `.top` under a toolbar button, `.bottom` over the docked composer.
    func commitPopover(ref: AgentRef, arrowEdge: Edge = .top) -> some View {
        modifier(PadCommitPopoverPresenter(ref: ref, arrowEdge: arrowEdge))
    }
}

private struct PadCommitPopoverPresenter: ViewModifier {
    let ref: AgentRef
    let arrowEdge: Edge
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    func body(content: Content) -> some View {
        content.popover(isPresented: Binding(get: { navigator.commitPopover == ref }, set: { if !$0 { close() } }),
                        arrowEdge: arrowEdge) {
            PadCommitPopover(ref: ref, close: close)
                .presentationCompactAdaptation(.popover)
        }
    }

    /// Closing a finished commit (or one whose outcome never came back) reloads the review, so
    /// what was committed leaves it.
    private func close() {
        guard navigator.commitPopover == ref else { return }
        navigator.commitPopover = nil
        let store = CommitStores.shared.store(for: ref, hosts: hosts)
        let succeeded = if case .succeeded = store.outcome { true } else { false }
        if store.closed(), !succeeded || !navigator.finishQueuedReview(ref, hosts: hosts) {
            Task { await ReviewStores.shared.store(for: ref).load(hosts: hosts) }
        }
    }
}

/// The popover (iPadCommit): "Commit 5 files to agent/refund-events", the message drafted from
/// the diff, Push to origin and Open a pull request as checkboxes, then Cancel and Commit & push;
/// once it runs, the host's steps. Every changed file goes in: the phone's sheet is where files
/// are ticked off.
struct PadCommitPopover: View {
    let ref: AgentRef
    let close: () -> Void
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let store = CommitStores.shared.store(for: ref, hosts: hosts)
        ScrollView {
            VStack(alignment: .leading, spacing: SH.Space.l) {
                PadCommitTitle(store: store)
                switch store.stage {
                case .loading:
                    HStack(spacing: SH.Space.m) {
                        Text("Reading the changes on the host…").font(.sh(.ui)).shShimmer(active: true)
                    }
                    .frame(minHeight: SH.Height.touch)
                case .unavailable(let message):
                    SHBanner(.failed, title: "Can't commit from here", message: message)
                case .form:
                    CommitNotices(store: store)
                    CommitMessageCard(store: store, fill: Color.sh.bgSunken)
                    PadCommitChecks(store: store)
                        .disabled(store.info?.blocked != nil)
                case .operation:
                    CommitProgress(store: store)
                }
                footer(store)
            }
            .padding(SH.Space.xl)
            .padding(.bottom, SH.Space.xs)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: MobileLayout.commitPopoverWidth)
        .background(Color.sh.bgRaised)
        .task { await store.begin() }
        .task(id: store.operationID) {
            guard store.operationID != nil else { return }
            await store.poll()
        }
    }

    @ViewBuilder private func footer(_ store: ReviewCommitStore) -> some View {
        VStack(alignment: .trailing, spacing: SH.Space.s) {
            if store.stage == .form, let problem = store.problem, store.info?.blocked == nil {
                Text(problem).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(spacing: SH.Space.xl) {
                if store.stage == .form {
                    Button("Ask agent", action: askAgent)
                        .buttonStyle(.shLink(color: Color.sh.textSecondary, font: .shSans(MobileLayout.touchBodyFont)))
                        .accessibilityLabel("Ask agent to commit")
                        .accessibilityHint("Sends the agent a turn asking it to commit these changes instead")
                }
                Spacer(minLength: 0)
                switch store.stage {
                case .operation:
                    if store.operation?.finished == true {
                        Button("Done", action: close).buttonStyle(.reviewCompactPill)
                    } else {
                        Button("Close", action: close)
                            .buttonStyle(.shLink(color: Color.sh.textSecondary, font: .shSans(MobileLayout.touchBodyFont)))
                            .accessibilityHint("The commit continues on the host")
                    }
                default:
                    Button("Cancel", action: close)
                        .buttonStyle(.shLink(color: Color.sh.textSecondary, font: .shSans(MobileLayout.touchBodyFont)))
                    if store.stage == .form {
                        Button(store.actionTitle) { Task { await store.commit() } }
                            .buttonStyle(.reviewCompactPill)
                            .disabled(!store.canCommit)
                    }
                }
            }
            .frame(minHeight: MobileLayout.touchCompactHeight)
        }
    }

    private func askAgent() {
        let review = ReviewStores.shared.store(for: ref)
        Task {
            if await review.commit(hosts: hosts) {
                close()
                navigator.finishQueuedReview(ref, hosts: hosts)
            } else {
                CommitStores.shared.store(for: ref, hosts: hosts).error = review.actionError
            }
        }
    }
}

/// "Commit 5 files" over, in mono, "to agent/refund-events".
private struct PadCommitTitle: View {
    let store: ReviewCommitStore

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            Text(commitTitle(store))
                .font(.sh(.headline))
                .foregroundStyle(Color.sh.textPrimary)
            if store.outcome == nil, let branch = store.info?.branch {
                Text("to \(branch)").font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Push to origin and Open a pull request, as the board's switches, each over what it does.
private struct PadCommitChecks: View {
    @Bindable var store: ReviewCommitStore

    var body: some View {
        if let info = store.info {
            VStack(spacing: 0) {
                CommitOptionRow(title: "Push to \(info.pushRemote ?? "origin")", detail: reviewCommitPushDetail(info), monoDetail: true,
                                isOn: Binding(get: { store.push || store.pullRequest }, set: { store.push = $0 }))
                    .disabled(store.pullRequest || !reviewCommitCanPush(info))
                SHHairline()
                CommitOptionRow(title: "Open a pull request", detail: reviewCommitPullRequestDetail(info, title: store.title),
                                isOn: $store.pullRequest)
                    .disabled(!reviewCommitCanOpenPullRequest(info))
            }
            .padding(.horizontal, -MobileLayout.gutter)
        }
    }
}
