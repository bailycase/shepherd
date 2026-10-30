import Foundation
import ShepherdCore

// Missions over the remote protocol (`RemoteProtocol.missionsCapability`, docs/missions.md ›
// Remote). The host's own Missions page and the remote request call the same owner methods with
// the same guards: every action names the revision the client displayed, Spec Kit consent the
// fingerprint of the files it showed, and publication the exact review fingerprint it showed.
// A Mission never rides `stateChanged` (it can approach the frame cap): clients list summaries,
// read one record at a time, and pull again on a pushed `missionChanged` hint.

extension RemoteProtocol {
    /// Offered while the host's Missions experiment is on and its app drives missions, and only to
    /// a client that lists it in `hello`.
    public static let missionsCapability = "missions.v1"
}

/// A mission as a list knows it. `agentIDs` are every agent its receipts name (planner turns,
/// stations, Spec Kit planning threads): their threads belong to the mission, not the thread list.
public struct RemoteMissionSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: MissionID
    public var revision: UInt64
    public var title: String
    public var phase: MissionRun.Phase?
    public var agentIDs: [AgentID]

    public init(id: MissionID, revision: UInt64, title: String, phase: MissionRun.Phase?, agentIDs: [AgentID]) {
        self.id = id; self.revision = revision; self.title = title; self.phase = phase; self.agentIDs = agentIDs
    }

    public init(_ mission: Mission) {
        var agents: [AgentID] = []
        for agent in (mission.run?.attempts.compactMap(\.agentID) ?? []) + (mission.run?.specKit?.lanes.compactMap(\.plannerAgentID) ?? [])
        where !agents.contains(agent) { agents.append(agent) }
        self.init(id: mission.id, revision: mission.revision, title: mission.draft.title, phase: mission.run?.phase, agentIDs: agents)
    }
}

/// What New mission offers on the host: its models, the Git repositories among its spaces, and each
/// one's branches (full refs) with the one checked out.
public struct RemoteMissionStartOptions: Codable, Hashable, Sendable {
    public var models: [String]
    public var defaultModel: String?
    public var spaces: [Space]
    public var branchChoices: [SpaceID: [String]]
    public var defaultBranches: [SpaceID: String]

    public init(models: [String] = [], defaultModel: String? = nil, spaces: [Space] = [],
                branchChoices: [SpaceID: [String]] = [:], defaultBranches: [SpaceID: String] = [:]) {
        self.models = models; self.defaultModel = defaultModel; self.spaces = spaces
        self.branchChoices = branchChoices; self.defaultBranches = defaultBranches
    }
}

/// One owner action on a mission. Mirrors the Mac's Missions page; each runs the host's own method.
public enum RemoteMissionAction: Codable, Hashable, Sendable {
    case plan(feedback: String)
    case answer(text: String, choice: String?, replyTo: UUID?)
    /// Lets one repository load its own stock Spec Kit prompts, bound to `fingerprint` (the
    /// preflight's `consentFingerprint` the client showed). Refused when the files changed since.
    case specKitConsent(spaceID: SpaceID, fingerprint: String, continuePlanning: Bool)
    /// Stock `specify init` / `specify integration install pi` in that repository's mission worktree.
    case specKitSetUp(spaceID: SpaceID)
    case acceptConvergence(attemptID: UUID)
    /// Saves the brief edited from the action's revision.
    case save(draft: MissionDraft)
    case launch, pause, stop
    case changes(text: String)
    /// Approves publication of exactly the reviewed contents: `fingerprint` is the run's
    /// `reviewFingerprint` the client showed. Never defaulted on the host.
    case publish(fingerprint: String)
    case revalidate
    /// A new mission with the same destination; answered `created`.
    case runAgain
    /// Steers a working station's turn in its own session (waits, bounded, for the agent to read it).
    case steer(attemptID: UUID, text: String)
}

public enum RemoteMissionRequest: Codable, Hashable, Sendable {
    case list
    case get(missionID: MissionID)
    case startOptions
    case create(goal: String, spaceIDs: [SpaceID], model: String, branches: [SpaceID: String])
    /// `revision`: the mission as the client displayed it. A changed mission is refused (`stale_mission`).
    case action(missionID: MissionID, revision: UInt64, action: RemoteMissionAction)
    /// Reads every repository's actual changes again: files and fingerprints, no hunks.
    case review(missionID: MissionID)
    /// One file of the last review read, with its hunks.
    case reviewFile(missionID: MissionID, spaceID: SpaceID, path: String)
    /// Re-reads each repository's stock Spec Kit files (reads only) and tasks.md progress.
    case specKit(missionID: MissionID)

    /// How long a client waits: a steer waits for the agent to read it, a review reads git.
    public var timeout: TimeInterval {
        switch self {
        case .action(_, _, .steer): 330
        case .list, .get: 10
        default: 120
        }
    }
}

/// A file of a repository's review, without its hunks (`RemoteMissionRequest.reviewFile` reads those).
public struct RemoteMissionReviewFile: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var oldPath: String?
    public var isNew: Bool
    public var isDeleted: Bool
    public var isRenamed: Bool
    public var isBinary: Bool
    public var added: Int
    public var removed: Int
    public var id: String { path }

    public init(_ file: DiffFile) {
        path = file.displayPath; oldPath = file.isRenamed ? file.oldPath : nil
        isNew = file.isNew; isDeleted = file.isDeleted; isRenamed = file.isRenamed; isBinary = file.isBinary
        added = file.addedCount; removed = file.removedCount
    }
}

public struct RemoteMissionReview: Codable, Hashable, Sendable, Identifiable {
    public var spaceID: SpaceID
    public var name: String
    public var path: String
    public var branch: String
    public var head: String
    public var fingerprint: String
    public var files: [RemoteMissionReviewFile]
    public var id: SpaceID { spaceID }

    public init(spaceID: SpaceID, name: String, path: String, branch: String, head: String, fingerprint: String, files: [RemoteMissionReviewFile]) {
        self.spaceID = spaceID; self.name = name; self.path = path; self.branch = branch
        self.head = head; self.fingerprint = fingerprint; self.files = files
    }
}

/// Each repository's stock Spec Kit files as last read, its tasks.md progress, and whether setup runs now.
public struct RemoteMissionSpecKit: Codable, Hashable, Sendable {
    public var reports: [SpaceID: SpecKitPreflight]
    public var phases: [SpaceID: [SpecKitPhase]]
    public var settingUp: Bool

    public init(reports: [SpaceID: SpecKitPreflight] = [:], phases: [SpaceID: [SpecKitPhase]] = [:], settingUp: Bool = false) {
        self.reports = reports; self.phases = phases; self.settingUp = settingUp
    }
}

public enum RemoteMissionResult: Codable, Hashable, Sendable {
    case list([RemoteMissionSummary])
    case mission(Mission)
    case startOptions(RemoteMissionStartOptions)
    /// A mission `create` or `runAgain` made.
    case created(missionID: MissionID)
    /// An action finished; the mission as it is now (nil once it is gone).
    case done(mission: Mission?)
    case review([RemoteMissionReview])
    case reviewFile(DiffFile)
    case specKit(RemoteMissionSpecKit)
}
