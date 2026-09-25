import Foundation
import ShepherdProtocol

// Finalize over the remote protocol, as a client draws it: the host's prerequisite checks, the
// form's gates, and the pipeline's steps read back from the operation's progress lines. The
// host runs the pipeline (commit → push → PR → optional merge → clean gate → remove worktree →
// delete local branch); each step gates the next, and nothing is removed before the clean gate.

/// One of the host's prerequisite checks, in the order the host probes them.
public struct FinalizeCheckRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let state: RemoteWorktreeCheckState

    public init(id: String, label: String, state: RemoteWorktreeCheckState) {
        self.id = id
        self.label = label
        self.state = state
    }
}

/// The host's checks by the keys it reports (`WorktreeSetupCheck` on the Mac); a check the host
/// did not report is pending, and one this client does not know is listed after the rest.
public func finalizeCheckRows(_ setup: RemoteWorktreeSetup) -> [FinalizeCheckRow] {
    let known: [(String, String)] = [
        ("git", "Git installed"), ("identity", "Git identity"), ("remote", "Origin reachable"),
        ("gh", "GitHub CLI"), ("ghAuth", "GitHub CLI signed in"),
    ]
    let knownIDs = Set(known.map(\.0))
    let extra = setup.checks.keys.filter { !knownIDs.contains($0) }.sorted().map { ($0, $0) }
    return (known + extra).map { id, label in FinalizeCheckRow(id: id, label: label, state: setup.checks[id] ?? .pending) }
}

/// Whether every check the host reports passes (and it reported some).
public func finalizeChecksPass(_ setup: RemoteWorktreeSetup) -> Bool {
    !setup.checks.isEmpty && setup.checks.values.allSatisfy(\.passed)
}

/// Why the form can't finalize yet, or nil when it can: the host needs a base, a title and a
/// merge method it supports.
public func finalizeFormProblem(_ options: RemoteFinalizeOptions) -> String? {
    if options.base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Choose a base branch." }
    if options.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the pull request a title." }
    if !["squash", "merge", "rebase"].contains(options.mergeMethod) { return "Choose squash, merge or rebase." }
    return nil
}

/// The included-commit count a wrong base usually inflates: past it, the count is a warning.
public let finalizeCommitWarningCount = 20

/// One step of the host's pipeline.
public struct FinalizeStep: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case pending
        case running
        /// Done or skipped, with what the host said ("committed", "nothing to commit").
        case done(String)
        case failed(String)
    }

    public let label: String
    public let state: State
    public var id: String { label }

    public init(label: String, state: State) {
        self.label = label
        self.state = state
    }
}

/// The host's progress lines ("push branch to origin: pushed") as steps. A line without a
/// detail is a step the host has finished.
public func finalizeSteps(_ progress: [String]) -> [FinalizeStep] {
    progress.map { line in
        guard let colon = line.range(of: ": ") else { return FinalizeStep(label: line, state: .done("")) }
        let label = String(line[..<colon.lowerBound])
        let detail = String(line[colon.upperBound...])
        let state: FinalizeStep.State
        if detail == "pending" {
            state = .pending
        } else if detail == "working…" || detail == "working..." {
            state = .running
        } else if detail.hasPrefix("failed: ") {
            state = .failed(String(detail.dropFirst("failed: ".count)))
        } else {
            state = .done(detail)
        }
        return FinalizeStep(label: label, state: state)
    }
}

/// Where a finalize operation stands.
public enum FinalizeOutcome: Equatable, Sendable {
    case running
    case succeeded(prURL: String?)
    case failed(String)

    public init(_ operation: RemoteWorktreeOperation) {
        if !operation.finished {
            self = .running
        } else if let error = operation.error {
            self = .failed(error)
        } else {
            self = .succeeded(prURL: operation.prURL)
        }
    }
}
