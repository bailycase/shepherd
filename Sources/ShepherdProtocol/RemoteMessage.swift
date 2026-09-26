import Foundation
import ShepherdCore

/// Wire traffic between a remote Shepherd client (another Mac) and the TCP
/// listener a host's SessionServer optionally binds. Same NDJSON framing as
/// the extension socket. The transport security is the user's own VPN; the
/// token only keeps other devices on that network honest.
public enum RemoteProtocol {
    public static let uploadChunkBytes = 256 * 1024
    public static let uploadMaxBytes = 32 * 1024 * 1024
    public static let uploadCapability = "session.upload.v1"
    public static let creationOptionsCapability = "agent.creation.options.v1"
    public static let nativeThreadCapability = "native.thread.v1"
    /// v2: snapshot runtime/stats/commands, setModel/setThinking, send images.
    public static let nativeThreadV2Capability = "native.thread.v2"
    /// The host answers `NativeThreadCode.starting` while an agent's pi starts. Older hosts
    /// answered `native_unavailable` then; clients read that as starting (see RemoteHostClient).
    public static let nativeThreadStartingCapability = "native.thread.starting.v1"
    /// The host holds messages sent while pi works (`NativeThreadSnapshot.queue`) and serves
    /// `NativeThreadRequest.queue`. Older hosts send every message straight to pi.
    public static let nativeQueueCapability = "native.queue.v1"
    /// What this client tells a host in `hello`: it reads the host's queue and where each
    /// delivered message came from (`nativeQueueCapability`). An older client, which lists
    /// nothing, finds its own sends in the thread by their text, so a host delivers its queued
    /// messages one per turn, each as it was sent.
    /// It also decodes every thinking level pi has (`thinkingLevelsCapability`); a host sends an
    /// older client's state and creation options with each level clamped to `ThinkingLevel.legacy`.
    public static let clientCapabilities = [nativeQueueCapability, thinkingLevelsCapability]
    public static let version = 1
    /// A host's final reply to a `hello` whose token it refused; it closes the connection after.
    public static let unauthorizedCode = "unauthorized"
    /// A host's final reply to a `hello` with another `version`; the message ends with the
    /// host's own ("host speaks protocol 1").
    public static let versionMismatchCode = "protocol_version"
    public static let pasteCapability = "session.paste.v1"
    public static let paneControlCapability = "pane.control.v1"
    public static let agentActionsCapability = "agent.actions.v1"
    public static let worktreeActionsCapability = "agent.worktree.v1"
    public static let worktreeSetupCapability = "agent.worktree.setup.v1"
    public static let agentInspectionCapability = "agent.inspection.v1"
    /// The host answers `RemoteAgentQuery.terminals`: what each of an agent's terminal panes runs
    /// and how far its output has got. Older hosts leave a client with plain tabs.
    public static let terminalActivityCapability = "terminal.activity.v1"
    /// The host commits from review (`RemoteAgentQuery.commitInfo`, `.commitMessage`, `.commit`).
    /// Older hosts only take Commit as a turn the agent is asked to do.
    public static let reviewCommitCapability = "review.commit.v1"
    /// The host serves `RemoteRequest.automation`: on and off, Run now and Stop, the runs it
    /// kept, and create, edit and delete. Older hosts show automations read-only.
    public static let automationsCapability = "automations.v1"
    /// The host takes every level pi has (`ThinkingLevel`: minimal, xhigh, max too) in
    /// `createAgent`. An older host knows only `ThinkingLevel.legacy`, and refuses a request
    /// carrying another. A client lists it too: it decodes them in state and creation options.
    public static let thinkingLevelsCapability = "thinking.levels.v1"
    /// The host answers the Changes pane's queries (`RemoteAgentQuery.changes*`): scopes, the
    /// base picker, a file's hunks, a patch, and Undo and Redo of an agent's last turn; and its
    /// thread snapshots carry the turns it recorded (`NativeThreadSnapshot.turnChanges`). Older
    /// hosts review the working tree only (`RemoteAgentQuery.review`).
    public static let changesCapability = "changes.v1"
    /// The host serves `RemoteRequest.instructions`: its root instruction files for pi, their
    /// history, save and restore (Settings ▸ Instructions). Older hosts have none to show.
    public static let instructionsCapability = "instructions.v1"
    /// The host serves `RemoteRequest.suggestions`: Settings ▸ Experiments ▸ Suggested
    /// instructions (the experiment's settings, the lines waiting, and those added). Older hosts
    /// have no experiments.
    public static let suggestionsCapability = "suggestions.v1"
    /// The host serves `RemoteRequest.hostSettings`: what its Settings ▸ Agents, Worktrees and Pi
    /// set, its Shepherd and pi versions, and one change at a time. Older hosts show none.
    public static let hostSettingsCapability = "hostSettings.v1"
    /// The host serves `RemoteRequest.skills`: the agent skills in its ~/.agents/skills (on, off,
    /// how each is used, updates), installs from a repository or a copied folder, and removal
    /// with undo (Settings ▸ Skills). Older hosts have none to show.
    public static let skillsCapability = "skills.v1"
    public static let capabilities = [nativeThreadCapability, nativeThreadV2Capability, nativeThreadStartingCapability, nativeQueueCapability, pasteCapability, paneControlCapability, agentActionsCapability, agentInspectionCapability, worktreeActionsCapability, worktreeSetupCapability, uploadCapability, creationOptionsCapability, reviewCommitCapability, automationsCapability, terminalActivityCapability, thinkingLevelsCapability, changesCapability, instructionsCapability, suggestionsCapability, hostSettingsCapability, skillsCapability]

    public static func composedInput(text: String, submit: Bool) -> Data {
        var payload = Data("\u{1B}[200~".utf8)
        payload.append(Data(text.utf8))
        payload.append(Data("\u{1B}[201~".utf8))
        if submit { payload.append(0x0D) }
        return payload
    }
}

public struct RemoteAttachment: Codable, Hashable, Sendable {
    public let sessionID: SessionID
    public let cols: Int
    public let rows: Int
    public let viewportGeneration: UInt64

    public init(sessionID: SessionID, cols: Int, rows: Int, viewportGeneration: UInt64) {
        self.sessionID = sessionID
        self.cols = cols
        self.rows = rows
        self.viewportGeneration = viewportGeneration
    }
}

public enum RemoteUploadAction: Codable, Hashable, Sendable {
    case begin(sessionID: SessionID, name: String, size: Int)
    case chunk(uploadID: UUID, data: Data)
    case finish(uploadID: UUID)
    case cancel(uploadID: UUID)
}

public enum RemoteUploadResult: Codable, Hashable, Sendable {
    case ready(uploadID: UUID)
    case complete(path: String)
}

public struct RemoteCreationOptions: Codable, Hashable, Sendable {
    public var base: String
    public var note: String
    public var fetchFirst: Bool
    public var model: String?
    public var thinking: ThinkingLevel
    public init(base: String, note: String, fetchFirst: Bool, model: String?, thinking: ThinkingLevel) {
        self.base = base; self.note = note; self.fetchFirst = fetchFirst
        self.model = model; self.thinking = thinking
    }
}

/// A machine's pi models as a picker offers them (`listModels`): "provider/id" in catalog order,
/// the one pi starts a session with when none is passed, and the ones that take no thinking level.
public struct ModelListing: Hashable, Sendable {
    public var models: [String]
    public var defaultModel: String?
    /// nil when the host does not say (a Shepherd before this field): every model then keeps the
    /// thinking control, as it did.
    public var withoutThinking: [String]?
    /// The levels a model takes where pi's configuration says (a models.json
    /// `thinkingLevelMap`), as pi spells them. A reasoning model not listed takes the standard
    /// set (`ThinkingLevel.supported`); nil from a host that does not say.
    public var thinkingLevels: [String: [String]]?

    public init(models: [String], defaultModel: String?, withoutThinking: [String]? = nil, thinkingLevels: [String: [String]]? = nil) {
        self.models = models
        self.defaultModel = defaultModel
        self.withoutThinking = withoutThinking
        self.thinkingLevels = thinkingLevels
    }

    /// The levels to offer `model` (blank: the default) before its session starts: none without
    /// reasoning, the configured ones where the listing has them, else the standard set (Off to
    /// High, with Minimal).
    public func offeredThinkingLevels(_ model: String?) -> [ThinkingLevel] {
        guard takesThinking(model) else { return [] }
        let trimmed = model?.trimmingCharacters(in: .whitespaces) ?? ""
        if let id = trimmed.isEmpty ? defaultModel : trimmed, let levels = thinkingLevels?[id] {
            let known = levels.compactMap(ThinkingLevel.init(rawValue:))
            if !known.isEmpty { return known }
        }
        return ThinkingLevel.supported(reasoning: true)
    }

    /// Whether `model` (blank: the default) takes a thinking level. A model the listing does not
    /// say otherwise about does, so an unknown one keeps the control.
    public func takesThinking(_ model: String?) -> Bool {
        let trimmed = model?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let id = trimmed.isEmpty ? defaultModel : trimmed, let withoutThinking else { return true }
        return !withoutThinking.contains(id)
    }
}

public enum RemoteAgentAction: Codable, Hashable, Sendable {
    case rename(name: String)
    /// Retires the agent only. A worktree checkout and branch are kept.
    case deleteKeepingWorktree
    case reorder(target: AgentID)
}

public struct RemoteFinalizeOptions: Codable, Hashable, Sendable {
    public var base: String
    public var title: String
    public var body: String
    public var autoCommit: Bool
    public var deleteLocalBranch: Bool
    public var autoMergePR: Bool
    public var mergeMethod: String
    public init(base: String, title: String, body: String, autoCommit: Bool, deleteLocalBranch: Bool, autoMergePR: Bool, mergeMethod: String) {
        self.base = base; self.title = title; self.body = body
        self.autoCommit = autoCommit; self.deleteLocalBranch = deleteLocalBranch
        self.autoMergePR = autoMergePR; self.mergeMethod = mergeMethod
    }
}

public enum RemoteWorktreeSetupAction: Codable, Hashable, Sendable {
    case check
    case applyIdentity(name: String, email: String)
    case installCommandLineTools
    case enableDeleteBranchOnMerge
    case enableAutoMerge
    case loginShell
}

public enum RemoteWorktreeCheckState: Codable, Hashable, Sendable {
    case pending, checking
    case pass(String), fail(String)
    public var passed: Bool {
        if case .pass = self { return true }
        return false
    }
}

public enum RemoteWorktreeRepoSettingState: Codable, Hashable, Sendable {
    case unknown, checking, enabled, disabled
    case unavailable(String)
}

public struct RemoteWorktreeSetup: Codable, Hashable, Sendable {
    public var repoPath: String
    public var checks: [String: RemoteWorktreeCheckState]
    public var repoSettings: [String: RemoteWorktreeRepoSettingState]
    public init(repoPath: String, checks: [String: RemoteWorktreeCheckState], repoSettings: [String: RemoteWorktreeRepoSettingState]) {
        self.repoPath = repoPath; self.checks = checks; self.repoSettings = repoSettings
    }
}

public struct RemoteWorktreeInfo: Codable, Hashable, Sendable {
    public var path: String
    public var branch: String
    public var warning: String?
    public var defaults: RemoteFinalizeOptions
    public var fingerprint: String?
    public var generateDescription: Bool?
    public init(path: String, branch: String, warning: String?, defaults: RemoteFinalizeOptions, generateDescription: Bool? = nil, fingerprint: String? = nil) {
        self.path = path; self.branch = branch; self.warning = warning; self.defaults = defaults
        self.generateDescription = generateDescription
        self.fingerprint = fingerprint
    }
}

public struct RemoteWorktreeOperation: Codable, Hashable, Sendable {
    public var id: UUID
    public var finished: Bool
    public var error: String?
    public var progress: [String]
    public var prURL: String?
    public init(id: UUID, finished: Bool = false, error: String? = nil, progress: [String] = [], prURL: String? = nil) {
        self.id = id; self.finished = finished; self.error = error; self.progress = progress; self.prURL = prURL
    }
}

/// One terminal pane of an agent's layout, as its host sees it now (terminal tab states: a
/// command running, output since you last looked).
public struct RemoteTerminalActivity: Codable, Hashable, Sendable {
    public var paneID: PaneID
    public var sessionID: SessionID
    /// The program the terminal talks to: the shell at its prompt ("zsh"), else what runs.
    public var process: String?
    /// The running command line ("make dev"), while a command runs; nil at the prompt.
    public var command: String?
    /// Advances with every read of the session's output.
    public var outputSequence: UInt64
    /// Advances with output that is news, leaving out what the terminal prints to redraw itself
    /// right after a resize. Nil from hosts that predate it.
    public var newsSequence: UInt64?

    public init(paneID: PaneID, sessionID: SessionID, process: String?, command: String?, outputSequence: UInt64,
                newsSequence: UInt64? = nil) {
        self.paneID = paneID
        self.sessionID = sessionID
        self.process = process
        self.command = command
        self.outputSequence = outputSequence
        self.newsSequence = newsSequence
    }

    /// A command runs in it.
    public var isRunning: Bool { command != nil }

    /// What a client compares with the value it last showed for the tab's dot: the news
    /// sequence, or every read of output from an older host.
    public var news: UInt64 { newsSequence ?? outputSequence }
}

public enum RemoteInspectorPaneAction: Codable, Hashable, Sendable {
    case split(paneID: PaneID, axis: SplitAxis)
    case close(paneID: PaneID)
    case resize(split: PaneNode, ratio: Double)
}

public enum RemoteAgentQuery: Codable, Hashable, Sendable {
    case deleteKeepingWorktree
    case worktreeInfo
    case worktreeSetup(action: RemoteWorktreeSetupAction)
    case worktreeCommitCount(base: String)
    case worktreeDescription(base: String, title: String)
    case deleteWorktree(operationID: UUID, confirmedWarning: String?, fingerprint: String? = nil)
    case finalizeWorktree(operationID: UUID, options: RemoteFinalizeOptions)
    case worktreeStatus(operationID: UUID)
    case review(pullRequest: Bool)
    case reviewPane(paneID: PaneID, pullRequest: Bool? = nil)
    case finishReview(paneID: PaneID, text: String?)
    case children
    case inspectorPane(tabID: TabID, action: RemoteInspectorPaneAction)
    case search(query: String)
    /// The agent's terminal panes and what runs in each (`terminalActivityCapability`).
    case terminals
    /// What a commit from review would take (`reviewCommitCapability`).
    case commitInfo
    /// A commit message drafted from the diff of `paths`; slow, so asked for after the info.
    case commitMessage(paths: [String])
    /// Commit (then push, or open a pull request), as an operation polled with `worktreeStatus`.
    case commit(operationID: UUID, options: RemoteCommitOptions)
    /// The scope menu: every scope's diffstat, the branch's commits, the pull request
    /// (`changesCapability`, like every `changes*` query).
    case changesOverview
    /// A scope's files and counts, and the revision to fetch their hunks from.
    case changesList(scope: ChangesScope, options: ChangesOptions)
    /// One file's hunks from a list's revision; `oldPath` for a rename.
    case changesFile(revision: ChangesRevision, path: String, oldPath: String?, options: ChangesOptions)
    /// The base picker's branches.
    case changesBranches
    /// A revision's diff as a patch (Copy as patch).
    case changesPatch(revision: ChangesRevision, options: ChangesOptions)
    /// Undo a turn's edits in the agent's working tree; Redo puts them back.
    case changesUndoTurn(turnID: UUID)
    case changesRedoTurn(turnID: UUID)

    /// Answered by the host's server itself, without the GUI.
    public var isChanges: Bool {
        switch self {
        case .changesOverview, .changesList, .changesFile, .changesBranches, .changesPatch, .changesUndoTurn, .changesRedoTurn: true
        default: false
        }
    }
}

public enum RemoteAgentResult: Codable, Hashable, Sendable {
    case ok
    case worktreeInfo(RemoteWorktreeInfo)
    case worktreeSetup(RemoteWorktreeSetup)
    case worktreeCommitCount(Int?)
    case worktreeDescription(body: String)
    case worktreeOperation(RemoteWorktreeOperation)
    case review(files: Data, reference: String?)
    case children([ChildRun])
    case inspector(TabID)
    case inspectorFocus(PaneID)
    case search(snippet: String?)
    case terminals([RemoteTerminalActivity])
    case commitInfo(RemoteCommitInfo)
    /// `drafted` is false when the host fell back to a message written from the file list.
    case commitMessage(title: String, body: String, drafted: Bool)
    case changesOverview(ChangesOverview)
    case changesList(ChangesList)
    case changesFile(ChangesFileDiff)
    case changesBranches(ChangesBranches)
    /// `truncated`: the patch passed `ChangesLimits.remoteBytes` and ends early.
    case changesPatch(text: String, truncated: Bool)
    /// The turn after an Undo or a Redo.
    case changesTurn(ChangesTurn)
}

/// Client → host. The first message on a connection must be a successful
/// `hello`; anything else closes the connection.
public enum RemoteRequest: Codable, Hashable, Sendable {
    case nativeThread(id: Int, agentID: AgentID, request: NativeThreadRequest)
    /// Authenticate with the host's shared token (`remote-token` in its
    /// support directory). `capabilities` says what the client understands
    /// (`RemoteProtocol.clientCapabilities`); older clients send none.
    case hello(id: Int, token: String, clientName: String, protocolVersion: Int, capabilities: [String]? = nil)
    /// Full state snapshot.
    case stateFetch(id: Int)
    /// Attach to a session: the host resizes the PTY to the client's grid,
    /// snapshots the screen atomically, replies `attached`, and streams the
    /// replay + live output as `output` frames on the same ordered stream.
    case attach(id: Int, sessionID: SessionID, cols: Int, rows: Int, viewportGeneration: UInt64)
    /// Stop streaming a session's output to this client.
    case detach(sessionID: SessionID)
    /// Keystrokes for a session's PTY. Fire-and-forget, like the local path.
    case input(sessionID: SessionID, data: Data)
    /// The client's settled grid (debounced client-side, never per drag
    /// frame). The host records it as this client's viewport report and
    /// applies the smallest grid across all viewers (tmux semantics).
    case resize(sessionID: SessionID, cols: Int, rows: Int, viewportGeneration: UInt64)
    /// A composed block for a session: delivered as one bracketed paste so
    /// multi-line text is inserted literally, then an optional Return. The
    /// composer's transport — the raw `input` path would submit each line of
    /// a multi-line prompt separately. Acked so the client can keep the text
    /// on failure.
    case paste(id: Int, sessionID: SessionID, text: String, submit: Bool)
    case openPane(id: Int, agentID: AgentID, axis: SplitAxis, relativeTo: PaneID)
    case closePane(id: Int, agentID: AgentID, paneID: PaneID)
    case resizePaneSplit(id: Int, agentID: AgentID, split: PaneNode, ratio: Double)
    /// List a directory on the host (for the remote cwd/space pickers).
    /// Empty path means the host user's home directory.
    case listDir(id: Int, path: String)
    /// The host's pi model ids and default (for the remote model picker).
    case listModels(id: Int)
    /// Create a space from a directory that exists on the host.
    case addSpace(id: Int, path: String)
    /// Create an agent on the host: the host GUI runs its normal creation
    /// flow (spawn pi, seed the session file, bind the pane) and the new
    /// agent arrives at every client via the state push.
    case createAgent(
        id: Int,
        spaceID: SpaceID,
        cwd: String?,
        model: String?,
        thinking: ThinkingLevel?,
        initialPrompt: String?,
        worktreeBranch: String? = nil,
        worktreeBase: String? = nil,
        worktreeFetchFirst: Bool? = nil
    )

    case upload(id: Int, action: RemoteUploadAction)
    case creationOptions(id: Int, spaceID: SpaceID, cwd: String?, fetchFirst: Bool?)
    case agentQuery(id: Int, agentID: AgentID, query: RemoteAgentQuery)
    case agentAction(id: Int, agentID: AgentID, action: RemoteAgentAction)
    /// Manage one automation (`RemoteProtocol.automationsCapability`). A `create` names the new
    /// automation's id.
    case automation(id: Int, automationID: AutomationID, request: RemoteAutomationRequest)
    /// Read or save the host's root instructions (`RemoteProtocol.instructionsCapability`).
    case instructions(id: Int, request: RemoteInstructionsRequest)
    /// Read or act on the host's suggested instructions (`RemoteProtocol.suggestionsCapability`).
    case suggestions(id: Int, request: RemoteSuggestionsRequest)
    /// Read or change the host's settings (`RemoteProtocol.hostSettingsCapability`).
    case hostSettings(id: Int, request: RemoteHostSettingsRequest)
    /// Read or change the host's agent skills (`RemoteProtocol.skillsCapability`).
    case skills(id: Int, request: RemoteSkillsRequest)

    private enum CodingKeys: String, CodingKey {
        case request
        case type, id, token, clientName, protocolVersion, capabilities
        case sessionID, cols, rows, data, viewportGeneration
        case path, spaceID, cwd, model, thinking, initialPrompt, worktreeBranch
        case text, submit, agentID, paneID, axis, relativeTo, split, ratio, action, query, fetchFirst, worktreeBase, worktreeFetchFirst
        case automationID
    }

    private enum Kind: String, Codable {
        case nativeThread
        case hello, stateFetch, attach, detach, input, resize, paste
        case openPane, closePane, resizePaneSplit
        case listDir, listModels, addSpace, createAgent, agentAction, agentQuery, upload, creationOptions
        case automation
        case instructions, suggestions, hostSettings, skills
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .nativeThread:
            self = .nativeThread(id: try c.decode(Int.self, forKey: .id), agentID: try c.decode(AgentID.self, forKey: .agentID), request: try c.decode(NativeThreadRequest.self, forKey: .request))
        case .automation:
            self = .automation(id: try c.decode(Int.self, forKey: .id),
                               automationID: try c.decode(AutomationID.self, forKey: .automationID),
                               request: try c.decode(RemoteAutomationRequest.self, forKey: .request))
        case .instructions:
            self = .instructions(id: try c.decode(Int.self, forKey: .id),
                                 request: try c.decode(RemoteInstructionsRequest.self, forKey: .request))
        case .suggestions:
            self = .suggestions(id: try c.decode(Int.self, forKey: .id),
                                request: try c.decode(RemoteSuggestionsRequest.self, forKey: .request))
        case .hostSettings:
            self = .hostSettings(id: try c.decode(Int.self, forKey: .id),
                                 request: try c.decode(RemoteHostSettingsRequest.self, forKey: .request))
        case .skills:
            self = .skills(id: try c.decode(Int.self, forKey: .id),
                           request: try c.decode(RemoteSkillsRequest.self, forKey: .request))
        case .hello:
            self = .hello(
                id: try c.decode(Int.self, forKey: .id),
                token: try c.decode(String.self, forKey: .token),
                clientName: try c.decode(String.self, forKey: .clientName),
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                capabilities: try c.decodeIfPresent([String].self, forKey: .capabilities)
            )
        case .upload:
            self = .upload(id: try c.decode(Int.self, forKey: .id), action: try c.decode(RemoteUploadAction.self, forKey: .action))
        case .creationOptions:
            self = .creationOptions(id: try c.decode(Int.self, forKey: .id), spaceID: try c.decode(SpaceID.self, forKey: .spaceID), cwd: try c.decodeIfPresent(String.self, forKey: .cwd), fetchFirst: try c.decodeIfPresent(Bool.self, forKey: .fetchFirst))
        case .agentQuery:
            self = .agentQuery(id: try c.decode(Int.self, forKey: .id),
                               agentID: try c.decode(AgentID.self, forKey: .agentID),
                               query: try c.decode(RemoteAgentQuery.self, forKey: .query))
        case .agentAction:
            self = .agentAction(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                action: try c.decode(RemoteAgentAction.self, forKey: .action)
            )
        case .stateFetch:
            self = .stateFetch(id: try c.decode(Int.self, forKey: .id))
        case .attach:
            self = .attach(
                id: try c.decode(Int.self, forKey: .id),
                sessionID: try c.decode(SessionID.self, forKey: .sessionID),
                cols: try c.decode(Int.self, forKey: .cols),
                rows: try c.decode(Int.self, forKey: .rows),
                viewportGeneration: try c.decodeIfPresent(UInt64.self, forKey: .viewportGeneration) ?? 0
            )
        case .detach:
            self = .detach(sessionID: try c.decode(SessionID.self, forKey: .sessionID))
        case .input:
            self = .input(
                sessionID: try c.decode(SessionID.self, forKey: .sessionID),
                data: try c.decode(Data.self, forKey: .data)
            )
        case .resize:
            self = .resize(
                sessionID: try c.decode(SessionID.self, forKey: .sessionID),
                cols: try c.decode(Int.self, forKey: .cols),
                rows: try c.decode(Int.self, forKey: .rows),
                viewportGeneration: try c.decodeIfPresent(UInt64.self, forKey: .viewportGeneration) ?? 0
            )
        case .paste:
            self = .paste(
                id: try c.decode(Int.self, forKey: .id),
                sessionID: try c.decode(SessionID.self, forKey: .sessionID),
                text: try c.decode(String.self, forKey: .text),
                submit: try c.decodeIfPresent(Bool.self, forKey: .submit) ?? true
            )
        case .openPane:
            self = .openPane(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                axis: try c.decode(SplitAxis.self, forKey: .axis),
                relativeTo: try c.decode(PaneID.self, forKey: .relativeTo)
            )
        case .closePane:
            self = .closePane(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                paneID: try c.decode(PaneID.self, forKey: .paneID)
            )
        case .resizePaneSplit:
            self = .resizePaneSplit(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                split: try c.decode(PaneNode.self, forKey: .split),
                ratio: try c.decode(Double.self, forKey: .ratio)
            )
        case .listDir:
            self = .listDir(
                id: try c.decode(Int.self, forKey: .id),
                path: try c.decode(String.self, forKey: .path)
            )
        case .listModels:
            self = .listModels(id: try c.decode(Int.self, forKey: .id))
        case .addSpace:
            self = .addSpace(
                id: try c.decode(Int.self, forKey: .id),
                path: try c.decode(String.self, forKey: .path)
            )
        case .createAgent:
            self = .createAgent(
                id: try c.decode(Int.self, forKey: .id),
                spaceID: try c.decode(SpaceID.self, forKey: .spaceID),
                cwd: try c.decodeIfPresent(String.self, forKey: .cwd),
                model: try c.decodeIfPresent(String.self, forKey: .model),
                // A level this host does not know reads as its default (a newer client's).
                thinking: (try? c.decodeIfPresent(ThinkingLevel.self, forKey: .thinking)) ?? nil,
                initialPrompt: try c.decodeIfPresent(String.self, forKey: .initialPrompt),
                worktreeBranch: try c.decodeIfPresent(String.self, forKey: .worktreeBranch),
                worktreeBase: try c.decodeIfPresent(String.self, forKey: .worktreeBase),
                worktreeFetchFirst: try c.decodeIfPresent(Bool.self, forKey: .worktreeFetchFirst)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .nativeThread(let id, let agentID, let request):
            try c.encode(Kind.nativeThread, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(request, forKey: .request)
        case .hello(let id, let token, let clientName, let protocolVersion, let capabilities):
            try c.encode(Kind.hello, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(token, forKey: .token)
            try c.encode(clientName, forKey: .clientName)
            try c.encode(protocolVersion, forKey: .protocolVersion)
            try c.encodeIfPresent(capabilities, forKey: .capabilities)
        case .upload(let id, let action):
            try c.encode(Kind.upload, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(action, forKey: .action)
        case .creationOptions(let id, let spaceID, let cwd, let fetchFirst):
            try c.encode(Kind.creationOptions, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(spaceID, forKey: .spaceID)
            try c.encodeIfPresent(cwd, forKey: .cwd)
            try c.encodeIfPresent(fetchFirst, forKey: .fetchFirst)
        case .agentQuery(let id, let agentID, let query):
            try c.encode(Kind.agentQuery, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(query, forKey: .query)
        case .agentAction(let id, let agentID, let action):
            try c.encode(Kind.agentAction, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(action, forKey: .action)
        case .automation(let id, let automationID, let request):
            try c.encode(Kind.automation, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(automationID, forKey: .automationID)
            try c.encode(request, forKey: .request)
        case .instructions(let id, let request):
            try c.encode(Kind.instructions, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .suggestions(let id, let request):
            try c.encode(Kind.suggestions, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .hostSettings(let id, let request):
            try c.encode(Kind.hostSettings, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .skills(let id, let request):
            try c.encode(Kind.skills, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .stateFetch(let id):
            try c.encode(Kind.stateFetch, forKey: .type)
            try c.encode(id, forKey: .id)
        case .attach(let id, let sessionID, let cols, let rows, let viewportGeneration):
            try c.encode(Kind.attach, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(sessionID, forKey: .sessionID)
            try c.encode(cols, forKey: .cols)
            try c.encode(rows, forKey: .rows)
            try c.encode(viewportGeneration, forKey: .viewportGeneration)
        case .detach(let sessionID):
            try c.encode(Kind.detach, forKey: .type)
            try c.encode(sessionID, forKey: .sessionID)
        case .input(let sessionID, let data):
            try c.encode(Kind.input, forKey: .type)
            try c.encode(sessionID, forKey: .sessionID)
            try c.encode(data, forKey: .data)
        case .resize(let sessionID, let cols, let rows, let viewportGeneration):
            try c.encode(Kind.resize, forKey: .type)
            try c.encode(sessionID, forKey: .sessionID)
            try c.encode(cols, forKey: .cols)
            try c.encode(rows, forKey: .rows)
            try c.encode(viewportGeneration, forKey: .viewportGeneration)
        case .paste(let id, let sessionID, let text, let submit):
            try c.encode(Kind.paste, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(sessionID, forKey: .sessionID)
            try c.encode(text, forKey: .text)
            try c.encode(submit, forKey: .submit)
        case .openPane(let id, let agentID, let axis, let relativeTo):
            try c.encode(Kind.openPane, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(axis, forKey: .axis)
            try c.encode(relativeTo, forKey: .relativeTo)
        case .closePane(let id, let agentID, let paneID):
            try c.encode(Kind.closePane, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(paneID, forKey: .paneID)
        case .resizePaneSplit(let id, let agentID, let split, let ratio):
            try c.encode(Kind.resizePaneSplit, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(split, forKey: .split)
            try c.encode(ratio, forKey: .ratio)
        case .listDir(let id, let path):
            try c.encode(Kind.listDir, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(path, forKey: .path)
        case .listModels(let id):
            try c.encode(Kind.listModels, forKey: .type)
            try c.encode(id, forKey: .id)
        case .addSpace(let id, let path):
            try c.encode(Kind.addSpace, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(path, forKey: .path)
        case .createAgent(let id, let spaceID, let cwd, let model, let thinking, let initialPrompt, let worktreeBranch, let worktreeBase, let worktreeFetchFirst):
            try c.encode(Kind.createAgent, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(spaceID, forKey: .spaceID)
            try c.encodeIfPresent(cwd, forKey: .cwd)
            try c.encodeIfPresent(model, forKey: .model)
            try c.encodeIfPresent(thinking, forKey: .thinking)
            try c.encodeIfPresent(initialPrompt, forKey: .initialPrompt)
            try c.encodeIfPresent(worktreeBranch, forKey: .worktreeBranch)
            try c.encodeIfPresent(worktreeBase, forKey: .worktreeBase)
            try c.encodeIfPresent(worktreeFetchFirst, forKey: .worktreeFetchFirst)
        }
    }
}

/// Host → client. Replies correlate by request `id`; `stateChanged` is an
/// unsolicited push after every host-side mutation.
public enum RemoteReply: Codable, Hashable, Sendable {
    case nativeThread(id: Int, result: NativeThreadResult)
    case uploadResult(id: Int, result: RemoteUploadResult)
    case creationOptions(id: Int, options: RemoteCreationOptions)
    case helloOk(id: Int, protocolVersion: Int, capabilities: [String])
    /// Generic success for acked requests with no payload (paste).
    case agentResult(id: Int, result: RemoteAgentResult)
    case ok(id: Int)
    case paneOpened(id: Int, paneID: PaneID)
    case error(id: Int, code: String, message: String)
    case state(id: Int, state: ShepherdState)
    case stateChanged(state: ShepherdState)
    /// Attach accepted. The screen replay follows as `output` frames on this
    /// same ordered stream (chunked to stay under the payload limit), then
    /// live output continues seamlessly — the client just feeds bytes in
    /// arrival order.
    case attached(id: Int, attachment: RemoteAttachment)
    /// Raw PTY output for a session this client is attached to.
    case output(sessionID: SessionID, data: Data)
    /// The session's child process exited.
    case sessionExited(sessionID: SessionID, code: Int32?)
    /// Subdirectories of a host directory, for the remote pickers.
    case dirListing(id: Int, path: String, parent: String?, dirs: [String])
    /// The host's pi models as "provider/id" (may be empty), its configured default, and the ones
    /// that take no thinking level (absent from a host that does not say; see `ModelListing`).
    /// `thinkingLevels`: the configured levels of the models that have them (`ModelListing`).
    case models(id: Int, models: [String], defaultModel: String?, withoutThinking: [String]? = nil, thinkingLevels: [String: [String]]? = nil)
    /// Space created on the host (the state push carries the full snapshot).
    case spaceAdded(id: Int, spaceID: SpaceID)
    /// Agent created and its pi process spawned on the host.
    case agentCreated(id: Int, agentID: AgentID)
    /// An automation request's answer (`RemoteRequest.automation`).
    case automationResult(id: Int, result: RemoteAutomationResult)
    /// The host's root instructions after an instructions request (`RemoteRequest.instructions`).
    case instructions(id: Int, snapshot: InstructionsSnapshot)
    /// The host's suggested instructions after a suggestions request (`RemoteRequest.suggestions`).
    case suggestions(id: Int, snapshot: SuggestionsSnapshot)
    /// The host's settings after a settings request (`RemoteRequest.hostSettings`).
    case hostSettings(id: Int, settings: HostSettings)
    /// A skills request's answer (`RemoteRequest.skills`).
    case skills(id: Int, result: RemoteSkillsResult)

    private enum CodingKeys: String, CodingKey {
        case result
        case type, id, protocolVersion, capabilities, code, message, state
        case sessionID, data, exitCode, spaceID, agentID, paneID
        case path, parent, dirs, models, defaultModel, withoutThinking, thinkingLevels, attachment, options
        case snapshot, settings
    }

    private enum Kind: String, Codable {
        case nativeThread
        case agentResult, helloOk, ok, paneOpened, error, state, stateChanged, attached, output, sessionExited
        case dirListing, models, spaceAdded, agentCreated, uploadResult, creationOptions
        case automationResult
        case instructions, suggestions, hostSettings, skills
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .nativeThread:
            self = .nativeThread(id: try c.decode(Int.self, forKey: .id), result: try c.decode(NativeThreadResult.self, forKey: .result))
        case .helloOk:
            self = .helloOk(
                id: try c.decode(Int.self, forKey: .id),
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                capabilities: try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
            )
        case .uploadResult:
            self = .uploadResult(id: try c.decode(Int.self, forKey: .id), result: try c.decode(RemoteUploadResult.self, forKey: .result))
        case .creationOptions:
            self = .creationOptions(id: try c.decode(Int.self, forKey: .id), options: try c.decode(RemoteCreationOptions.self, forKey: .options))
        case .agentResult:
            self = .agentResult(id: try c.decode(Int.self, forKey: .id),
                                result: try c.decode(RemoteAgentResult.self, forKey: .result))
        case .automationResult:
            self = .automationResult(id: try c.decode(Int.self, forKey: .id),
                                     result: try c.decode(RemoteAutomationResult.self, forKey: .result))
        case .instructions:
            self = .instructions(id: try c.decode(Int.self, forKey: .id),
                                 snapshot: try c.decode(InstructionsSnapshot.self, forKey: .snapshot))
        case .suggestions:
            self = .suggestions(id: try c.decode(Int.self, forKey: .id),
                                snapshot: try c.decode(SuggestionsSnapshot.self, forKey: .snapshot))
        case .hostSettings:
            self = .hostSettings(id: try c.decode(Int.self, forKey: .id),
                                 settings: try c.decode(HostSettings.self, forKey: .settings))
        case .skills:
            self = .skills(id: try c.decode(Int.self, forKey: .id),
                           result: try c.decode(RemoteSkillsResult.self, forKey: .result))
        case .ok:
            self = .ok(id: try c.decode(Int.self, forKey: .id))
        case .paneOpened:
            self = .paneOpened(
                id: try c.decode(Int.self, forKey: .id),
                paneID: try c.decode(PaneID.self, forKey: .paneID)
            )
        case .error:
            self = .error(
                id: try c.decode(Int.self, forKey: .id),
                code: try c.decode(String.self, forKey: .code),
                message: try c.decode(String.self, forKey: .message)
            )
        case .state:
            self = .state(
                id: try c.decode(Int.self, forKey: .id),
                state: try c.decode(ShepherdState.self, forKey: .state)
            )
        case .stateChanged:
            self = .stateChanged(state: try c.decode(ShepherdState.self, forKey: .state))
        case .attached:
            if let attachment = try c.decodeIfPresent(RemoteAttachment.self, forKey: .attachment) {
                self = .attached(id: try c.decode(Int.self, forKey: .id), attachment: attachment)
            } else {
                self = .attached(
                    id: try c.decode(Int.self, forKey: .id),
                    attachment: RemoteAttachment(
                        sessionID: try c.decode(SessionID.self, forKey: .sessionID),
                        cols: 0,
                        rows: 0,
                        viewportGeneration: 0
                    )
                )
            }
        case .output:
            self = .output(
                sessionID: try c.decode(SessionID.self, forKey: .sessionID),
                data: try c.decode(Data.self, forKey: .data)
            )
        case .sessionExited:
            self = .sessionExited(
                sessionID: try c.decode(SessionID.self, forKey: .sessionID),
                code: try c.decodeIfPresent(Int32.self, forKey: .exitCode)
            )
        case .dirListing:
            self = .dirListing(
                id: try c.decode(Int.self, forKey: .id),
                path: try c.decode(String.self, forKey: .path),
                parent: try c.decodeIfPresent(String.self, forKey: .parent),
                dirs: try c.decode([String].self, forKey: .dirs)
            )
        case .models:
            self = .models(
                id: try c.decode(Int.self, forKey: .id),
                models: try c.decode([String].self, forKey: .models),
                defaultModel: try c.decodeIfPresent(String.self, forKey: .defaultModel),
                withoutThinking: try c.decodeIfPresent([String].self, forKey: .withoutThinking),
                thinkingLevels: try c.decodeIfPresent([String: [String]].self, forKey: .thinkingLevels)
            )
        case .spaceAdded:
            self = .spaceAdded(
                id: try c.decode(Int.self, forKey: .id),
                spaceID: try c.decode(SpaceID.self, forKey: .spaceID)
            )
        case .agentCreated:
            self = .agentCreated(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .nativeThread(let id, let result):
            try c.encode(Kind.nativeThread, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .helloOk(let id, let protocolVersion, let capabilities):
            try c.encode(Kind.helloOk, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(protocolVersion, forKey: .protocolVersion)
            try c.encode(capabilities, forKey: .capabilities)
        case .uploadResult(let id, let result):
            try c.encode(Kind.uploadResult, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .creationOptions(let id, let options):
            try c.encode(Kind.creationOptions, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(options, forKey: .options)
        case .agentResult(let id, let result):
            try c.encode(Kind.agentResult, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .automationResult(let id, let result):
            try c.encode(Kind.automationResult, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .instructions(let id, let snapshot):
            try c.encode(Kind.instructions, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(snapshot, forKey: .snapshot)
        case .suggestions(let id, let snapshot):
            try c.encode(Kind.suggestions, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(snapshot, forKey: .snapshot)
        case .hostSettings(let id, let settings):
            try c.encode(Kind.hostSettings, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(settings, forKey: .settings)
        case .skills(let id, let result):
            try c.encode(Kind.skills, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .ok(let id):
            try c.encode(Kind.ok, forKey: .type)
            try c.encode(id, forKey: .id)
        case .paneOpened(let id, let paneID):
            try c.encode(Kind.paneOpened, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(paneID, forKey: .paneID)
        case .error(let id, let code, let message):
            try c.encode(Kind.error, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
        case .state(let id, let state):
            try c.encode(Kind.state, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(state, forKey: .state)
        case .stateChanged(let state):
            try c.encode(Kind.stateChanged, forKey: .type)
            try c.encode(state, forKey: .state)
        case .attached(let id, let attachment):
            try c.encode(Kind.attached, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(attachment, forKey: .attachment)
            try c.encode(attachment.sessionID, forKey: .sessionID)
        case .output(let sessionID, let data):
            try c.encode(Kind.output, forKey: .type)
            try c.encode(sessionID, forKey: .sessionID)
            try c.encode(data, forKey: .data)
        case .sessionExited(let sessionID, let code):
            try c.encode(Kind.sessionExited, forKey: .type)
            try c.encode(sessionID, forKey: .sessionID)
            try c.encodeIfPresent(code, forKey: .exitCode)
        case .dirListing(let id, let path, let parent, let dirs):
            try c.encode(Kind.dirListing, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(parent, forKey: .parent)
            try c.encode(dirs, forKey: .dirs)
        case .models(let id, let models, let defaultModel, let withoutThinking, let thinkingLevels):
            try c.encode(Kind.models, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(models, forKey: .models)
            try c.encodeIfPresent(defaultModel, forKey: .defaultModel)
            try c.encodeIfPresent(withoutThinking, forKey: .withoutThinking)
            try c.encodeIfPresent(thinkingLevels, forKey: .thinkingLevels)
        case .spaceAdded(let id, let spaceID):
            try c.encode(Kind.spaceAdded, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(spaceID, forKey: .spaceID)
        case .agentCreated(let id, let agentID):
            try c.encode(Kind.agentCreated, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
        }
    }
}
