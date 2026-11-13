import CryptoKit
import Foundation
import ShepherdCore

// Dispatch (`RemoteProtocol.fleetDispatchCapability`): a thread on one Mac sends work to another.
// The sending host places it, sends `fleetDispatchCreate` over its link, and follows it; the
// receiving host makes the worktree and the thread and pushes what happens back to the sender
// (`fleetDispatchChanged`, `fleetDispatchResult`). Both Macs keep a `FleetDispatchRecord`.

/// The thread that sent a dispatch, as the receiver records it (`DispatchedFrom`).
public struct FleetDispatchSender: Codable, Hashable, Sendable {
    public var hostID: UUID
    public var hostName: String
    /// Nil for a thread the person started with Auto.
    public var agentID: AgentID?
    public var agentTitle: String

    public init(hostID: UUID, hostName: String, agentID: AgentID? = nil, agentTitle: String) {
        self.hostID = hostID
        self.hostName = hostName
        self.agentID = agentID
        self.agentTitle = agentTitle
    }
}

/// Where the receiving Mac gets the repository when it has no checkout of it (slice 4f): the sender's own origin, the space it belongs
/// to and its default base. The receiver finds a checkout it already has before it uses any of this; none of it is needed when it does.
public struct FleetRepoSource: Codable, Hashable, Sendable {
    /// The origin's URL as the sender reports it, with any password (and an https user) removed: what the receiver clones with its own
    /// git sign-in. Nil for a repository with no origin.
    public var origin: String?
    /// The sender's space for it, and its name: the receiver binds the checkout it finds or makes to the same space, so the fleet's
    /// space becomes one on this Mac with no "locate folder" step.
    public var spaceID: SpaceID?
    public var name: String?
    /// The space's default base branch, as the sender has it.
    public var worktreeBase: String?

    public init(origin: String? = nil, spaceID: SpaceID? = nil, name: String? = nil, worktreeBase: String? = nil) {
        self.origin = origin
        self.spaceID = spaceID
        self.name = name
        self.worktreeBase = worktreeBase
    }

    /// `origin` as it may be sent: a URL's password never leaves the Mac (an https user goes too, since it is only ever a token), and
    /// anything that could be read as an option is refused.
    public static func sanitized(origin: String) -> String? {
        let text = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("-"), !text.contains("\n"), !text.contains("\0"), text.utf8.count <= 2_048 else { return nil }
        guard let scheme = text.range(of: "://") else { return text }
        let rest = text[scheme.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var authority = String(rest[..<slash])
        if let at = authority.lastIndex(of: "@") {
            let user = authority[..<at]
            let web = ["http", "https"].contains(text[..<scheme.lowerBound].lowercased())
            if web { authority = String(authority[authority.index(after: at)...]) }
            else if let colon = user.firstIndex(of: ":") { authority = String(user[..<colon]) + String(authority[at...]) }
        }
        return String(text[..<scheme.upperBound]) + authority + String(rest[slash...])
    }
}

/// `RemoteRequest.fleetDispatchCreate`: start this work on the receiving Mac. The receiver resolves
/// `repoKey` against its own spaces, needs `commitSHA`, makes a fresh worktree on its own branch
/// and starts a thread there with `task` as its first message. Idempotent on `dispatchID`.
public struct FleetDispatchCreate: Codable, Hashable, Sendable {
    public var dispatchID: UUID
    public var kind: FleetDispatchRecord.Kind
    public var task: String
    public var title: String
    public var repoKey: String
    /// The commit to start from. Nil for a thread the person started with Auto, which starts from the
    /// space's base on the receiver.
    public var commitSHA: String?
    /// A folder under the repo's root the thread works in.
    public var subdir: String?
    /// The branch name asked for; nil lets the receiver derive `fleet/<title>`.
    public var branch: String?
    public var model: String?
    public var thinking: String?
    public var from: FleetDispatchSender
    /// What the work carries beyond its commit (slice 4c): edits, untracked and ignored files, and the unpushed commits. The
    /// parts and contents follow (`fleetSnapshotPart`, `fleetBlobPush`); the receiver starts the thread once they check out.
    public var snapshot: FleetSnapshotHeader?
    /// Where to get the repository when the receiver has no checkout of it (slice 4f). Nil from an older sender, which is refused
    /// `repo_missing` by a receiver with no checkout, as before.
    public var repo: FleetRepoSource?
    /// Where a thread the person started begins (the New thread form's workplace choice); nil for a thread's dispatch.
    public var start: FleetThreadStart?

    public init(dispatchID: UUID, kind: FleetDispatchRecord.Kind = .agentDispatch, task: String, title: String, repoKey: String,
                commitSHA: String? = nil, subdir: String? = nil, branch: String? = nil, model: String? = nil, thinking: String? = nil,
                from: FleetDispatchSender, snapshot: FleetSnapshotHeader? = nil, repo: FleetRepoSource? = nil, start: FleetThreadStart? = nil) {
        self.start = start
        self.dispatchID = dispatchID
        self.kind = kind
        self.task = task
        self.title = title
        self.repoKey = repoKey
        self.commitSHA = commitSHA
        self.subdir = subdir
        self.branch = branch
        self.model = model
        self.thinking = thinking
        self.from = from
        self.snapshot = snapshot
        self.repo = repo
    }

    private enum CodingKeys: String, CodingKey { case dispatchID, kind, task, title, repoKey, commitSHA, subdir, branch, model, thinking, from, snapshot, repo, start }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dispatchID = try c.decode(UUID.self, forKey: .dispatchID)
        kind = (try? c.decodeIfPresent(FleetDispatchRecord.Kind.self, forKey: .kind)) ?? .agentDispatch
        task = try c.decode(String.self, forKey: .task)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        repoKey = try c.decode(String.self, forKey: .repoKey)
        commitSHA = try c.decodeIfPresent(String.self, forKey: .commitSHA)
        subdir = try c.decodeIfPresent(String.self, forKey: .subdir)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        from = try c.decode(FleetDispatchSender.self, forKey: .from)
        snapshot = try c.decodeIfPresent(FleetSnapshotHeader.self, forKey: .snapshot)
        repo = try c.decodeIfPresent(FleetRepoSource.self, forKey: .repo)
        start = try c.decodeIfPresent(FleetThreadStart.self, forKey: .start)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dispatchID, forKey: .dispatchID)
        try c.encode(kind, forKey: .kind)
        try c.encode(task, forKey: .task)
        try c.encode(title, forKey: .title)
        try c.encode(repoKey, forKey: .repoKey)
        try c.encodeIfPresent(commitSHA, forKey: .commitSHA)
        try c.encodeIfPresent(subdir, forKey: .subdir)
        try c.encodeIfPresent(branch, forKey: .branch)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(thinking, forKey: .thinking)
        try c.encode(from, forKey: .from)
        try c.encodeIfPresent(snapshot, forKey: .snapshot)
        try c.encodeIfPresent(repo, forKey: .repo)
        try c.encodeIfPresent(start, forKey: .start)
    }
}

/// `FleetAction.sendThread`: a thread the person started in New thread, to run on the Mac Auto picks or on one named. The
/// folder is one of this Mac's spaces; the Mac that runs it finds its own checkout of the same repository. The id is made
/// by the app, so a retry can't start it twice.
public struct FleetUserThread: Codable, Hashable, Sendable {
    public var dispatchID: UUID
    /// A space of the Mac the app belongs to.
    public var spaceID: SpaceID
    public var task: String
    public var title: String?
    /// A Mac's name or id, or nil (or "auto") for Auto.
    public var host: String?
    public var model: String?
    public var thinking: String?
    /// The form's workplace choice: a new worktree from a base, a new worktree on an existing branch, or the space's own checkout. Nil is a
    /// new worktree from the base Settings ▸ Worktrees and the project give (as a form left at its defaults would).
    public var start: FleetThreadStart?

    public init(dispatchID: UUID = UUID(), spaceID: SpaceID, task: String, title: String? = nil, host: String? = nil,
                model: String? = nil, thinking: String? = nil, start: FleetThreadStart? = nil) {
        self.start = start
        self.dispatchID = dispatchID
        self.spaceID = spaceID
        self.task = task
        self.title = title
        self.host = host
        self.model = model
        self.thinking = thinking
    }
}

/// How a message to a dispatched thread is delivered: after its current turn, or into it.
public enum FleetMessageDelivery: String, Codable, Hashable, Sendable {
    case followUp, steer
}

/// `RemoteRequest.fleetDispatchControl`: ask the Mac running a dispatch about it or act on it.
public enum FleetDispatchControl: Codable, Hashable, Sendable {
    case status
    /// Stop the thread there.
    case cancel
    /// Send the thread a message. A finished dispatch starts a new run on the same thread.
    case message(text: String, delivery: FleetMessageDelivery)

    private enum Kind: String, Codable { case status, cancel, message }
    private enum CodingKeys: String, CodingKey { case type, text, delivery }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .status: self = .status
        case .cancel: self = .cancel
        case .message:
            self = .message(text: try c.decode(String.self, forKey: .text),
                            delivery: (try? c.decodeIfPresent(FleetMessageDelivery.self, forKey: .delivery)) ?? .followUp)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status: try c.encode(Kind.status, forKey: .type)
        case .cancel: try c.encode(Kind.cancel, forKey: .type)
        case .message(let text, let delivery):
            try c.encode(Kind.message, forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encode(delivery, forKey: .delivery)
        }
    }
}

public enum FleetDispatchProtocol {
    /// What a dispatched thread's first message adds after the task (`FleetDispatch.prompt`): a rule line, then the sentence
    /// naming who sent it. The From box draws the task alone, so it cuts the message here.
    public static let promptSeparator = "\n\n---\nYou were started by "

    /// The codes the receiver answers a refused create or control with.
    public enum Code {
        /// The receiver holds no dispatch with that id.
        public static let unknownDispatch = "unknown_dispatch"
    }

    /// The longest task the receiver takes, and the longest result it sends back (bytes).
    public static let maxTaskBytes = 64 * 1024
    public static let maxResultBytes = 32 * 1024
    /// Running dispatches one Mac takes from the fleet; past it the receiver answers `waitingRoom`.
    public static let admissionLimit = 8
    /// A dispatch the target accepted counts as a promised place for this long (seconds), so two
    /// parents in one tick don't send to the same Mac.
    public static let reservationLifetime: TimeInterval = 60
}

// MARK: - What an agent's fleet tools are told

/// One Mac as `fleet_hosts` lists it to a thread.
public struct FleetHostInfo: Codable, Hashable, Sendable {
    public var name: String
    /// The Mac the thread runs on.
    public var isThisMac: Bool
    /// "most room", "some room", "little room", "no room" or "not counted": the Fleet page's words, lowercased.
    public var room: String
    public var connected: Bool
    /// What it lacks that stops work (git, and Xcode when this thread's repository has an Xcode project); empty when it is ready.
    public var problems: [String]
    /// The commands of MCP servers it lacks: a thread sent there starts without those servers. Nil when it lacks none.
    public var without: [String]?
    /// Whether it has this thread's repository; nil when it hasn't said.
    public var hasRepo: Bool?
    /// "Prefer", "Normal", "Less often" or "Manual only".
    public var weight: String

    public init(name: String, isThisMac: Bool, room: String, connected: Bool, problems: [String] = [], without: [String]? = nil, hasRepo: Bool? = nil, weight: String) {
        self.name = name
        self.isThisMac = isThisMac
        self.room = room
        self.connected = connected
        self.problems = problems
        self.without = without
        self.hasRepo = hasRepo
        self.weight = weight
    }
}

/// A dispatch as a thread's `fleet_*` tools see it. Data, never instructions: `resultText` is what the
/// dispatched thread said.
public struct FleetDispatchInfo: Codable, Hashable, Sendable {
    public var dispatchID: String
    /// A `FleetDispatchState` raw value.
    public var state: String
    /// The Mac it went to, once chosen.
    public var host: String?
    public var title: String
    public var branch: String?
    public var activity: String?
    public var resultText: String?
    public var branchFacts: FleetBranchFacts?
    /// A `FleetDispatchCode` when it failed or was refused.
    public var failure: String?
    public var detail: String?
    /// The MCP server commands the Mac lacked: the thread started without those servers. Nil when none.
    public var without: [String]?

    public init(dispatchID: String, state: String, host: String? = nil, title: String = "", branch: String? = nil, activity: String? = nil,
                resultText: String? = nil, branchFacts: FleetBranchFacts? = nil, failure: String? = nil, detail: String? = nil,
                without: [String]? = nil) {
        self.dispatchID = dispatchID
        self.state = state
        self.host = host
        self.title = title
        self.branch = branch
        self.activity = activity
        self.resultText = resultText
        self.branchFacts = branchFacts
        self.failure = failure
        self.detail = detail
        self.without = without
    }

    public init(_ record: FleetDispatchRecord) {
        self.init(dispatchID: record.id.uuidString.lowercased(), state: record.state.rawValue, host: record.targetHostName, title: record.title,
                  branch: record.branch, activity: record.activity, resultText: record.resultText, branchFacts: record.resultBranchFacts,
                  failure: record.failure, detail: record.failureDetail, without: record.without.isEmpty ? nil : record.without)
    }
}

/// The id of the dispatch a `fleet_dispatch` tool call made. The panes extension derives it from the thread and the call
/// (`dispatchIDFor` in shepherd-panes.ts), so a retried call can't start the work twice; a client derives the same id to
/// find the dispatch a call in the transcript made.
public enum FleetDispatchID {
    public static func forToolCall(_ toolCallID: String, agent: AgentID) -> UUID? {
        let digest = SHA256.hash(data: Data("\(agent.rawValue)\0\(toolCallID)".utf8))
        let hex = Array(digest.map { String(format: "%02x", $0) }.joined())
        guard hex.count == 64, let variantNibble = UInt8(String(hex[16]), radix: 16) else { return nil }
        let variant = String((variantNibble & 0x3) | 0x8, radix: 16)
        func part(_ range: Range<Int>) -> String { String(hex[range]) }
        return UUID(uuidString: "\(part(0..<8))-\(part(8..<12))-5\(part(13..<16))-\(variant)\(part(17..<20))-\(part(20..<32))")
    }
}
