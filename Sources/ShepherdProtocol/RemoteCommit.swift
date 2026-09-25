import Foundation

// A direct commit from review, run by the host (`RemoteAgentQuery.commitInfo`, `.commitMessage`
// and `.commit`, behind `RemoteProtocol.reviewCommitCapability`). The client asks what would be
// committed, drafts the message on the host, then starts the commit as an operation it polls
// with `.worktreeStatus`, as Finalize does. Every field past `path` decodes with a default, so a
// newer host's info still reads on an older client of this capability.

/// One changed file the commit can take: the review's path, the old path of a rename, and a
/// fingerprint of the file as the host saw it. The host commits a file only while its
/// fingerprint still matches, so a file that changed after the sheet opened is never committed
/// unseen.
public struct RemoteCommitFile: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var oldPath: String?
    /// "M", "A", "D" or "R".
    public var status: String
    public var added: Int
    public var removed: Int
    public var fingerprint: String

    public var id: String { path }

    /// Every path the commit takes for this file: a rename's old path and its new one.
    public var paths: [String] {
        guard let oldPath, oldPath != path else { return [path] }
        return [oldPath, path]
    }

    public init(path: String, oldPath: String? = nil, status: String, added: Int, removed: Int, fingerprint: String) {
        self.path = path; self.oldPath = oldPath; self.status = status
        self.added = added; self.removed = removed; self.fingerprint = fingerprint
    }

    private enum CodingKeys: String, CodingKey { case path, oldPath, status, added, removed, fingerprint }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        oldPath = try c.decodeIfPresent(String.self, forKey: .oldPath)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "M"
        added = try c.decodeIfPresent(Int.self, forKey: .added) ?? 0
        removed = try c.decodeIfPresent(Int.self, forKey: .removed) ?? 0
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
    }
}

/// What a commit from review would take, where it would go, and why the host would refuse it.
public struct RemoteCommitInfo: Codable, Hashable, Sendable {
    /// The repository's top level on the host.
    public var repository: String
    /// The checked-out branch; nil on a detached HEAD.
    public var branch: String?
    /// HEAD's commit when the host looked ("" before the first commit). The commit is refused if
    /// HEAD moved since.
    public var head: String
    /// The upstream a push goes to ("origin/feat-x"): the remote's branch of the same name. nil
    /// when the branch has none, or tracks another name (a push then sets its own).
    public var upstream: String?
    /// The remote a push sets the upstream on when there is none ("origin"); nil with no remote.
    public var pushRemote: String?
    /// The branch a pull request goes into ("main"); nil when the host can't tell.
    public var defaultBranch: String?
    /// The files the review shows, in its order.
    public var files: [RemoteCommitFile]
    /// A plain message written from the file list, until (or instead of) a drafted one.
    public var title: String
    public var body: String
    /// The host drafts a message from the diff on request (`commitMessage`).
    public var draftsMessage: Bool
    /// The agent is mid-turn: its files may still change. The commit needs a confirmation.
    public var agentWorking: Bool
    /// Why the host won't commit here (a detached HEAD, a merge or rebase in progress); nil when
    /// it will.
    public var blocked: String?

    /// Committing on the default branch: a pull request needs a new branch first.
    public var onDefaultBranch: Bool { branch != nil && branch == defaultBranch }

    public init(repository: String, branch: String?, head: String, upstream: String?, pushRemote: String?, defaultBranch: String?,
                files: [RemoteCommitFile], title: String, body: String, draftsMessage: Bool, agentWorking: Bool, blocked: String?) {
        self.repository = repository; self.branch = branch; self.head = head; self.upstream = upstream
        self.pushRemote = pushRemote; self.defaultBranch = defaultBranch; self.files = files
        self.title = title; self.body = body; self.draftsMessage = draftsMessage
        self.agentWorking = agentWorking; self.blocked = blocked
    }

    private enum CodingKeys: String, CodingKey {
        case repository, branch, head, upstream, pushRemote, defaultBranch, files, title, body, draftsMessage, agentWorking, blocked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repository = try c.decodeIfPresent(String.self, forKey: .repository) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        head = try c.decodeIfPresent(String.self, forKey: .head) ?? ""
        upstream = try c.decodeIfPresent(String.self, forKey: .upstream)
        pushRemote = try c.decodeIfPresent(String.self, forKey: .pushRemote)
        defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch)
        files = try c.decodeIfPresent([RemoteCommitFile].self, forKey: .files) ?? []
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        draftsMessage = try c.decodeIfPresent(Bool.self, forKey: .draftsMessage) ?? false
        agentWorking = try c.decodeIfPresent(Bool.self, forKey: .agentWorking) ?? false
        blocked = try c.decodeIfPresent(String.self, forKey: .blocked)
    }
}

/// Where a commit from review goes once made.
public enum RemoteCommitPush: String, Codable, Hashable, Sendable, CaseIterable {
    /// Stays local.
    case none
    /// Pushed to the branch's upstream, or to `pushRemote` with the upstream set when it has none.
    case upstream
    /// Pushed as a branch (a new one when on the default branch) with a pull request opened by gh.
    case pullRequest
}

/// A confirmed commit from review.
public struct RemoteCommitOptions: Codable, Hashable, Sendable {
    /// `RemoteCommitInfo.head` as the sheet showed it.
    public var head: String
    /// The files to commit, with the fingerprints the sheet showed. Nothing else is touched.
    public var files: [RemoteCommitFile]
    public var title: String
    public var body: String
    public var push: RemoteCommitPush
    /// The branch a pull request from the default branch creates first.
    public var newBranch: String?
    /// The reviewer confirmed committing while the agent works.
    public var confirmedWhileWorking: Bool

    public init(head: String, files: [RemoteCommitFile], title: String, body: String, push: RemoteCommitPush,
                newBranch: String? = nil, confirmedWhileWorking: Bool = false) {
        self.head = head; self.files = files; self.title = title; self.body = body
        self.push = push; self.newBranch = newBranch; self.confirmedWhileWorking = confirmedWhileWorking
    }

    private enum CodingKeys: String, CodingKey { case head, files, title, body, push, newBranch, confirmedWhileWorking }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        head = try c.decode(String.self, forKey: .head)
        files = try c.decode([RemoteCommitFile].self, forKey: .files)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        push = try c.decodeIfPresent(RemoteCommitPush.self, forKey: .push) ?? .none
        newBranch = try c.decodeIfPresent(String.self, forKey: .newBranch)
        confirmedWhileWorking = try c.decodeIfPresent(Bool.self, forKey: .confirmedWhileWorking) ?? false
    }
}
