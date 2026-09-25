import Foundation
import Observation
import ShepherdProtocol

/// One commit from review, as the sheet runs it on every client (the Mac's review pane, the
/// iPhone's and the iPad's review): the host's info and plain message, then its drafted message,
/// the files (all selected), where the commit goes, and the host's operation until it finishes.
/// `query` reaches the host: a remote host over the protocol, or the Mac's own host code for a
/// local review. The host checks everything again before it commits, so the sheet's gates are a
/// courtesy, never the safety.
@MainActor
@Observable
public final class ReviewCommitStore {
    public enum Stage: Equatable, Sendable {
        /// Asking the host what would be committed.
        case loading
        /// The host couldn't say (offline, not a repository).
        case unavailable(String)
        /// The message, the files and the options.
        case form
        /// The host is committing (or finished).
        case operation
    }

    public private(set) var stage: Stage = .loading
    public private(set) var info: RemoteCommitInfo?
    public var title = ""
    public var body = ""
    public private(set) var selected: Set<String> = [] { didSet { derive() } }
    /// Push after commit (to the upstream, setting one when there is none).
    public var push = true
    /// Open a pull request instead: push the branch and open the PR.
    public var pullRequest = false
    public var confirmedWhileWorking = false
    public private(set) var drafting = false
    /// The message on screen came from the host's draft of the diff.
    public private(set) var drafted = false
    public private(set) var submitting = false
    public private(set) var operationID: UUID?
    public private(set) var operation: RemoteWorktreeOperation?
    public private(set) var steps: [FinalizeStep] = []
    public var error: String?
    /// The file rows, derived once per change of the files or the selection.
    public private(set) var rows: [ReviewCommitFileRow] = []

    @ObservationIgnored public var query: ((RemoteAgentQuery) async throws -> RemoteAgentResult)?
    @ObservationIgnored private var loadID = UUID()
    /// The message as the host wrote it, so a draft replaces it only while nobody has typed.
    @ObservationIgnored private var written: (title: String, body: String) = ("", "")

    public init(query: ((RemoteAgentQuery) async throws -> RemoteAgentResult)? = nil) {
        self.query = query
    }

    // MARK: Derived

    public var destination: RemoteCommitPush { reviewCommitPush(push: push, pullRequest: pullRequest) }
    public var actionTitle: String { reviewCommitActionTitle(destination) }
    public var selectionText: String { reviewCommitSelectionText(selected: selectedFiles.count, of: info?.files.count ?? 0) }
    public var selectedFiles: [RemoteCommitFile] { info?.files.filter { selected.contains($0.id) } ?? [] }
    public var outcome: ReviewCommitOutcome? { operation.map(ReviewCommitOutcome.init) }

    /// Why Commit can't run: the host's refusal, the form, or a request in flight.
    public var problem: String? {
        guard let info else { return nil }
        return reviewCommitProblem(info, selected: selectedFiles.count, title: title, push: destination,
                                   confirmedWhileWorking: confirmedWhileWorking)
    }

    public var canCommit: Bool { stage == .form && !submitting && info != nil && problem == nil }

    /// The branch a pull request from the default branch creates.
    public var newBranch: String? {
        guard pullRequest, info?.onDefaultBranch == true else { return nil }
        return reviewCommitBranchName(title: title)
    }

    // MARK: Loading

    /// Asks the host what would be committed, then for a drafted message. A finished commit
    /// starts over; one still running keeps the sheet on its progress.
    public func begin() async {
        if operation?.finished == true { reset() }
        guard operationID == nil else { stage = .operation; return }
        await load()
    }

    public func load() async {
        guard let query else { stage = .unavailable("The host is offline."); return }
        let id = UUID()
        loadID = id
        stage = .loading
        error = nil
        do {
            guard case .commitInfo(let info) = try await query(.commitInfo) else { throw ReviewCommitStoreError.reply }
            guard loadID == id, operationID == nil else { return }
            adopt(info)
        } catch {
            guard loadID == id, operationID == nil else { return }
            stage = .unavailable(Self.text(error))
            return
        }
        await draft()
    }

    /// Shows what the host would commit, every file selected, with the host's plain message.
    public func adopt(_ info: RemoteCommitInfo) {
        self.info = info
        written = (info.title, info.body)
        title = info.title
        body = info.body
        drafted = false
        selected = Set(info.files.map(\.id))
        push = reviewCommitCanPush(info)
        pullRequest = false
        confirmedWhileWorking = false
        stage = .form
    }

    /// Stages the sheet as a host would fill it, for previews and fixtures: the host is asked
    /// nothing.
    public func stage(_ info: RemoteCommitInfo, title: String? = nil, body: String? = nil, drafted: Bool = false, drafting: Bool = false) {
        adopt(info)
        if let title { self.title = title }
        if let body { self.body = body }
        written = (self.title, self.body)
        self.drafted = drafted
        self.drafting = drafting
    }

    /// Asks the host to draft the message from the diff, keeping anything typed meanwhile.
    public func draft() async {
        guard let info, info.draftsMessage, !info.files.isEmpty, !drafting, let query else { return }
        drafting = true
        defer { drafting = false }
        let before = (title, body)
        do {
            guard case .commitMessage(let title, let body, let drafted) = try await query(.commitMessage(paths: info.files.flatMap(\.paths))) else { return }
            guard self.info == info, operationID == nil, !title.isEmpty else { return }
            // Anything typed while the host drafted wins over the draft.
            guard self.title == before.0, self.body == before.1, before.0 == written.title, before.1 == written.body else { return }
            self.title = title
            self.body = body
            written = (title, body)
            self.drafted = drafted
        } catch {
            // The plain message stays; a failed draft is not worth a banner.
        }
    }

    // MARK: Selection

    public func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    public func selectAll(_ on: Bool) {
        selected = on ? Set(info?.files.map(\.id) ?? []) : []
    }

    // MARK: The operation

    /// Starts the commit on the host. A refusal brings the form back with why; an unknown
    /// outcome keeps polling rather than inviting a second commit.
    public func commit() async {
        guard canCommit, let info, let query else { return }
        let id = UUID()
        let options = RemoteCommitOptions(head: info.head, files: selectedFiles, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                          body: body.trimmingCharacters(in: .whitespacesAndNewlines), push: destination,
                                          newBranch: newBranch, confirmedWhileWorking: confirmedWhileWorking)
        submitting = true
        operationID = id
        stage = .operation
        error = nil
        defer { submitting = false }
        do {
            guard case .worktreeOperation(let status) = try await query(.commit(operationID: id, options: options)) else { throw ReviewCommitStoreError.reply }
            adopt(status)
        } catch RemoteHostClientError.rejected(_, let message) {
            refused(message)
            await refreshChecks()
        } catch let error as ReviewCommitRefusal {
            refused(error.message)
            await refreshChecks()
        } catch {
            self.error = "Outcome not yet known: \(Self.text(error)). Don't commit again; its status is checked again."
        }
    }

    /// Refused before it started: nothing ran, so the form comes back with why.
    private func refused(_ message: String) {
        operationID = nil
        stage = .form
        error = message
    }

    /// After a refusal, reads again whether the agent is working and whether the checkout is
    /// blocked, so the form offers what the refusal asks for (an agent that started working after
    /// the sheet opened needs the confirmation). The files, HEAD and fingerprints stay as the
    /// sheet showed them: a changed file or a moved HEAD still needs Commit… again.
    private func refreshChecks() async {
        guard let query, let shown = info else { return }
        guard case .commitInfo(let fresh)? = try? await query(.commitInfo), info == shown, stage == .form, operationID == nil else { return }
        var next = shown
        next.agentWorking = fresh.agentWorking
        next.blocked = fresh.blocked
        if next != shown { info = next }
    }

    /// The sheet closed. A finished commit, or one whose outcome never came back, is done with:
    /// the next Commit… reads the checkout again, where the host's HEAD check keeps a commit that
    /// landed from landing twice. One still running keeps its progress. True when the review
    /// should reload.
    @discardableResult
    public func closed() -> Bool {
        guard operationID != nil, operation?.finished != false else { return false }
        reset()
        return true
    }

    /// Asks the host once how the commit stands; true once it finished.
    @discardableResult
    public func pollOnce() async -> Bool {
        guard let id = operationID, let query else { return true }
        do {
            if case .worktreeOperation(let status) = try await query(.worktreeStatus(operationID: id)), status.id == id {
                adopt(status)
                error = nil
            }
        } catch {
            self.error = "Outcome not yet known: \(Self.text(error)). Don't commit again."
        }
        return operation?.finished == true
    }

    /// Polls until the operation finishes.
    public func poll(every interval: Duration = .seconds(1)) async {
        while !Task.isCancelled, operationID != nil, operation?.finished != true {
            if await pollOnce() { return }
            try? await Task.sleep(for: interval)
        }
    }

    /// Shows an operation the host reported (and the previews' and fixtures' staged ones).
    public func adopt(_ status: RemoteWorktreeOperation) {
        operationID = status.id
        operation = status
        steps = finalizeSteps(status.progress)
        stage = .operation
    }

    /// Done with a finished commit (or never started): the next one starts over.
    public func reset() {
        guard operation?.finished != false else { return }
        stage = .loading
        info = nil
        title = ""
        body = ""
        selected = []
        drafted = false
        operationID = nil
        operation = nil
        steps = []
        error = nil
        confirmedWhileWorking = false
    }

    private func derive() {
        let next = reviewCommitRows(info?.files ?? [], selected: selected)
        if next != rows { rows = next }
    }

    /// A host's refusal says what went wrong in its message; anything else describes itself.
    static func text(_ error: Error) -> String {
        switch error {
        case RemoteHostClientError.rejected(_, let message): message
        case let refusal as ReviewCommitRefusal: refusal.message
        default: String(describing: error)
        }
    }
}

/// A refusal from the host's own code (the Mac's local review), read as a rejected request.
public struct ReviewCommitRefusal: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

enum ReviewCommitStoreError: Error, CustomStringConvertible {
    case reply
    var description: String { "The host answered something unexpected." }
}
