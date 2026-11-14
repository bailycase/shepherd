import Foundation
import ShepherdCore

// Moving a thread to another Mac (`RemoteProtocol.fleetMoveCapability`, `FleetMove.swift` for the tombstone). A move is a
// dispatch of `kind: .move`: the same create, the same snapshot of the worktree (`fleetSnapshotPart`, `fleetBlobPush`), the same
// pushes. It differs in four ways:
//  - the create carries a `FleetMoveHandoff`, and the snapshot's header names the conversation (`FleetSnapshotHeader.transcript`);
//  - the receiving Mac builds the worktree and keeps what arrived, but starts no thread: it says so (`FleetMoveStage.staged`);
//  - the sending Mac then writes its tombstone and tells the receiver to go live (`FleetDispatchControl.commit`);
//  - a restart of the sender before it handed over cancels the move, and one after it repeats the handover until it is answered.
// The receiving Mac never starts a thread the sender hasn't handed over, so at most one Mac holds the thread live.

/// What `fleetDispatchCreate` carries of a thread that moves (`FleetDispatchCreate.move`): the thread as the receiver makes it, the
/// same thread with the same id.
public struct FleetMoveHandoff: Codable, Hashable, Sendable {
    public var agentID: AgentID
    /// The pi session the thread is in now (`Agent.effectivePiSessionID`): the conversation that arrives as the snapshot's transcript.
    public var sessionID: String
    public var name: String
    public var nameIsFinal: Bool
    public var model: String?
    public var thinking: String?
    public var serviceTier: String?
    public var pushMuted: Bool
    /// Where the thread came from when another Mac sent it work: it keeps that, so it still nests under its sender.
    public var dispatchedFrom: DispatchedFrom?
    /// The sender's record of that work, when the thread was sent work and hasn't returned its result: the receiver reports to the same
    /// Mac under the same id from now on.
    public var dispatch: FleetDispatchRecord?
    /// The thread's branch and base, as the sending Mac had them.
    public var branch: String?
    public var worktreeBase: String?
    /// Epoch milliseconds: when the sender last had it active, and when it handed it over.
    public var lastActiveAt: Double?
    public var movedAt: Double
    public var messages: Int
    public var uncommittedFiles: Int
    public var unpushedCommits: Int

    public init(agentID: AgentID, sessionID: String, name: String, nameIsFinal: Bool, model: String? = nil, thinking: String? = nil,
                serviceTier: String? = nil, pushMuted: Bool = false, dispatchedFrom: DispatchedFrom? = nil, dispatch: FleetDispatchRecord? = nil,
                branch: String? = nil, worktreeBase: String? = nil, lastActiveAt: Double? = nil, movedAt: Double, messages: Int = 0,
                uncommittedFiles: Int = 0, unpushedCommits: Int = 0) {
        self.agentID = agentID
        self.sessionID = sessionID
        self.name = name
        self.nameIsFinal = nameIsFinal
        self.model = model
        self.thinking = thinking
        self.serviceTier = serviceTier
        self.pushMuted = pushMuted
        self.dispatchedFrom = dispatchedFrom
        self.dispatch = dispatch
        self.branch = branch
        self.worktreeBase = worktreeBase
        self.lastActiveAt = lastActiveAt
        self.movedAt = movedAt
        self.messages = messages
        self.uncommittedFiles = uncommittedFiles
        self.unpushedCommits = unpushedCommits
    }

    private enum CodingKeys: String, CodingKey {
        case agentID, sessionID, name, nameIsFinal, model, thinking, serviceTier, pushMuted, dispatchedFrom, dispatch, branch, worktreeBase
        case lastActiveAt, movedAt, messages, uncommittedFiles, unpushedCommits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentID = try c.decode(AgentID.self, forKey: .agentID)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID) ?? agentID.rawValue
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        nameIsFinal = try c.decodeIfPresent(Bool.self, forKey: .nameIsFinal) ?? true
        model = try c.decodeIfPresent(String.self, forKey: .model)
        thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        serviceTier = try c.decodeIfPresent(String.self, forKey: .serviceTier)
        pushMuted = try c.decodeIfPresent(Bool.self, forKey: .pushMuted) ?? false
        dispatchedFrom = try? c.decodeIfPresent(DispatchedFrom.self, forKey: .dispatchedFrom)
        dispatch = try? c.decodeIfPresent(FleetDispatchRecord.self, forKey: .dispatch)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        worktreeBase = try c.decodeIfPresent(String.self, forKey: .worktreeBase)
        lastActiveAt = try c.decodeIfPresent(Double.self, forKey: .lastActiveAt)
        movedAt = try c.decodeIfPresent(Double.self, forKey: .movedAt) ?? 0
        messages = try c.decodeIfPresent(Int.self, forKey: .messages) ?? 0
        uncommittedFiles = try c.decodeIfPresent(Int.self, forKey: .uncommittedFiles) ?? 0
        unpushedCommits = try c.decodeIfPresent(Int.self, forKey: .unpushedCommits) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agentID, forKey: .agentID)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(name, forKey: .name)
        try c.encode(nameIsFinal, forKey: .nameIsFinal)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(thinking, forKey: .thinking)
        try c.encodeIfPresent(serviceTier, forKey: .serviceTier)
        if pushMuted { try c.encode(pushMuted, forKey: .pushMuted) }
        try c.encodeIfPresent(dispatchedFrom, forKey: .dispatchedFrom)
        try c.encodeIfPresent(dispatch, forKey: .dispatch)
        try c.encodeIfPresent(branch, forKey: .branch)
        try c.encodeIfPresent(worktreeBase, forKey: .worktreeBase)
        try c.encodeIfPresent(lastActiveAt, forKey: .lastActiveAt)
        try c.encode(movedAt, forKey: .movedAt)
        try c.encode(messages, forKey: .messages)
        if uncommittedFiles != 0 { try c.encode(uncommittedFiles, forKey: .uncommittedFiles) }
        if unpushedCommits != 0 { try c.encode(unpushedCommits, forKey: .unpushedCommits) }
    }

    /// Whether the numbers are ones a receiver will work with.
    public var isValid: Bool {
        !agentID.rawValue.isEmpty && agentID.rawValue.utf8.count <= 128 && !sessionID.isEmpty && sessionID.utf8.count <= 128
            && !sessionID.contains("/") && !sessionID.contains("\0") && name.utf8.count <= 1_024
    }
}

/// `FleetAction.moveThread`: move a thread of this Mac to another, from the thread's header, its menu or the palette, or from a phone's
/// thread menu (`RemoteAgentAction.moveToMac`). The id is made by the one that asks, so a retry can't move it twice.
public struct FleetMoveRequest: Codable, Hashable, Sendable {
    public enum When: String, Codable, Hashable, Sendable {
        /// Stop the turn, if one is running, and go.
        case now
        /// Wait for the turn to end first ("Move when it's done").
        case whenDone
    }

    public var moveID: UUID
    public var agentID: AgentID
    /// The Mac to move to: its fleet host id, or its name.
    public var host: String
    public var when: When

    public init(moveID: UUID = UUID(), agentID: AgentID, host: String, when: When = .now) {
        self.moveID = moveID
        self.agentID = agentID
        self.host = host
        self.when = when
    }

    private enum CodingKeys: String, CodingKey { case moveID, agentID, host, when }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        moveID = try c.decode(UUID.self, forKey: .moveID)
        agentID = try c.decode(AgentID.self, forKey: .agentID)
        host = try c.decode(String.self, forKey: .host)
        when = (try? c.decodeIfPresent(When.self, forKey: .when)) ?? .now
    }
}
