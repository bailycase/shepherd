import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Finalize for a worktree agent, run by its host (the Mac's remote Finalize sheet): the host's
/// prerequisite checks, then the form (base, title, description, commit, cleanup, merge), then
/// the host's pipeline, polled until it finishes. Each step gates the next on the host, nothing
/// is removed before its clean gate, and the remote branch is never deleted. The operation
/// outlives the sheet: reopening it resumes polling the same operation.
@MainActor
@Observable
final class FinalizeStore {
    enum Stage: Equatable {
        /// Asking the host whether git, origin and the GitHub CLI are ready.
        case checking
        /// A check failed: its remedy is on the host.
        case setup
        /// The form, filled with the host's defaults.
        case form
        /// The host is running the pipeline (or finished it).
        case operation
    }

    let ref: AgentRef
    private(set) var stage: Stage = .checking
    private(set) var checks: [FinalizeCheckRow] = []
    private(set) var info: RemoteWorktreeInfo?
    var options = RemoteFinalizeOptions(base: "", title: "", body: "", autoCommit: true, deleteLocalBranch: true,
                                        autoMergePR: false, mergeMethod: "squash")
    private(set) var includedCommits: Int?
    private(set) var generating = false
    private(set) var descriptionPrepared = false
    private(set) var submitting = false
    private(set) var operationID: UUID?
    private(set) var operation: RemoteWorktreeOperation?
    private(set) var steps: [FinalizeStep] = []
    var error: String?
    @ObservationIgnored private var offer: Offer?

    private struct Offer {
        let host: MobileHost
        let session: UUID
        let client: RemoteHostClient
        let address: String
        let port: UInt16
        let agent: Agent
        let spacePath: String

        @MainActor func isCurrent(_ hosts: MobileHosts) -> Bool {
            guard hosts.host(host.id) === host, host.session == session, host.connectedClient === client,
                  host.record.address == address, host.record.port == port,
                  host.supports(RemoteProtocol.worktreeActionsCapability),
                  let current = host.agent(agent.id), current.spaceID == agent.spaceID,
                  current.tabID == agent.tabID, current.paneID == agent.paneID,
                  current.worktreePath == agent.worktreePath, current.worktreeBranch == agent.worktreeBranch,
                  current.worktreeBase == agent.worktreeBase,
                  let space = host.state.spaces.first(where: { $0.id == agent.spaceID }), space.path == spacePath,
                  space.hidden != true else { return false }
            return true
        }
    }

    init(ref: AgentRef) {
        self.ref = ref
    }

    var outcome: FinalizeOutcome? { operation.map(FinalizeOutcome.init) }

    /// Why Finalize can't start: a check, the form, or a request in flight.
    var formProblem: String? {
        if generating { return "Drafting the description…" }
        return finalizeFormProblem(options)
    }

    var canFinalize: Bool { stage == .form && !submitting && formProblem == nil && info != nil }

    // MARK: Checks and the form

    /// Checks the host, then fills the form. A pending operation goes straight to its progress.
    func begin(hosts: MobileHosts) async {
        guard operationID == nil else { stage = .operation; return }
        if offer == nil {
            guard let host = hosts.host(ref.host), let session = host.session, let client = host.connectedClient,
                  let agent = host.agent(ref.agent), let space = host.state.spaces.first(where: { $0.id == agent.spaceID }) else {
                error = "The host is offline."; return
            }
            offer = Offer(host: host, session: session, client: client, address: host.record.address,
                          port: host.record.port, agent: agent, spacePath: space.path)
        }
        stage = .checking
        error = nil
        await runChecks(hosts: hosts)
    }

    func runChecks(hosts: MobileHosts) async {
        do {
            guard case .worktreeSetup(let setup) = try await query(.worktreeSetup(action: .check), hosts: hosts) else { throw FinalizeError.reply }
            // An operation that started meanwhile owns the sheet.
            guard operationID == nil else { return }
            checks = finalizeCheckRows(setup)
            guard finalizeChecksPass(setup) else {
                stage = .setup
                return
            }
            try await prepareForm(hosts: hosts)
        } catch {
            guard operationID == nil else { return }
            self.error = reviewErrorText(error)
            if stage == .checking { stage = .setup }
        }
    }

    private func prepareForm(hosts: MobileHosts) async throws {
        if info == nil {
            guard case .worktreeInfo(let value) = try await query(.worktreeInfo, hosts: hosts) else { throw FinalizeError.reply }
            guard operationID == nil else { return }
            info = value
            options = value.defaults
        }
        stage = .form
        await countCommits(hosts: hosts)
        await generateDescription(hosts: hosts)
    }

    /// Commits on the branch that are not on the base: an inflated count means a wrong base.
    func countCommits(hosts: MobileHosts) async {
        let base = options.base
        guard !base.trimmingCharacters(in: .whitespaces).isEmpty else { includedCommits = nil; return }
        if case .worktreeCommitCount(let count)? = try? await query(.worktreeCommitCount(base: base), hosts: hosts), options.base == base {
            includedCommits = count
        }
    }

    /// Asks the host to draft the PR description when it drafts them, keeping anything typed.
    func generateDescription(hosts: MobileHosts, force: Bool = false) async {
        guard info?.generateDescription == true, force || !descriptionPrepared, !generating else { return }
        let original = options.body
        generating = true
        defer { generating = false }
        do {
            if case .worktreeDescription(let body) = try await query(.worktreeDescription(base: options.base, title: options.title), hosts: hosts) {
                // A description typed while the host drafted wins over the draft.
                if options.body == original, !body.isEmpty { options.body = body }
                descriptionPrepared = true
            }
        } catch { self.error = reviewErrorText(error) }
    }

    // MARK: The operation

    func start(hosts: MobileHosts) async {
        guard canFinalize else { return }
        guard offer?.isCurrent(hosts) == true else {
            error = "This form belongs to an earlier worktree or connection. Close it and open it again."; return
        }
        let id = UUID()
        submitting = true
        operationID = id
        stage = .operation
        error = nil
        defer { submitting = false }
        do {
            if case .worktreeOperation(let status) = try await query(.finalizeWorktree(operationID: id, options: options), hosts: hosts) {
                guard status.id == id else { throw FinalizeError.reply }
                adopt(status)
            }
        } catch RemoteHostClientError.rejected(_, let message) {
            // Refused before it started: nothing ran, so the form comes back.
            operationID = nil
            stage = .form
            error = message
        } catch {
            self.error = "Outcome not yet known: \(reviewErrorText(error)). Don't start another operation; its status is checked again."
        }
    }

    /// Polls the host every two seconds until the operation finishes.
    func poll(hosts: MobileHosts) async {
        guard let id = operationID else { return }
        while !Task.isCancelled, operation?.finished != true {
            do {
                if case .worktreeOperation(let status) = try await query(.worktreeStatus(operationID: id), hosts: hosts) {
                    guard status.id == id else { throw FinalizeError.reply }
                    adopt(status)
                    error = nil
                    if status.finished { return }
                }
            } catch { self.error = "Outcome not yet known: \(reviewErrorText(error)). Don't retry the operation." }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Shows an operation the host reported (and the fixtures' staged ones).
    func adopt(_ status: RemoteWorktreeOperation) {
        guard operationID == nil || operationID == status.id else { return }
        guard operation?.finished != true || status.finished else { return }
        operationID = status.id
        operation = status
        steps = finalizeSteps(status.progress)
        stage = .operation
    }

    /// Stages the form with the host's answers (the fixtures, which change nothing).
    func prepare(info: RemoteWorktreeInfo, checks: RemoteWorktreeSetup, includedCommits: Int?) {
        self.info = info
        options = info.defaults
        self.checks = finalizeCheckRows(checks)
        self.includedCommits = includedCommits
        descriptionPrepared = true
        stage = finalizeChecksPass(checks) ? .form : .setup
    }

    /// Done with a finished operation: the next Finalize starts over.
    func reset() {
        guard operationID == nil || operation?.finished == true else { return }
        offer = nil
        stage = .checking
        info = nil
        operationID = nil
        operation = nil
        steps = []
        includedCommits = nil
        descriptionPrepared = false
        error = nil
    }

    private func query(_ query: RemoteAgentQuery, hosts: MobileHosts) async throws -> RemoteAgentResult {
        guard let offer, offer.isCurrent(hosts) else { throw FinalizeError.stale }
        let result: Result<RemoteAgentResult, Error>
        do { result = .success(try await offer.client.agentQuery(agentID: ref.agent, query: query)) }
        catch { result = .failure(error) }
        // A late refusal on a lost route is not proof that nothing ran on the captured host.
        guard offer.isCurrent(hosts) else { throw FinalizeError.stale }
        return try result.get()
    }

    private enum FinalizeError: Error, CustomStringConvertible {
        case offline, reply, stale
        var description: String {
            switch self {
            case .offline: "The host is offline."
            case .reply: "The host answered something unexpected."
            case .stale: "This worktree's connection or binding changed. Reopen the form; do not retry an unknown operation."
            }
        }
    }
}
