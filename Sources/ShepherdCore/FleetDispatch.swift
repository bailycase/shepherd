import Foundation

/// Where a dispatched thread came from, kept on the thread (`Agent.dispatchedFrom`). The title and
/// the Mac's name are snapshots: the sender may be renamed, or live on another host. Written only
/// when set, and it rides `ShepherdState` to every client, so no client needs another request to
/// draw "sent by".
public struct DispatchedFrom: Codable, Hashable, Sendable {
    public var hostID: UUID
    public var hostName: String
    /// The thread that sent the work; nil for a thread the person started with Auto.
    public var agentID: AgentID?
    public var agentTitle: String
    public var dispatchID: UUID
    /// Epoch milliseconds.
    public var at: Double

    public init(hostID: UUID, hostName: String, agentID: AgentID? = nil, agentTitle: String, dispatchID: UUID, at: Double) {
        self.hostID = hostID
        self.hostName = hostName
        self.agentID = agentID
        self.agentTitle = agentTitle
        self.dispatchID = dispatchID
        self.at = at
    }
}

/// Where a dispatch is. Both Macs keep a record and use the same words (`FleetDispatchRecord`).
public enum FleetDispatchState: String, Codable, Hashable, Sendable, CaseIterable {
    /// Choosing a Mac.
    case placing
    /// No Mac has room now; it goes when one does.
    case waitingRoom
    /// The named Mac is asleep or unreachable; it goes when it wakes.
    case waitingWake
    /// The parent thread already has as many live dispatches as the cap allows.
    case heldLimit
    /// The sending host restarted before this was placed. Nothing is sent again by itself.
    case heldRestart
    /// The target is fetching and making the worktree.
    case preparing
    case running
    /// The result is held for the thread (or Mac) it goes back to.
    case delivering
    case done
    case failed
    case cancelled

    /// Counts against the parent thread's cap: work in the air or on a Mac.
    public var countsAgainstCap: Bool {
        switch self {
        case .placing, .waitingRoom, .waitingWake, .preparing, .running: true
        case .heldLimit, .heldRestart, .delivering, .done, .failed, .cancelled: false
        }
    }

    /// Stop on the parent cancels it, and the host keeps following it.
    public var isLive: Bool {
        switch self {
        case .placing, .waitingRoom, .waitingWake, .heldLimit, .heldRestart, .preparing, .running, .delivering: true
        case .done, .failed, .cancelled: false
        }
    }
}

/// The codes a dispatch ends or is refused with (`FleetDispatchRecord.failure`). The text is the
/// UI's: nothing here is prose.
public enum FleetDispatchCode {
    public static let fleetOff = "fleet_off"
    public static let sendOff = "send_off"
    /// A dispatched, mission, project, coordinator, design or automation thread tried to dispatch.
    public static let fleetScope = "fleet_scope"
    public static let noSuchHost = "no_such_host"
    public static let hostNotReady = "host_not_ready"
    public static let repoMissing = "repo_missing"
    public static let repoAmbiguous = "repo_ambiguous"
    public static let commitUnreachable = "commit_unreachable"
    public static let snapshotTooLarge = "snapshot_too_large"
    public static let snapshotMismatch = "snapshot_mismatch"
    public static let snapshotFailed = "snapshot_failed"
    /// The target refused with a code this build doesn't know (`failureDetail` holds it).
    public static let refused = "refused"
    public static let peerGone = "peer_gone"
    public static let invalid = "invalid"
}

/// Why placement chose a Mac (`FleetPlacement`): codes and numbers, never prose. The UI turns them
/// into the drawn words ("Mac mini had 3.4x the room").
public struct FleetPlacementReason: Codable, Hashable, Sendable {
    public enum Code: String, Codable, Hashable, Sendable {
        /// The person or thread named the Mac.
        case named
        /// It scored highest among the Macs with room.
        case mostRoom
        /// It was the only Mac that could take the work.
        case onlyChoice
        /// The sending Mac couldn't take it; `skip` says why.
        case localIneligible
        /// A peer scored higher but not by the margin, so the work stayed here.
        case keptLocal
    }

    public var code: Code
    /// Why a Mac was left out (`FleetRoom.Skip`'s name), for `localIneligible`.
    public var skip: String?
    /// How many times the winner's room beat this Mac's, where that was weighed.
    public var ratio: Double?

    public init(_ code: Code, skip: String? = nil, ratio: Double? = nil) {
        self.code = code
        self.skip = skip
        self.ratio = ratio
    }
}

/// What a dispatched thread's branch looked like when it finished, as the Mac that ran it read it
/// (the host only verifies and reports; the agent commits and pushes itself).
public struct FleetBranchFacts: Codable, Hashable, Sendable {
    public var branch: String
    /// The branch's head commit.
    public var head: String?
    /// Commits the branch has beyond the commit the work started from.
    public var ahead: Int
    /// Origin has this head.
    public var pushed: Bool
    public var filesChanged: Int
    public var insertions: Int
    public var deletions: Int

    public init(branch: String, head: String? = nil, ahead: Int = 0, pushed: Bool = false,
                filesChanged: Int = 0, insertions: Int = 0, deletions: Int = 0) {
        self.branch = branch
        self.head = head
        self.ahead = ahead
        self.pushed = pushed
        self.filesChanged = filesChanged
        self.insertions = insertions
        self.deletions = deletions
    }
}

/// One dispatch: work a thread (or the person, `userThread`) sent to another Mac. Both Macs keep
/// one: the sender's is what the Dispatches log and `fleet_read` show, the receiver's is the
/// idempotency index (`id` to its thread), so a retried create returns the thread it already
/// started. Decodes with defaults, so a file from an older build still loads.
public struct FleetDispatchRecord: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// A thread sent it.
        case agentDispatch
        /// The person started it from New Thread's Auto chip: no parent thread.
        case userThread
    }

    public var id: UUID
    public var kind: Kind
    public var parentAgentID: AgentID?
    public var parentHostID: UUID
    /// The sending Mac's name when it was sent (a snapshot).
    public var parentHostName: String
    public var parentTitle: String
    public var targetHostID: UUID?
    public var targetHostName: String?
    /// The Mac the sender asked for by name; nil for Auto.
    public var requestedHost: String?
    public var state: FleetDispatchState
    /// The code it failed or was refused with (`FleetDispatchCode`); set with `.failed`.
    public var failure: String?
    public var failureDetail: String?
    public var title: String
    /// What the thread was asked to do. Data: nothing reads it as an instruction but the thread it was sent to.
    public var task: String
    public var repoKey: String
    /// The pinned commit the work starts from.
    public var commitSHA: String?
    /// A folder under the repo's root the thread works in.
    public var subdir: String?
    /// The branch the target made (`fleet/<slug>`), written before the worktree exists so a retry agrees.
    public var branch: String?
    public var model: String?
    public var thinking: String?
    public var reasonCodes: [FleetPlacementReason]
    /// The thread on the target.
    public var remoteAgentID: AgentID?
    /// What the thread is doing, in a line, as the target last said.
    public var activity: String?
    public var resultText: String?
    public var resultBranchFacts: FleetBranchFacts?
    /// The snapshot that went with the work (`FleetSnapshotHeader`): bytes to send, bytes sent so far, the files it names, whether it
    /// was above the warning size, and how long the file part took on the target (create received to a worktree that passed its digest).
    public var snapshotBytes: UInt64?
    public var snapshotProgress: UInt64?
    public var snapshotFiles: Int?
    public var sendWarning: Bool
    public var fileMillis: Int?
    /// Epoch milliseconds.
    public var createdAt: Double
    public var updatedAt: Double

    public init(id: UUID = UUID(), kind: Kind = .agentDispatch, parentAgentID: AgentID? = nil, parentHostID: UUID, parentHostName: String,
                parentTitle: String = "", targetHostID: UUID? = nil, targetHostName: String? = nil, requestedHost: String? = nil,
                state: FleetDispatchState = .placing, failure: String? = nil, failureDetail: String? = nil, title: String, task: String,
                repoKey: String, commitSHA: String? = nil, subdir: String? = nil, branch: String? = nil, model: String? = nil,
                thinking: String? = nil, reasonCodes: [FleetPlacementReason] = [], remoteAgentID: AgentID? = nil, activity: String? = nil,
                resultText: String? = nil, resultBranchFacts: FleetBranchFacts? = nil, snapshotBytes: UInt64? = nil, snapshotProgress: UInt64? = nil,
                snapshotFiles: Int? = nil, sendWarning: Bool = false, fileMillis: Int? = nil, createdAt: Double, updatedAt: Double? = nil) {
        self.id = id
        self.kind = kind
        self.parentAgentID = parentAgentID
        self.parentHostID = parentHostID
        self.parentHostName = parentHostName
        self.parentTitle = parentTitle
        self.targetHostID = targetHostID
        self.targetHostName = targetHostName
        self.requestedHost = requestedHost
        self.state = state
        self.failure = failure
        self.failureDetail = failureDetail
        self.title = title
        self.task = task
        self.repoKey = repoKey
        self.commitSHA = commitSHA
        self.subdir = subdir
        self.branch = branch
        self.model = model
        self.thinking = thinking
        self.reasonCodes = reasonCodes
        self.remoteAgentID = remoteAgentID
        self.activity = activity
        self.resultText = resultText
        self.resultBranchFacts = resultBranchFacts
        self.snapshotBytes = snapshotBytes
        self.snapshotProgress = snapshotProgress
        self.snapshotFiles = snapshotFiles
        self.sendWarning = sendWarning
        self.fileMillis = fileMillis
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, parentAgentID, parentHostID, parentHostName, parentTitle, targetHostID, targetHostName, requestedHost, state
        case failure, failureDetail, title, task, repoKey, commitSHA, subdir, branch, model, thinking, reasonCodes, remoteAgentID
        case activity, resultText, resultBranchFacts, createdAt, updatedAt
        case snapshotBytes, snapshotProgress, snapshotFiles, sendWarning, fileMillis
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .agentDispatch
        parentAgentID = try c.decodeIfPresent(AgentID.self, forKey: .parentAgentID)
        parentHostID = try c.decode(UUID.self, forKey: .parentHostID)
        parentHostName = try c.decodeIfPresent(String.self, forKey: .parentHostName) ?? ""
        parentTitle = try c.decodeIfPresent(String.self, forKey: .parentTitle) ?? ""
        targetHostID = try c.decodeIfPresent(UUID.self, forKey: .targetHostID)
        targetHostName = try c.decodeIfPresent(String.self, forKey: .targetHostName)
        requestedHost = try c.decodeIfPresent(String.self, forKey: .requestedHost)
        // A state this build doesn't know (a newer build's) reads as failed: nothing resumes it.
        state = (try? c.decodeIfPresent(FleetDispatchState.self, forKey: .state)) ?? .failed
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        failureDetail = try c.decodeIfPresent(String.self, forKey: .failureDetail)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
        repoKey = try c.decodeIfPresent(String.self, forKey: .repoKey) ?? ""
        commitSHA = try c.decodeIfPresent(String.self, forKey: .commitSHA)
        subdir = try c.decodeIfPresent(String.self, forKey: .subdir)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        reasonCodes = (try? c.decodeIfPresent([FleetPlacementReason].self, forKey: .reasonCodes)) ?? []
        remoteAgentID = try c.decodeIfPresent(AgentID.self, forKey: .remoteAgentID)
        activity = try c.decodeIfPresent(String.self, forKey: .activity)
        resultText = try c.decodeIfPresent(String.self, forKey: .resultText)
        resultBranchFacts = try c.decodeIfPresent(FleetBranchFacts.self, forKey: .resultBranchFacts)
        snapshotBytes = try c.decodeIfPresent(UInt64.self, forKey: .snapshotBytes)
        snapshotProgress = try c.decodeIfPresent(UInt64.self, forKey: .snapshotProgress)
        snapshotFiles = try c.decodeIfPresent(Int.self, forKey: .snapshotFiles)
        sendWarning = try c.decodeIfPresent(Bool.self, forKey: .sendWarning) ?? false
        fileMillis = try c.decodeIfPresent(Int.self, forKey: .fileMillis)
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? createdAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(parentAgentID, forKey: .parentAgentID)
        try c.encode(parentHostID, forKey: .parentHostID)
        try c.encode(parentHostName, forKey: .parentHostName)
        if !parentTitle.isEmpty { try c.encode(parentTitle, forKey: .parentTitle) }
        try c.encodeIfPresent(targetHostID, forKey: .targetHostID)
        try c.encodeIfPresent(targetHostName, forKey: .targetHostName)
        try c.encodeIfPresent(requestedHost, forKey: .requestedHost)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(failure, forKey: .failure)
        try c.encodeIfPresent(failureDetail, forKey: .failureDetail)
        try c.encode(title, forKey: .title)
        try c.encode(task, forKey: .task)
        try c.encode(repoKey, forKey: .repoKey)
        try c.encodeIfPresent(commitSHA, forKey: .commitSHA)
        try c.encodeIfPresent(subdir, forKey: .subdir)
        try c.encodeIfPresent(branch, forKey: .branch)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(thinking, forKey: .thinking)
        if !reasonCodes.isEmpty { try c.encode(reasonCodes, forKey: .reasonCodes) }
        try c.encodeIfPresent(remoteAgentID, forKey: .remoteAgentID)
        try c.encodeIfPresent(activity, forKey: .activity)
        try c.encodeIfPresent(resultText, forKey: .resultText)
        try c.encodeIfPresent(resultBranchFacts, forKey: .resultBranchFacts)
        try c.encodeIfPresent(snapshotBytes, forKey: .snapshotBytes)
        try c.encodeIfPresent(snapshotProgress, forKey: .snapshotProgress)
        try c.encodeIfPresent(snapshotFiles, forKey: .snapshotFiles)
        if sendWarning { try c.encode(sendWarning, forKey: .sendWarning) }
        try c.encodeIfPresent(fileMillis, forKey: .fileMillis)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    /// The same record without the task and the result, for the Fleet page's log: the app draws
    /// state, places and reasons, never the text.
    public var summary: FleetDispatchRecord {
        var copy = self
        copy.task = ""
        copy.resultText = nil
        return copy
    }
}
