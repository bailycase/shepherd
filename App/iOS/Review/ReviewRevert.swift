import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Revert File from a diff (the Mac review pane's confirmed Revert, `changes.revert.v1`): the host
/// puts one file back as HEAD has it, in the working tree only, fenced to the version this review
/// read, and refuses when the file changed since. Offered only for a working-tree review against
/// HEAD (the Uncommitted scope), as on the Mac.
@MainActor
@Observable
final class ReviewRevertStore {
    static let shared = ReviewRevertStore()

    /// Files whose revert is on its way, by path.
    private(set) var busy: Set<String> = []
    /// Why the host refused, for the alert.
    var failure: TurnUndoStore.Failure?
    @ObservationIgnored private var failureHost: UUID?
    @ObservationIgnored private var forgottenHosts: Set<UUID> = []

    func forget(host: UUID) {
        forgottenHosts.insert(host)
        if failureHost == host { failure = nil; failureHost = nil }
    }

    /// Whether `store`'s review can revert a file: a changes review of the working tree against
    /// HEAD, on a host that serves the revert.
    static func available(_ store: ReviewStore, host: MobileHost?) -> Bool {
        guard let host, host.supports(RemoteProtocol.changesRevertCapability), store.usesChanges else { return false }
        return store.list?.scope == .uncommitted
    }

    func revert(_ file: ChangesFile, in store: ReviewStore, hosts: MobileHosts) {
        let ref = store.ref
        guard !forgottenHosts.contains(ref.host), !busy.contains(file.id), let list = store.list, list.scope == .uncommitted else { return }
        guard let client = hosts.host(ref.host)?.connectedClient else {
            failureHost = ref.host
            failure = .init(title: "Couldn't revert \(reviewPathParts(file.path).name)", message: "The host is offline.")
            return
        }
        busy.insert(file.id)
        Task {
            defer { busy.remove(file.id) }
            do {
                guard case .ok = try await client.agentQuery(
                    agentID: ref.agent, query: .changesRevertFile(revision: list.revision, path: file.path, oldPath: file.oldPath)) else {
                    throw RemoteReviewError.unexpectedReply
                }
                guard !forgottenHosts.contains(ref.host) else { return }
                store.refresh()
            } catch {
                guard !forgottenHosts.contains(ref.host) else { return }
                failureHost = ref.host
                failure = .init(title: "Couldn't revert \(reviewPathParts(file.path).name)", message: reviewErrorText(error))
            }
        }
    }
}

/// The diff's Revert File… toolbar item: confirms, then asks the host.
struct ReviewRevertButton: View {
    let store: ReviewStore
    let file: ChangesFile
    @Environment(MobileHosts.self) private var hosts
    @State private var confirming = false

    var body: some View {
        let revert = ReviewRevertStore.shared
        Button("Revert file\u{2026}", systemImage: "arrow.uturn.backward", role: .destructive) { confirming = true }
            .disabled(revert.busy.contains(file.id))
            .confirmationDialog("Revert \(reviewPathParts(file.path).name)?", isPresented: $confirming, titleVisibility: .visible) {
                Button(file.status == .added ? "Move to Trash" : "Revert", role: .destructive) {
                    revert.revert(file, in: store, hosts: hosts)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(message)
            }
            .alert(revert.failure?.title ?? "", isPresented: Binding(get: { revert.failure != nil }, set: { if !$0 { revert.failure = nil } }),
                   presenting: revert.failure) { _ in
                Button("OK", role: .cancel) { revert.failure = nil }
            } message: { failure in
                Text(failure.message)
            }
    }

    private var message: String {
        switch file.status {
        case .added: "The file is new: it moves to the Trash on the host."
        case .renamed: "\(file.oldPath ?? "The old path") comes back as HEAD has it and \(file.path) moves to the Trash on the host."
        case .deleted: "The file comes back as HEAD has it."
        case .modified: "Its changes in the working tree are discarded on the host. Staged changes stay in the index."
        }
    }
}
