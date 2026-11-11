import Foundation

// A shared design's Git state: what the host answers and the app draws, over
// its connection (`RemoteDesignRequest.gitState` …, `design.git.v1`).

// MARK: - What a shared design's Git status is

/// A shared design's Git state as the chip and the panel draw it (GitDesignChanges).
public struct DesignGitStatus: Hashable, Sendable, Codable {
    public struct File: Hashable, Sendable, Codable, Identifiable {
        /// The path in the repository: `project/A.dc.html` shows as `A.dc.html`.
        public var path: String
        /// M, A or D.
        public var letter: String
        public var id: String { path }
        public init(path: String, letter: String) {
            self.path = path
            self.letter = letter
        }
    }

    public struct Commit: Hashable, Sendable, Codable {
        public var hash: String
        public var subject: String
        public var author: String
        public var files: [String]
        public init(hash: String, subject: String, author: String, files: [String]) {
            self.hash = hash
            self.subject = subject
            self.author = author
            self.files = files
        }
    }

    public var branch: String
    /// The remote's URL as the user gave it.
    public var remoteURL: String
    /// The upstream's name ("origin/main").
    public var upstream: String
    /// Commits the branch has that the remote doesn't, and the reverse, as of the last fetch.
    public var ahead: Int
    public var behind: Int
    /// The working copy's changes against the last commit.
    public var files: [File]
    /// When the remote was last reached (ms since 1970); nil when the last fetch failed.
    public var fetchedAt: Double?
    /// The last fetch failed: Offline.
    public var offline: Bool
    /// The newest incoming commit, when the remote is ahead.
    public var incoming: Commit?
    /// The last push failed, and why.
    public var pushFailed: String?

    public init(branch: String, remoteURL: String, upstream: String, ahead: Int = 0, behind: Int = 0, files: [File] = [],
                fetchedAt: Double? = nil, offline: Bool = false, incoming: Commit? = nil, pushFailed: String? = nil) {
        self.branch = branch
        self.remoteURL = remoteURL
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.files = files
        self.fetchedAt = fetchedAt
        self.offline = offline
        self.incoming = incoming
        self.pushFailed = pushFailed
    }

    public var isClean: Bool { files.isEmpty }
}

/// A pull that needs a merge (GitDesignConflict): the two commits, and the merge copy's state.
public struct DesignGitMerge: Hashable, Sendable, Codable {
    public enum Phase: String, Equatable, Sendable, Codable {
        /// Waiting on the user: Keep working locally or Resolve with agent.
        case conflict
        /// The design agent is combining the two in the merge copy.
        case running
        /// The agent finished and the merge copy passes the checks: Review merge.
        case ready
        case stopped
        case failed
    }

    public var phase: Phase
    public var ours: DesignGitStatus.Commit
    public var theirs: DesignGitStatus.Commit
    /// The commits the merge joins.
    public var oursHash: String
    public var theirsHash: String
    /// Why the attempt failed, when it did.
    public var reason: String?
    /// The merge copy's tree when it became ready to review: Commit merge commits exactly this,
    /// and refuses a copy that changed since.
    public var reviewedTree: String?

    public init(phase: Phase, ours: DesignGitStatus.Commit, theirs: DesignGitStatus.Commit, oursHash: String, theirsHash: String,
                reason: String? = nil, reviewedTree: String? = nil) {
        self.phase = phase
        self.ours = ours
        self.theirs = theirs
        self.oursHash = oursHash
        self.theirsHash = theirsHash
        self.reason = reason
        self.reviewedTree = reviewedTree
    }
}

/// What the app shows for a design's Git state, and what each change answers.
public struct DesignGitState: Hashable, Sendable, Codable {
    public var status: DesignGitStatus
    /// A pull that needs a merge, while it is being handled.
    public var merge: DesignGitMerge?
    /// The merge copy's changed files, once it is ready to review.
    public var mergeFiles: [DesignGitStatus.File]

    public init(status: DesignGitStatus, merge: DesignGitMerge? = nil, mergeFiles: [DesignGitStatus.File] = []) {
        self.status = status
        self.merge = merge
        self.mergeFiles = mergeFiles
    }
}

/// What a pull did.
public enum DesignGitPullResult: Hashable, Sendable, Codable {
    case upToDate
    /// The design's files took the remote's commit; the canvas reloads.
    case updated
    case needsMerge(DesignGitMerge)
}
