import Foundation

/// Session identity shared by snapshot pulls and lightweight fleet reads.
public struct NativeThreadSession: Hashable, Codable, Sendable {
    public var piSessionID: String
    public var generation: String

    public init(piSessionID: String, generation: String) {
        self.piSessionID = piSessionID
        self.generation = generation
    }

    public var key: String { piSessionID + ":" + generation }
}

/// Bounded Home metadata, never conversation pages. Derivation is shared with the local client.
public struct NativeFleetDigest: Hashable, Codable, Sendable {
    public struct Question: Hashable, Codable, Sendable {
        public var dialogID: String
        public var kind: NativeThreadDialog.Kind
        public var title: String
        public var message: String?
        public var options: [String]
        public var answerable: Bool

        public init(dialogID: String, kind: NativeThreadDialog.Kind, title: String, message: String? = nil,
                    options: [String] = [], answerable: Bool = true) {
            self.dialogID = dialogID
            self.kind = kind
            self.title = title
            self.message = message
            self.options = options
            self.answerable = answerable
        }
    }

    public var session: NativeThreadSession
    public var revision: UInt64
    public var running: Bool
    public var question: Question?
    public var liveSubagents: Bool
    public var subagentsWorking: Bool
    public var subagentsLive: Int
    public var subagentsAsking: Int
    public var lastTurnFailed: Bool
    public var activity: String?
    public var activitySince: Double?
    public var doing: String?
    public var lastActivity: Double?
    public var subagentsDone = 0
    public var queued = 0
    public var changes: FleetChanges?
    public var goal: String?
    public var result: String?

    public init(session: NativeThreadSession, revision: UInt64, running: Bool, question: Question? = nil,
                liveSubagents: Bool = false, subagentsWorking: Bool = false, subagentsLive: Int = 0, subagentsAsking: Int = 0,
                lastTurnFailed: Bool = false, activity: String? = nil, activitySince: Double? = nil, doing: String? = nil,
                lastActivity: Double? = nil, subagentsDone: Int = 0, queued: Int = 0, changes: FleetChanges? = nil, goal: String? = nil, result: String? = nil) {
        self.session = session
        self.revision = revision
        self.running = running
        self.question = question
        self.liveSubagents = liveSubagents
        self.subagentsWorking = subagentsWorking
        self.subagentsLive = subagentsLive
        self.subagentsAsking = subagentsAsking
        self.lastTurnFailed = lastTurnFailed
        self.activity = activity
        self.activitySince = activitySince
        self.doing = doing
        self.lastActivity = lastActivity
        self.subagentsDone = subagentsDone
        self.queued = queued
        self.changes = changes
        self.goal = goal
        self.result = result
    }
}

public struct FleetChanges: Hashable, Codable, Sendable {
    public var files: Int
    public var added: Int
    public var removed: Int

    public init(files: Int, added: Int, removed: Int) {
        self.files = files
        self.added = added
        self.removed = removed
    }
}

public enum NativeFleetDigestResult: Hashable, Codable, Sendable {
    case digest(NativeFleetDigest)
    case unchanged(piSessionID: String, generation: String, revision: UInt64)
}
