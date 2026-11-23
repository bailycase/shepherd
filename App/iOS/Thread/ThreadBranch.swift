import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Where a thread's branch stands, behind the thread's ••• (GitPhoneD board): the Branch item opens
// a sheet with the Mac's branch card rows (GitPhoneA, presented as `ReviewRoute.branch`), and Changes' summary card shows the same
// behind and pull request rows (GitPhoneD-changes). The host reads git and runs Update
// (`RemoteAgentQuery.branchStatus`, `.branchUpdate`, `.branchAbort`).

/// One thread's branch status as its host last read it, shared by the menu, the sheet and Changes.
@MainActor
@Observable
final class BranchStatusStore {
    private static var stores: [AgentRef: BranchStatusStore] = [:]

    static func of(_ ref: AgentRef) -> BranchStatusStore {
        if let store = stores[ref] { return store }
        let store = BranchStatusStore(ref: ref)
        stores[ref] = store
        return store
    }

    let ref: AgentRef
    private(set) var status: RemoteBranchStatus?
    private(set) var error: String?
    /// Update or Abort is running on the host.
    private(set) var busy = false

    private init(ref: AgentRef) { self.ref = ref }

    func load(_ host: MobileHost?) async {
        guard let client = host?.connectedClient, host?.supports(RemoteProtocol.branchStatusCapability) == true else { return }
        do {
            guard case .branchStatus(let read) = try await client.agentQuery(agentID: ref.agent, query: .branchStatus) else { return }
            if status != read { status = read }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Update from the base, on the person's tap; a conflict stops it, and Abort puts the branch back.
    func update(_ host: MobileHost?, rebase: Bool) async {
        guard let client = host?.connectedClient, let base = status?.base, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.agentQuery(agentID: ref.agent, query: .branchUpdate(base: base, rebase: rebase))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await load(host)
    }

    func abort(_ host: MobileHost?) async {
        guard let client = host?.connectedClient, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.agentQuery(agentID: ref.agent, query: .branchAbort)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await load(host)
    }

    /// The menu's line under Branch: "refund-events · 3 behind".
    func menuDetail(branch: String) -> String {
        guard let status, status.behind > 0 else { return branch }
        return "\(branch) · \(status.behind) behind"
    }
}

/// The branch sheet (GitPhoneA): the space, the branch, Changes, how far behind the base with
/// Update, the pull request, then the space's other branches.
struct ThreadBranchSheet: View {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let host = hosts.host(ref.host)
        let agent = host?.agent(ref.agent)
        let store = BranchStatusStore.of(ref)
        let label = agent.flatMap { AgentBranchLabel(agent: $0) }
        let space = agent.flatMap { agent in host?.state.spaces.first { $0.id == agent.spaceID }?.name }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let space {
                    BranchSheetHead(text: space)
                }
                if let label {
                    BranchSheetRow(symbol: SHGlyph.gitBranch.symbolName) {
                        Text(label.kind == .checkout ? "\(label.branch) (your checkout)" : label.branch)
                            .font(.sh(.mono)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: SH.Space.m)
                    }
                    .contextMenu { Button("Copy Branch Name", systemImage: "doc.on.doc") { UIPasteboard.general.string = label.branch } }
                    SHHairline()
                }
                Button {
                    navigator.dismissPresented()
                    navigator.open(.paneScreen(.changes, thread: ref))
                } label: {
                    BranchSheetRow(symbol: "plus.forwardslash.minus") {
                        Text("Changes")
                        Spacer(minLength: SH.Space.m)
                        if let status = store.status { SHDiffStat(added: status.additions, removed: status.deletions, font: .sh(.caption)) }
                        Image(systemName: "chevron.right").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                BranchStatusRows(ref: ref, store: store, host: host) { navigator.dismissPresented() }
                if let agent, let host {
                    let peers = AgentBranchPeer.peers(of: agent, in: host.state.agents)
                    if !peers.isEmpty {
                        BranchSheetHead(text: "Other branches in \(space ?? "this space")").padding(.top, SH.Space.l)
                        ForEach(peers) { peer in
                            Button {
                                navigator.dismissPresented()
                                navigator.open(.thread(AgentRef(host: ref.host, agent: peer.id)))
                            } label: {
                                BranchSheetRow(symbol: nil) {
                                    SHStatusDot(AgentState(peer.status)).frame(width: MobileLayout.statusDot * 2)
                                    Text(peer.branch).font(.sh(.mono)).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: SH.Space.m)
                                    Text(peer.detail).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(peer.branch), \(peer.detail)")
                            if peer.id != peers.last?.id { SHHairline() }
                        }
                    }
                }
            }
            .padding(.vertical, SH.Space.m)
        }
        .background(Color.sh.bgRaised)
        .toolbar(.hidden, for: .navigationBar)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await store.load(host) }
    }
}

/// "3 behind main · Update" and "Pull request #31 · Checks passed": the sheet's rows and Changes' summary card's.
struct BranchStatusRows: View {
    let ref: AgentRef
    let store: BranchStatusStore
    let host: MobileHost?
    /// Before the pull request opens (the sheet closes).
    var leaving: () -> Void = {}
    @Environment(MobileNavigator.self) private var navigator
    @State private var choosing = false

    var body: some View {
        if let conflict = store.status?.conflict {
            BranchSheetRow(symbol: "exclamationmark.triangle") {
                Text(conflict.files.count == 1 ? "Stopped on a conflict" : "Stopped on \(conflict.files.count) conflicts")
                    .foregroundStyle(Color.sh.failed)
                Spacer(minLength: SH.Space.m)
                Button("Abort") { Task { await store.abort(host) } }
                    .foregroundStyle(Color.sh.running)
                    .disabled(store.busy)
                    .accessibilityHint("Puts the branch back as it was before Update")
            }
            SHHairline()
        } else if let status = store.status, let base = status.base, status.behind > 0 {
            BranchSheetRow(symbol: "arrow.down") {
                Text("\(status.behind) behind \(base)")
                Spacer(minLength: SH.Space.m)
                if store.busy {
                    ProgressView()
                } else {
                    Button("Update") { choosing = true }
                        .foregroundStyle(Color.sh.running)
                        .confirmationDialog("Update from \(base)", isPresented: $choosing, titleVisibility: .visible) {
                            Button("Rebase") { Task { await store.update(host, rebase: true) } }
                            Button("Merge") { Task { await store.update(host, rebase: false) } }
                        } message: {
                            Text("Fetches \(base), then puts this branch on top of it. Uncommitted changes stop it.")
                        }
                }
            }
            SHHairline()
        }
        if let pull = store.status?.pull {
            Button {
                leaving()
                navigator.open(.forge(.pullRequest(host: ref.host, ref: pull.ref)))
            } label: {
                BranchSheetRow(symbol: ForgeGlyph.pullRequest) {
                    Text("Pull request #\(pull.ref.number)")
                    Spacer(minLength: SH.Space.m)
                    let word = Self.pullWord(pull)
                    Text(word.text).font(.sh(.caption)).foregroundStyle(word.color)
                    Image(systemName: "chevron.right").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
            }
            .buttonStyle(.plain)
        }
        if let error = store.error {
            Text(error).font(.sh(.caption)).foregroundStyle(Color.sh.failed)
                .padding(.horizontal, MobileLayout.gutter).padding(.vertical, SH.Space.s)
        }
    }

    /// A finished pull request says how it ended; an open one, its checks (as the Mac's card).
    static func pullWord(_ pull: PullRequestSummary) -> (text: String, color: Color) {
        let (text, state): (String, AgentState) = switch (pull.state, pull.checks) {
        case (.merged, _): ("Merged", .done)
        case (.closed, _): ("Closed", .idle)
        case (_, .passed): ("Checks passed", .done)
        case (_, .failing): ("Checks failed", .failed)
        case (_, .running): ("Checks running", .running)
        case (.draft, .none): ("Draft", .idle)
        case (.open, .none): ("Open", .idle)
        }
        return (text, state.textColor)
    }
}

/// A 48pt row: a glyph in its column (none for a dot row, which draws its own), then content.
private struct BranchSheetRow<Content: View>: View {
    let symbol: String?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: SH.Space.l) {
            if let symbol {
                Image(systemName: symbol).font(.sh(.body)).foregroundStyle(Color.sh.textSecondary)
                    .frame(width: MobileLayout.statusDot * 2)
            }
            content
        }
        .font(.sh(.body))
        .foregroundStyle(Color.sh.textPrimary)
        .padding(.horizontal, MobileLayout.gutter)
        .frame(maxWidth: .infinity, minHeight: MobileLayout.rowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct BranchSheetHead: View {
    let text: String

    var body: some View {
        Text(text).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            .padding(.horizontal, MobileLayout.gutter).padding(.top, SH.Space.s).padding(.bottom, SH.Space.xs)
            .accessibilityAddTraits(.isHeader)
    }
}
