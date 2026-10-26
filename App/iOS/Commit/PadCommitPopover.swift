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
        if CommitStores.shared.store(for: ref, hosts: hosts).closed() {
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

    var body: some View {
        let store = CommitStores.shared.store(for: ref, hosts: hosts)
        ScrollView {
            VStack(alignment: .leading, spacing: SH.Space.l) {
                PadCommitTitle(store: store)
                switch store.stage {
                case .loading:
                    HStack(spacing: SH.Space.m) {
                        ProgressView().progressViewStyle(SHSpinnerStyle())
                        Text("Reading the changes on the host…").font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary)
                    }
                    .frame(minHeight: SH.Height.touch)
                case .unavailable(let message):
                    SHBanner(.failed, title: "Can't commit from here", message: message)
                case .form:
                    CommitNotices(store: store)
                    CommitMessageCard(store: store, fill: Color.sh.bgWindow)
                    PadCommitChecks(store: store)
                        .disabled(store.info?.blocked != nil)
                case .operation:
                    CommitProgress(store: store)
                }
                footer(store)
            }
            .padding(SH.Space.xl)
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
            HStack(spacing: SH.Space.m) {
                if store.stage == .form {
                    Button("Ask agent", action: askAgent)
                        .buttonStyle(.sh(.ghost, size: .l))
                        .accessibilityLabel("Ask agent to commit")
                        .accessibilityHint("Sends the agent a turn asking it to commit these changes instead")
                }
                Spacer(minLength: 0)
                switch store.stage {
                case .operation:
                    if store.operation?.finished == true {
                        Button("Done", action: close).buttonStyle(.sh(.primary, size: .l))
                    } else {
                        Button("Close", action: close).buttonStyle(.sh(.secondary, size: .l))
                            .accessibilityHint("The commit continues on the host")
                    }
                default:
                    Button("Cancel", action: close).buttonStyle(.sh(.secondary, size: .l))
                    if store.stage == .form {
                        Button(store.actionTitle) { Task { await store.commit() } }
                            .buttonStyle(.sh(.primary, size: .l))
                            .disabled(!store.canCommit)
                    }
                }
            }
        }
    }

    private func askAgent() {
        let review = ReviewStores.shared.store(for: ref)
        Task {
            if await review.commit(hosts: hosts) {
                close()
            } else {
                CommitStores.shared.store(for: ref, hosts: hosts).error = review.actionError
            }
        }
    }
}

/// "Commit 5 files" and, in mono `textTertiary`, "to agent/refund-events".
private struct PadCommitTitle: View {
    let store: ReviewCommitStore

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            Text(commitTitle(store))
                .font(.sh(.headline))
                .foregroundStyle(Color.sh.textPrimary)
            if store.outcome == nil, let branch = store.info?.branch {
                Text("to \(branch)").font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Push to origin and Open a pull request, as the board's checkboxes, each over what it does.
private struct PadCommitChecks: View {
    @Bindable var store: ReviewCommitStore

    var body: some View {
        if let info = store.info {
            VStack(alignment: .leading, spacing: SH.Space.m) {
                check("Push to \(info.pushRemote ?? "origin")", detail: reviewCommitPushDetail(info),
                      isOn: Binding(get: { store.push || store.pullRequest }, set: { store.push = $0 }))
                    .disabled(store.pullRequest || !reviewCommitCanPush(info))
                check("Open a pull request", detail: reviewCommitPullRequestDetail(info, title: store.title), isOn: $store.pullRequest)
                    .disabled(!reviewCommitCanOpenPullRequest(info))
            }
        }
    }

    private func check(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                Text(detail).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.shCheckbox)
        .frame(minHeight: SH.Height.touch, alignment: .leading)
    }
}
