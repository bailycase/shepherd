import Foundation
import Observation
import ShepherdProtocol

/// One commit from review, as the sheet runs it on every client (the Mac's review pane, the
/// iPhone's and the iPad's review): the host's info and plain message, then its drafted message,
/// the files (all selected), where the commit goes, and the host's operation until it finishes.
/// A message nobody edited follows the ticked files: the plain one at once, a drafted one by
/// asking the host for a new draft once the ticks settle.
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
    public var title = "" {
        didSet { deriveNote() }
    }
    public var body = "" {
        didSet { deriveNote() }
    }
    public private(set) var selected: Set<String> = [] {
        didSet {
            derive()
            followSelection()
            followDraft()
            deriveNote()
        }
    }
    /// Push after commit (to the upstream, setting one when there is none).
    public var push = true
    /// Open a pull request instead: push the branch and open the PR.
    public var pullRequest = false
    public var confirmedWhileWorking = false
    /// The host is drafting the message, or will once the ticks settle.
    public private(set) var drafting = false
    /// The message on screen came from the host's draft of the diff.
    public private(set) var drafted = false
    /// The message was edited after files it was written for were unticked, so it may still
    /// mention them. It is never rewritten once edited; the sheet says so instead.
    public private(set) var mentionsUntickedFiles = false
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
    /// The written message is the one written from the file list, so it follows the selection.
    @ObservationIgnored private var writtenFromFiles = false
    /// The files the written message was written (or drafted) for.
    @ObservationIgnored private var writtenFor: Set<String> = []
    /// The draft request whose answer the sheet takes; any other answer is stale.
    @ObservationIgnored private var draftRequest: UUID?
    /// The draft asked for once the ticks settle.
    @ObservationIgnored var redraft: Task<Void, Never>?
    /// How long the ticks must stay put before a drafted message is drafted again, so ticking
    /// several files costs one draft.
    @ObservationIgnored public var redraftDelay: Duration = .milliseconds(600)
    /// Waits out `redraftDelay`; tests replace it.
    @ObservationIgnored public var pause: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    public init(query: ((RemoteAgentQuery) async throws -> RemoteAgentResult)? = nil) {
        self.query = query
    }

    // MARK: Derived

    public var destination: RemoteCommitPush { reviewCommitPush(push: push, pullRequest: pullRequest) }
    public var actionTitle: String { reviewCommitActionTitle(destination) }
    public var selectionText: String { reviewCommitSelectionText(selected: selectedFiles.count, of: info?.files.count ?? 0) }
    public var selectedFiles: [RemoteCommitFile] { info?.files.filter { selected.contains($0.id) } ?? [] }
    public var outcome: ReviewCommitOutcome? { operation.map(ReviewCommitOutcome.init) }

    /// Why Commit can't run: the host's refusal, the form, or a draft on screen that describes
    /// files since unticked while its replacement is drafted.
    public var problem: String? {
        guard let info else { return nil }
        if drafted && drafting && showsWritten && !selected.isEmpty { return "Redrafting the message…" }
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
        cancelDraft()
        self.info = info
        written = (info.title, info.body)
        writtenFromFiles = reviewCommitFallbackMessage(info.files) == written
        writtenFor = Set(info.files.map(\.id))
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
        writtenFromFiles = !drafted && reviewCommitFallbackMessage(selectedFiles) == written
        writtenFor = selected
        self.drafted = drafted
        self.drafting = drafting
        deriveNote()
    }

    /// Asks the host to draft the message from the diff of the ticked files, keeping anything
    /// typed meanwhile. Only the latest request's answer counts, and only while the ticks are the
    /// ones it asked about. A failed draft leaves a plain message on screen: the one already
    /// there, or, in place of a draft of other files, the plain one for the ticked files.
    public func draft() async {
        guard let info, info.draftsMessage, operationID == nil, let query else { return }
        let files = selectedFiles
        guard !files.isEmpty, showsWritten else {
            if draftRequest == nil { drafting = false }
            return
        }
        let id = UUID()
        let asked = selected
        draftRequest = id
        drafting = true
        var answer: (title: String, body: String, drafted: Bool)?
        do {
            if case .commitMessage(let title, let body, let drafted) = try await query(.commitMessage(paths: files.flatMap(\.paths))) {
                answer = (title, body, drafted)
            }
        } catch {
            // A failed draft is not worth a banner.
        }
        // A later request (the ticks moved on, the sheet reloaded) owns the message now.
        guard draftRequest == id else { return }
        draftRequest = nil
        drafting = false
        // Anything typed while the host drafted wins over the draft.
        guard self.info == info, operationID == nil, selected == asked, showsWritten else { return }
        if let answer, answer.drafted, !answer.title.isEmpty {
            write((answer.title, answer.body), for: asked, drafted: true)
        } else if drafted {
            // The draft on screen describes other files: the plain message for these instead.
            let plain = answer.flatMap { $0.title.isEmpty ? nil : ($0.title, $0.body) } ?? reviewCommitFallbackMessage(files)
            write(plain, for: asked, drafted: false)
        }
        // Otherwise the plain message on screen already follows the ticked files.
    }

    private func write(_ message: (title: String, body: String), for files: Set<String>, drafted: Bool) {
        written = message
        writtenFor = files
        writtenFromFiles = !drafted && reviewCommitFallbackMessage(selectedFiles) == written
        title = message.title
        body = message.body
        self.drafted = drafted
        deriveNote()
    }

    /// Forgets a draft asked for or in flight: its answer, when it comes, is stale.
    private func cancelDraft() {
        redraft?.cancel()
        redraft = nil
        draftRequest = nil
        drafting = false
    }

    // MARK: Selection

    public func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    public func selectAll(_ on: Bool) {
        selected = on ? Set(info?.files.map(\.id) ?? []) : []
    }

    private var showsWritten: Bool { title == written.title && body == written.body }

    /// The message written from the file list describes the ticked files until someone edits it.
    /// With nothing ticked it stays as it was, for the next tick to rewrite.
    private func followSelection() {
        guard writtenFromFiles, showsWritten, !selectedFiles.isEmpty else { return }
        writtenFor = selected
        let next = reviewCommitFallbackMessage(selectedFiles)
        guard next != written else { return }
        written = next
        title = next.title
        body = next.body
    }

    /// A drafted message nobody edited (or one being drafted) is drafted again for the ticked
    /// files once they stay put for `redraftDelay`. The draft on screen stays until the new one
    /// arrives. An edited message is never replaced, and with nothing ticked the draft waits for
    /// the next tick.
    private func followDraft() {
        guard stage == .form, operationID == nil, let info, info.draftsMessage, query != nil, drafted || drafting else { return }
        guard showsWritten, !selected.isEmpty, !(drafted && selected == writtenFor) else {
            cancelDraft()
            return
        }
        redraft?.cancel()
        // Whatever is in flight was asked for other ticks.
        draftRequest = nil
        drafting = true
        redraft = Task { [weak self] in
            guard let pause = self?.pause, let delay = self?.redraftDelay else { return }
            do { try await pause(delay) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.draft()
        }
    }

    /// An edited message may mention files unticked since it was written.
    private func deriveNote() {
        let next = !showsWritten && !selected.isEmpty && !writtenFor.isSubset(of: selected)
        if next != mentionsUntickedFiles { mentionsUntickedFiles = next }
    }

    // MARK: The operation

    /// Starts the commit on the host. A refusal brings the form back with why; an unknown
    /// outcome keeps polling rather than inviting a second commit.
    public func commit() async {
        guard canCommit, let info, let query else { return }
        cancelDraft()
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
            self.error = "\(Self.sentence(error)) Don't commit again; its status is checked again."
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

    /// Asks the host once how the commit stands; true once it finished. While the commit request
    /// is unanswered it asks nothing: the host knows the operation only once it has taken the
    /// request, so an earlier poll would read as an operation it has never heard of.
    @discardableResult
    public func pollOnce() async -> Bool {
        guard let id = operationID, let query else { return true }
        guard !submitting else { return false }
        do {
            if case .worktreeOperation(let status) = try await query(.worktreeStatus(operationID: id)), status.id == id {
                adopt(status)
                error = nil
            }
        } catch {
            self.error = "\(Self.sentence(error)) Don't commit again."
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
        cancelDraft()
        stage = .loading
        info = nil
        title = ""
        body = ""
        selected = []
        writtenFor = []
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

    /// `text(error)` as a sentence: its own full stop, or one added.
    static func sentence(_ error: Error) -> String {
        let text = self.text(error).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last, !".!?…".contains(last) else { return text }
        return text + "."
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
