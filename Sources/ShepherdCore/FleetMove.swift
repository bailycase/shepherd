import Foundation

// Moving a thread to another Mac (`RemoteProtocol.fleetMoveCapability`). A thread is one conversation with one id on every
// Mac of a fleet, and at most one Mac holds it live. The Mac it leaves keeps a tombstone (`Agent.movedTo`) that no code path
// resumes, and the Mac it arrives on keeps where it came from (`Agent.movedFrom`).

/// Where a thread went (`Agent.movedTo`): the tombstone its old Mac keeps. A thread with one is never started, resumed,
/// recovered or sent to, whatever else asks, and it is left out of the state every client reads (`ShepherdState.withoutMoved`).
/// Persisted until the thread comes back to this Mac.
public struct MovedTo: Codable, Hashable, Sendable {
    public var hostID: UUID
    public var hostName: String
    /// Epoch milliseconds.
    public var at: Double
    /// The move that took it (`FleetDispatchRecord.id`), so a repeated confirmation is the same one.
    public var moveID: UUID

    public init(hostID: UUID, hostName: String, at: Double, moveID: UUID) {
        self.hostID = hostID
        self.hostName = hostName
        self.at = at
        self.moveID = moveID
    }
}

/// Where a thread came from (`Agent.movedFrom`), kept by the Mac that runs it: "moved from This Mac · 14:02" in its header.
public struct MovedFrom: Codable, Hashable, Sendable {
    public var hostID: UUID
    public var hostName: String
    /// Epoch milliseconds.
    public var at: Double
    public var moveID: UUID
    public var branch: String?
    public var uncommittedFiles: Int

    public init(hostID: UUID, hostName: String, at: Double, moveID: UUID, branch: String? = nil, uncommittedFiles: Int = 0) {
        self.hostID = hostID
        self.hostName = hostName
        self.at = at
        self.moveID = moveID
        self.branch = branch
        self.uncommittedFiles = uncommittedFiles
    }

    private enum CodingKeys: String, CodingKey { case hostID, hostName, at, moveID, branch, uncommittedFiles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try c.decode(UUID.self, forKey: .hostID)
        hostName = try c.decodeIfPresent(String.self, forKey: .hostName) ?? ""
        at = try c.decodeIfPresent(Double.self, forKey: .at) ?? 0
        moveID = try c.decode(UUID.self, forKey: .moveID)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        uncommittedFiles = try c.decodeIfPresent(Int.self, forKey: .uncommittedFiles) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hostID, forKey: .hostID)
        try c.encode(hostName, forKey: .hostName)
        try c.encode(at, forKey: .at)
        try c.encode(moveID, forKey: .moveID)
        try c.encodeIfPresent(branch, forKey: .branch)
        if uncommittedFiles != 0 { try c.encode(uncommittedFiles, forKey: .uncommittedFiles) }
    }
}

/// How far a move has got, as both Macs and the progress card say it (FleetMove: "Stopped the turn", "Sent the conversation",
/// "Sending the worktree", "Starting on Mac mini").
public enum FleetMoveStage: String, Codable, Hashable, Sendable, CaseIterable {
    /// "Move when it's done": the thread is working, and the move begins when its turn ends.
    case waitingTurn
    /// The turn is being stopped, and the thread's pi with it.
    case stopping
    /// The conversation is being sent.
    case conversation
    /// The worktree is being sent.
    case worktree
    /// The other Mac holds everything and waits for the source to hand over (its worktree is built, no thread exists yet).
    case staged
    /// The source handed over and the other Mac is starting the thread.
    case starting
    /// The thread runs on the other Mac.
    case moved

    /// The steps the card draws, in order: the stage each is done at.
    public var order: Int {
        switch self {
        case .waitingTurn: 0
        case .stopping: 1
        case .conversation: 2
        case .worktree: 3
        case .staged: 4
        case .starting: 5
        case .moved: 6
        }
    }
}

/// What a move carries on its dispatch record (`FleetDispatchRecord.move`): enough for the progress card and the divider, and
/// for either Mac to settle the move after a restart.
public struct FleetMoveInfo: Codable, Hashable, Sendable {
    public var agentID: AgentID
    public var stage: FleetMoveStage
    /// The thread's current pi session (`Agent.effectivePiSessionID`).
    public var sessionID: String
    /// The move was asked to wait for the end of the turn.
    public var whenDone: Bool
    /// Messages in the conversation, and its size in bytes: "412 messages · 1.8 MB".
    public var messages: Int?
    public var transcriptBytes: UInt64?
    /// "3 uncommitted files, 1 unpushed commit".
    public var uncommittedFiles: Int?
    public var unpushedCommits: Int?
    /// The source handed over: its tombstone is written, and the other Mac starts the thread whenever it is told (a repeated
    /// confirmation is the same one). Set only on the source's record.
    public var committed: Bool
    /// The source restarted before it handed over: the other Mac is still to be told to drop what it holds. Source's record only.
    public var cancelPending: Bool
    /// Epoch milliseconds the thread was handed over.
    public var movedAt: Double?

    public init(agentID: AgentID, stage: FleetMoveStage, sessionID: String, whenDone: Bool = false, messages: Int? = nil,
                transcriptBytes: UInt64? = nil, uncommittedFiles: Int? = nil, unpushedCommits: Int? = nil, committed: Bool = false,
                cancelPending: Bool = false, movedAt: Double? = nil) {
        self.agentID = agentID
        self.stage = stage
        self.sessionID = sessionID
        self.whenDone = whenDone
        self.messages = messages
        self.transcriptBytes = transcriptBytes
        self.uncommittedFiles = uncommittedFiles
        self.unpushedCommits = unpushedCommits
        self.committed = committed
        self.cancelPending = cancelPending
        self.movedAt = movedAt
    }

    private enum CodingKeys: String, CodingKey {
        case agentID, stage, sessionID, whenDone, messages, transcriptBytes, uncommittedFiles, unpushedCommits, committed, cancelPending, movedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentID = try c.decode(AgentID.self, forKey: .agentID)
        stage = (try? c.decodeIfPresent(FleetMoveStage.self, forKey: .stage)) ?? .stopping
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID) ?? agentID.rawValue
        whenDone = try c.decodeIfPresent(Bool.self, forKey: .whenDone) ?? false
        messages = try c.decodeIfPresent(Int.self, forKey: .messages)
        transcriptBytes = try c.decodeIfPresent(UInt64.self, forKey: .transcriptBytes)
        uncommittedFiles = try c.decodeIfPresent(Int.self, forKey: .uncommittedFiles)
        unpushedCommits = try c.decodeIfPresent(Int.self, forKey: .unpushedCommits)
        committed = try c.decodeIfPresent(Bool.self, forKey: .committed) ?? false
        cancelPending = try c.decodeIfPresent(Bool.self, forKey: .cancelPending) ?? false
        movedAt = try c.decodeIfPresent(Double.self, forKey: .movedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agentID, forKey: .agentID)
        try c.encode(stage, forKey: .stage)
        try c.encode(sessionID, forKey: .sessionID)
        if whenDone { try c.encode(whenDone, forKey: .whenDone) }
        try c.encodeIfPresent(messages, forKey: .messages)
        try c.encodeIfPresent(transcriptBytes, forKey: .transcriptBytes)
        try c.encodeIfPresent(uncommittedFiles, forKey: .uncommittedFiles)
        try c.encodeIfPresent(unpushedCommits, forKey: .unpushedCommits)
        if committed { try c.encode(committed, forKey: .committed) }
        if cancelPending { try c.encode(cancelPending, forKey: .cancelPending) }
        try c.encodeIfPresent(movedAt, forKey: .movedAt)
    }
}

/// A dispatched thread that moved on: the Mac it was running on tells the Mac that sent it, so the sender follows it and the result
/// still comes back (`FleetDispatchRecord.movedOn`).
public struct FleetMovedOn: Codable, Hashable, Sendable {
    public var hostID: UUID
    public var hostName: String

    public init(hostID: UUID, hostName: String) {
        self.hostID = hostID
        self.hostName = hostName
    }
}

extension ShepherdState {
    /// The workspace without the threads that moved to another Mac, and their tabs: what every client reads. A tombstone is
    /// the host's own, never a thread a client could open or answer.
    public var withoutMoved: ShepherdState {
        guard agents.contains(where: { $0.movedTo != nil }) else { return self }
        var state = self
        let gone = agents.filter { $0.movedTo != nil }
        let ids = Set(gone.map(\.id)), tabs = Set(gone.map(\.tabID))
        state.agents.removeAll { ids.contains($0.id) }
        state.tabs.removeAll { tabs.contains($0.id) }
        return state
    }
}
