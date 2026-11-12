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

    public init(dispatchID: UUID, kind: FleetDispatchRecord.Kind = .agentDispatch, task: String, title: String, repoKey: String,
                commitSHA: String? = nil, subdir: String? = nil, branch: String? = nil, model: String? = nil, thinking: String? = nil,
                from: FleetDispatchSender) {
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
    }

    private enum CodingKeys: String, CodingKey { case dispatchID, kind, task, title, repoKey, commitSHA, subdir, branch, model, thinking, from }

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
    /// What it lacks (a program), if anything; empty when it is ready.
    public var problems: [String]
    /// Whether it has this thread's repository; nil when it hasn't said.
    public var hasRepo: Bool?
    /// "Prefer", "Normal", "Less often" or "Manual only".
    public var weight: String

    public init(name: String, isThisMac: Bool, room: String, connected: Bool, problems: [String] = [], hasRepo: Bool? = nil, weight: String) {
        self.name = name
        self.isThisMac = isThisMac
        self.room = room
        self.connected = connected
        self.problems = problems
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

    public init(dispatchID: String, state: String, host: String? = nil, title: String = "", branch: String? = nil, activity: String? = nil,
                resultText: String? = nil, branchFacts: FleetBranchFacts? = nil, failure: String? = nil, detail: String? = nil) {
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
    }

    public init(_ record: FleetDispatchRecord) {
        self.init(dispatchID: record.id.uuidString.lowercased(), state: record.state.rawValue, host: record.targetHostName, title: record.title,
                  branch: record.branch, activity: record.activity, resultText: record.resultText, branchFacts: record.resultBranchFacts,
                  failure: record.failure, detail: record.failureDetail)
    }
}
