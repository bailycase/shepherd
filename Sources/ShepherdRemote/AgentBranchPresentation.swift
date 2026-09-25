import Foundation
import ShepherdCore

/// What the thread header's branch chip says about where an agent works (Main, QuestionAsk,
/// TerminalSplit, MobileThread, iPadThread boards), on the Mac and iOS alike. A worktree Shepherd
/// made for the agent is a worktree; any other checkout is "your checkout", since pi edits the
/// files you work in there. The count is the files that differ from HEAD, as the agent's host
/// last read them (`Agent.checkout`); a remote agent's host is named after it.
public struct AgentBranchLabel: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case worktree, checkout
    }

    public let kind: Kind
    public let branch: String
    public let changedFiles: Int
    /// The host the agent runs on, when it is not this device's own.
    public let host: String?

    public init(kind: Kind, branch: String, changedFiles: Int = 0, host: String? = nil) {
        self.kind = kind
        self.branch = branch
        self.changedFiles = changedFiles
        self.host = host
    }

    /// Nil until the host has read a branch for an agent outside a worktree (or never will: its
    /// directory is no repository, or the host predates the chip). A worktree agent falls back
    /// to the branch Shepherd made for it.
    public init?(agent: Agent, host: String? = nil) {
        let checkout = agent.checkout
        if let worktree = agent.worktreeBranch {
            kind = .worktree
            branch = checkout?.branch ?? worktree
        } else if let checkout {
            kind = .checkout
            branch = checkout.branch
        } else {
            return nil
        }
        changedFiles = checkout?.changedFiles ?? 0
        self.host = host
    }

    /// The chip's tooltip: "Worktree · pi/x · 3 files changed · on horizon", then the directory
    /// on a second line when it is known.
    public func help(directory: String?) -> String {
        let summary = [kind == .worktree ? "Worktree" : "Your checkout", branch,
                       changedFiles > 0 ? "\(changedFiles) file\(changedFiles == 1 ? "" : "s") changed" : "no changes",
                       host.map { "on \($0)" }].compactMap { $0 }.joined(separator: " · ")
        return directory.map { "\(summary)\n\($0)" } ?? summary
    }
}
