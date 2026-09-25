import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

extension View {
    /// Commit on iPad (iPadCommit board): a popover from the Commit… it is attached to, open
    /// while `CommitStores.popover` is this thread. `arrowEdge` is the side of the anchor the
    /// arrow points from: `.top` under a toolbar button, `.bottom` over the docked composer.
    func commitPopover(ref: AgentRef, arrowEdge: Edge = .top) -> some View {
        modifier(PadCommitPopoverPresenter(ref: ref, arrowEdge: arrowEdge))
    }
}

private struct PadCommitPopoverPresenter: ViewModifier {
    let ref: AgentRef
    let arrowEdge: Edge
    @Environment(MobileHosts.self) private var hosts

    func body(content: Content) -> some View {
        let stores = CommitStores.shared
        content.popover(isPresented: Binding(get: { stores.popover == ref }, set: { if !$0 { close() } }),
                        arrowEdge: arrowEdge) {
            PadCommitPopover(ref: ref, close: close)
                .presentationCompactAdaptation(.popover)
        }
    }

    /// Closing a finished commit reloads the review, so what was committed leaves it.
    private func close() {
        guard CommitStores.shared.popover == ref else { return }
        CommitStores.shared.popover = nil
        let store = CommitStores.shared.store(for: ref, hosts: hosts)
        if store.operation?.finished == true {
            store.reset()
            Task { await ReviewStores.shared.store(for: ref).load(hosts: hosts) }
        }
    }
}

/// The popover: "Commit 3 files", the message drafted from the diff, the files, the options,
/// then Cancel and Commit & push; once it runs, the host's steps.
struct PadCommitPopover: View {
    let ref: AgentRef
    let close: () -> Void
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let store = CommitStores.shared.store(for: ref, hosts: hosts)
        ScrollView {
            VStack(alignment: .leading, spacing: NW.Space.l) {
                Text(commitTitle(store))
                    .font(.nw(.headline))
                    .foregroundStyle(Color.nw.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                switch store.stage {
                case .loading:
                    HStack(spacing: NW.Space.m) {
                        ProgressView().progressViewStyle(NWSpinnerStyle())
                        Text("Reading the changes on the host…").font(.nw(.ui)).foregroundStyle(Color.nw.textSecondary)
                    }
                    .frame(minHeight: NW.Height.touch)
                case .unavailable(let message):
                    NWBanner(.failed, title: "Can't commit from here", message: message)
                case .form:
                    CommitNotices(store: store)
                    CommitMessageCard(store: store, fill: Color.nw.bgWindow)
                    ScrollView {
                        CommitFileList(store: store)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: MobileLayout.commitPopoverFilesHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        NWHairline()
                        CommitOptions(store: store)
                    }
                    .disabled(store.info?.blocked != nil)
                case .operation:
                    CommitProgress(store: store)
                }
                footer(store)
            }
            .padding(NW.Space.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: MobileLayout.commitPopoverWidth)
        .background(Color.nw.bgRaised)
        .task { await store.begin() }
        .task(id: store.operationID) {
            guard store.operationID != nil else { return }
            await store.poll()
        }
    }

    @ViewBuilder private func footer(_ store: ReviewCommitStore) -> some View {
        VStack(alignment: .trailing, spacing: NW.Space.s) {
            if store.stage == .form, let problem = store.problem, store.info?.blocked == nil {
                Text(problem).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(spacing: NW.Space.m) {
                if store.stage == .form {
                    Button("Ask agent", action: askAgent)
                        .buttonStyle(.nw(.ghost, size: .l))
                        .accessibilityLabel("Ask agent to commit")
                        .accessibilityHint("Sends the agent a turn asking it to commit these changes instead")
                }
                Spacer(minLength: 0)
                switch store.stage {
                case .operation:
                    if store.operation?.finished == true {
                        Button("Done", action: close).buttonStyle(.nw(.primary, size: .l))
                    } else {
                        Button("Close", action: close).buttonStyle(.nw(.secondary, size: .l))
                            .accessibilityHint("The commit continues on the host")
                    }
                default:
                    Button("Cancel", action: close).buttonStyle(.nw(.secondary, size: .l))
                    if store.stage == .form {
                        Button(store.actionTitle) { Task { await store.commit() } }
                            .buttonStyle(.nw(.primary, size: .l))
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
