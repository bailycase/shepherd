import Foundation
import ShepherdCore

/// Wire traffic between a remote Shepherd client (another Mac) and the TCP
/// listener a host's SessionServer optionally binds. Same NDJSON framing as
/// the extension socket. The transport security is the user's own VPN; the
/// token only keeps other devices on that network honest.
public enum RemoteProtocol {
    public static let pushNotificationsCapability = "push.notifications.v1"
    public static let hostUpdateCapability = "host.update.v1"
    public static let uploadChunkBytes = 256 * 1024
    public static let uploadMaxBytes = 32 * 1024 * 1024
    public static let uploadCapability = "session.upload.v1"
    public static let creationOptionsCapability = "agent.creation.options.v1"
    /// The host answers `RemoteRequest.creationBranches`: a space's branches for a new
    /// worktree's base, before any agent exists. Older hosts leave the base a typed name.
    public static let creationBranchesCapability = "agent.creation.branches.v1"
    public static let nativeThreadCapability = "native.thread.v1"
    public static let nativeThreadRevisionsCapability = "native.revisions.v1"
    public static let nativeFleetDigestCapability = "native.fleetDigest.v1"
    /// v2: snapshot runtime/stats/commands, setModel/setThinking, send images.
    public static let nativeThreadV2Capability = "native.thread.v2"
    /// The host answers `NativeThreadCode.starting` while an agent's pi starts. Older hosts
    /// answered `native_unavailable` then; clients read that as starting (see RemoteHostClient).
    public static let nativeThreadStartingCapability = "native.thread.starting.v1"
    /// The host holds messages sent while pi works (`NativeThreadSnapshot.queue`) and serves
    /// `NativeThreadRequest.queue`. Older hosts send every message straight to pi.
    public static let nativeQueueCapability = "native.queue.v1"
    /// Partial startup snapshots expose questions without replacing history or releasing sends.
    public static let nativeStartupDialogsCapability = "native.startup-dialogs.v1"
    /// A client that lists it is answered a `NativeThreadRequest.snapshot` for an agent whose pi is
    /// not running from pi's saved session file (`NativeThreadSnapshot.preview`), without starting
    /// pi; any other request starts it as before. A client that does not list it has every
    /// request start pi, as older hosts did.
    public static let nativeThreadPreviewCapability = "native.preview.v1"
    /// What this client tells a host in `hello`: it reads the host's queue and where each
    /// delivered message came from (`nativeQueueCapability`). An older client, which lists
    /// nothing, finds its own sends in the thread by their text, so a host delivers its queued
    /// messages one per turn, each as it was sent.
    /// It also decodes every thinking level pi has (`thinkingLevelsCapability`); a host sends an
    /// older client's state and creation options with each level clamped to `ThinkingLevel.legacy`.
    /// And it reads a host's pushed design changes and capability changes (`designsCapability`),
    /// and its design systems changing (`designSystemsCapability`).
    /// And it reads the tunnel frames a host pushes back (`browserTunnelCapability`), which a host
    /// sends only for a client that lists it.
    /// And it runs an agent's browser tools on its own page when the host asks
    /// (`browserDriveCapability`), which a host asks only of a client that lists it.
    /// Space editing understands both legacy .pi and current .shepherd inventories (`projectsV2Capability`).
    /// And it browses a thread's folder (`filesCapability`), which a host offers only to a client that lists it.
    /// And it draws a background host's designs off screen when the host asks
    /// (`designRelayCapability`), which a host asks only of a local client that lists it. v2: the
    /// job travels as a file, since a design's files outgrow a frame.
    public static let designRelayCapability = "designRelay.v2"
    /// And it answers what a background host's agent asks of Shepherd's window (`AppRelayJob`),
    /// which a host asks only of a local client that lists it.
    public static let appRelayCapability = "appRelay.v1"
    public static let clientCapabilities = [nativeThreadRevisionsCapability, nativeFleetDigestCapability, filesCapability, missionsCapability, pushNotificationsCapability, checkpointRecoveryCapability, projectResultCapability, browserTabsCapability, projectPublicationsCapability, projectWorkerCapability, projectPlacementCapability, logicalProjectRuntimeCapability, projectExecutionCapability, nativeQueueCapability, nativeStartupDialogsCapability, thinkingLevelsCapability, designSystemsCapability, designsCapability, browserTunnelCapability, browserDriveCapability, projectsV2Capability, designRelayCapability, appRelayCapability, appsV2Capability]
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
    /// The host answers `RemoteAgentQuery.setWorktree`: the branch or base it records for a
    /// worktree thread, after the client changed the checkout itself (the branch card on This Mac).
    public static let worktreeRecordCapability = "agent.worktree.record.v1"
    /// The host answers `RemoteAgentQuery.moveToCheckout`: a thread re-pointed at another existing
    /// checkout of its repository (the branch picker's "move here"), its pi restarted there.
    public static let worktreeMoveCapability = "agent.worktree.move.v1"
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
    /// Automation triggers: schedules and GitHub events, settings on the draft, status, pause,
    /// pending events and unread runs (`RemoteAutomationRequest.status` and after).
    public static let automationTriggersCapability = "automationTriggers.v1"
    /// The host serves `RemoteRequest.forge`: GitHub issues and pull requests through its `gh`
    /// (lists, details, diffs, comments, reviews, merges, pins). Older hosts have no Issues & PRs.
    public static let forgeCapability = "issuesAndPRs.v1"
    /// Issues & PRs across every repository (`ForgeList.allRepos`), browsing with filters and
    /// pages (`browse`), a repository's people, new issues, editing labels, assignees and
    /// reviewers, and reviews with line comments (`postReview`). Older hosts serve one repository's
    /// sections only.
    public static let forgeBrowseCapability = "issuesAndPRs.browse.v1"
    /// The host takes every level pi has (`ThinkingLevel`: minimal, xhigh, max too) in
    /// `createAgent`. An older host knows only `ThinkingLevel.legacy`, and refuses a request
    /// carrying another. A client lists it too: it decodes them in state and creation options.
    public static let thinkingLevelsCapability = "thinking.levels.v1"
    /// The host answers the Changes pane's queries (`RemoteAgentQuery.changes*`): scopes, the
    /// base picker, a file's hunks, a patch, and Undo and Redo of an agent's last turn; and its
    /// thread snapshots carry the turns it recorded (`NativeThreadSnapshot.turnChanges`). Older
    /// hosts review the working tree only (`RemoteAgentQuery.review`).
    public static let changesCapability = "changes.v1"
    /// The host reports what fills each agent's context window (`NativeThreadSnapshot.context`,
    /// compactions in the thread) and serves `NativeThreadRequest.compact`. Older hosts send
    /// neither, and clients draw no context meter.
    public static let nativeContextCapability = "native.context.v1"
    /// The host takes the opening prompt's images with `createAgent` (`initialImages`) and sends
    /// them to pi with it. An older host would drop them without a word, so a client refuses to
    /// create an agent with images there.
    public static let createAgentImagesCapability = "agent.create.images.v1"
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
    /// The host's settings carry Settings ▸ Agents' speed for new threads and Compact at
    /// (`HostSettings.defaultServiceTier`, `compactAtPercent`), and it takes their changes. An older
    /// host omits the fields and refuses the changes as unknown.
    public static let hostSettingsAgentDefaultsCapability = "hostSettings.agentDefaults.v1"
    /// The host takes the text generation model's change (`HostSettingChange.textGenerationModel`),
    /// which replaced the session naming model's. An older host knows only the old change, so a
    /// client offers the picker only here.
    public static let hostSettingsTextGenerationModelCapability = "hostSettings.textGenerationModel.v1"
    /// The host takes the image reading model's change (`HostSettingChange.visionModel`) and
    /// its settings carry the pick. An older host refuses the change as unknown, so a client
    /// offers the picker only here.
    public static let hostSettingsVisionModelCapability = "hostSettings.visionModel.v1"
    /// The host answers `RemoteRequest.hostInventory`: its MCP servers and their status, its
    /// subagent profiles, and its providers' sign-in state, read-only (`RemoteHostInventoryRequest`).
    public static let hostInventoryCapability = "hostInventory.v1"
    /// The host's settings carry Subagent defaults, Deleting a worktree agent, Skills in the /
    /// menu, a repo's .mcp.json and the slash commands, and it takes their changes
    /// (`HostSettingChange.capability`). An older host omits them and refuses the changes.
    public static let hostSettingsV2Capability = "hostSettings.v2"
    /// The host's settings carry Close threads when their pull request merges and it takes its
    /// change (`HostSettingChange.closeOnMerge`). An older host omits it and refuses the change.
    public static let hostSettingsCloseOnMergeCapability = "hostSettings.closeOnMerge.v1"
    /// `HostSettings.backgroundService`: whether the Mac keeps agents running when Shepherd is
    /// quit. Older hosts omit it and clients show nothing.
    public static let hostSettingsBackgroundServiceCapability = "hostSettings.backgroundService.v1"
    /// The host serves `RemoteRequest.hostConfig`: MCP servers, subagent profiles and provider
    /// sign-ins changed from a client (`RemoteHostConfigRequest`). Older hosts show them read-only.
    public static let hostConfigCapability = "hostConfig.v1"
    /// The host reverts one file of a working-tree review (`RemoteAgentQuery.changesRevertFile`),
    /// fenced to the version the client displayed (`ChangesRevision`).
    public static let changesRevertCapability = "changes.revert.v1"
    /// The host reads a `changes*` query's `cwd`: the repository an agent's `review_diff` asked to
    /// review. Older hosts ignore it and answer for the agent's own folder.
    public static let changesCwdCapability = "changes.cwd.v1"
    /// Older hosts' project inventory uses native .pi configuration paths.
    public static let projectsCapability = "projects.v1"
    /// Host-owned project files use .shepherd; clients must acknowledge this format before access.
    public static let projectsV2Capability = "projects.v2"
    public static let projectDetailsCapability = "projects.details.v1"
    public static let projectMCPCapability = "projects.mcp.v1"
    /// No longer offered: spaces need no approval. Kept so older peers' checks still compile and decode.
    public static let projectTrustCapability = "projects.trust.v1"
    /// The host lists a space's resources, removes one, and copies skills into it from a repository.
    public static let projectResourcesCapability = "projects.resources.v1"
    /// The host records what a child space turns off of its parent's MCP servers and skills
    /// (`RemoteProjectsRequest.inheritance`) and reports it in the space's context.
    public static let projectInheritanceCapability = "projects.inheritance.v1"
    /// Child spaces inherit their parent's slash commands and extensions too, and the host records
    /// turning them off (`SpaceInheritanceExclusions.prompts`, `.extensions`).
    public static let projectInheritedResourcesCapability = "projects.inheritance.resources.v1"
    /// The host sets a space's parent space and name (`RemoteProjectsRequest.organize`).
    public static let projectParentCapability = "projects.parent.v1"
    /// The host serves `RemoteRequest.skills`: the agent skills its pi reads (on, off,
    /// how each is used, updates), installs from a repository or a copied folder, and removal
    /// with undo (Settings ▸ Skills). Older hosts have none to show.
    public static let skillsCapability = "skills.v1"
    /// A host's skills answer carries the skills its pi loads from outside its skills folder
    /// (`SkillsSnapshot.pi`), which Settings lists read-only: none from a host whose pi reads only
    /// its own home. Older hosts send none.
    public static let piSkillsCapability = "skills.pi.v1"
    /// The host serves `RemoteRequest.hooks`: Settings › Hooks on its files (the catalog, off
    /// switches, readers, add, edit, delete, and a test run there). Older hosts hide the page.
    public static let hooksCapability = "hooks.v1"
    /// The host serves `RemoteRequest.apps`: a space's apps, run and stopped there.
    public static let appsCapability = "apps.v1"
    /// The host serves `RemoteAppsRequest`'s This Mac apps with no space, `processes`, `restart`
    /// and `output`; a local client that lists it (in `clientCapabilities`) is pushed `appsChanged`.
    public static let appsV2Capability = "apps.v2"
    /// Offered only on the local socket (`host.sock`): the client is this Mac's own app, as a
    /// background host's client. Never in `capabilities`, which every client may be offered.
    public static let localCapability = "local.v1"
    /// Offered only on the local socket: the host takes `RemoteRequest.drain`, from an app newer
    /// than it. Older hosts leave it off and drain once they see the new bundle.
    public static let hostDrainCapability = "host.drain.v1"
    /// A client capability, from this Mac's own app only: it shows its background host's threads
    /// as its own and posts their turns' and questions' banners itself, so the host doesn't.
    public static let localThreadsCapability = "local.threads.v1"
    /// The host takes the terminal panel's actions on an agent's terminal panes
    /// (`RemoteAgentAction.renameTerminal`, `.killTerminalProcess`): Rename tab and Kill
    /// process. Older hosts leave them off. A host answers an older client's `typeInTerminal`
    /// (Run in terminal, since removed) with `unsupported`.
    public static let terminalControlCapability = "terminal.control.v1"
    public static let terminalStartCapability = "terminal.start.v1"
    /// `RemoteAgentAction.readCheckout`: the host reads a thread's checkout again.
    public static let checkoutReadCapability = "checkout.read.v1"
    /// `RemoteAgentQuery.pullRequest`: the host looks a thread's branch's pull request up again.
    public static let pullRequestLinkCapability = "pullrequest.link.v1"
    /// The host starts a thread's stopped pi again on request (`RemoteAgentAction.restartPi`).
    public static let agentRestartCapability = "agent.restart.v1"
    /// The host keeps which completion of each thread was opened (`Agent.seenCompletedAt`) and
    /// takes `RemoteAgentAction.markSeen`, so Done clears on every device at once.
    public static let completionSeenCapability = "agent.seen.v1"
    /// The host keeps which threads are muted (`Agent.pushMuted`) and takes
    /// `RemoteAgentAction.mutePushes`: a muted thread sends no push to any phone.
    public static let pushMuteCapability = "push.mute.v1"
    /// The host takes a send's `designContext` (what the sender's design screen showed) and hands
    /// it to pi fenced as data. An older host would drop it, so a client leaves it out there.
    public static let designContextCapability = "design.context.v1"
    /// Legacy retry routing remains advertised so old clients reach a refusal, not their
    /// send-again fallback. Safe recovery additionally requires checkpointRecoveryCapability.
    public static let nativeRetryCapability = "native.retry.v1"
    public static let checkpointRecoveryCapability = "native.checkpointRecovery.v1"
    /// The host interrupts a running turn for a message (`NativeThreadDelivery.interrupt`,
    /// `NativeQueueAction.interrupt`): it stops pi as Stop does and sends the message at once as
    /// the next turn. An older host has only steer, so a client steers there.
    public static let nativeInterruptCapability = "native.interrupt.v1"
    public static let nativeQueueSubagentCapability = "native.queueSubagent.v1"
    /// The host keeps each agent's service tier (Fast or Standard) and serves
    /// `NativeThreadRequest.setServiceTier`; its snapshots say the tier and the tiers the model
    /// offers (`NativeThreadSnapshot.serviceTier`, `serviceTiers`). An older host has neither, and
    /// a client draws no Speed control there.
    public static let nativeServiceTierCapability = "native.serviceTier.v1"
    /// The host serves the images pi saved in a thread (`NativeThreadRequest.image`) and names them in its snapshots
    /// (`NativeThreadBlock.imageID`). An older host sends only the "Image" chip, and a client draws that.
    public static let nativeImagesCapability = "native.images.v1"
    public static let nativeGoalCapability = "native.goal.v1"
    /// Live Settings ▸ Experiments ▸ Goals control on this host.
    public static let goalExperimentCapability = "experiments.goals.v1"
    public static let projectsExperimentCapability = "experiments.projects.v1"
    /// Settings ▸ Experiments ▸ Fleet switched from a client (`HostSettingChange.fleetEnabled`).
    public static let fleetExperimentCapability = "experiments.fleet.v1"
    /// The host speaks fleet: `fleetIdentify` and `fleetPair` before `hello`, and after it
    /// `fleetEstablish`, `fleetIntroduce` and `fleetRevoke` (`FleetWire.swift`), and its `helloOk`
    /// carries its `hostID`. Offered only while Fleet is on; the other fleet requests are the
    /// app's, on the local socket.
    public static let fleetCapability = "fleet.v1"
    /// Pressure and readiness: Macs in a fleet push `fleetPressure` and `fleetReadiness` to each
    /// other and answer `fleetPressureNow` (`FleetPressureWire.swift`). Offered while Fleet is on.
    public static let fleetPressureCapability = "fleet.pressure.v1"
    /// The host syncs settings and content with the Macs it is paired with (`FleetSyncWire.swift`):
    /// `fleetSync` after `hello` with a peer's token. Offered only while Fleet is on.
    public static let fleetSyncCapability = "fleet.sync.v1"
    /// The host takes client devices by code (`fleetPairDevice`) and offers a client on the shared token its own
    /// token (`fleetEnrollDevice`). Offered whenever the host runs, Fleet on or off; never to a device.
    public static let fleetDevicesCapability = "fleet.devices.v1"
    /// Capabilities a client device is never offered (`FleetAccess`): the ones for taking part in the
    /// fleet's store (`fleet.v1`, sync), and the one for enrolling (a device already has its token). Later fleet
    /// units (credentials, dispatch) add theirs here.
    public static let fleetMemberCapabilities: Set<String> = [fleetCapability, fleetSyncCapability, fleetDevicesCapability, fleetPressureCapability]
    /// Settings ▸ Experiments ▸ Design tool switched from a client (`HostSettingChange.designToolEnabled`).
    /// Offered while the tool is off too: it is not one of `designCapabilities`.
    public static let designToolExperimentCapability = "experiments.designTool.v1"
    /// Settings ▸ Experiments ▸ Missions switched from a client; off is refused while a mission is active.
    public static let missionsExperimentCapability = "experiments.missions.v1"
    /// The creation page may choose a tier before the opening prompt reaches pi.
    public static let createAgentServiceTierCapability = "agent.create.serviceTier.v1"
    public static let projectExecutionCapability = "logicalProjects.execution.v1"
    public static let logicalProjectRuntimeCapability = "logicalProjectRuntime.v1"
    public static let projectMessageImagesCapability = "logicalProjectRuntime.images.v1"
    /// The owner keeps a Project's conversation reasoning level (`LogicalProjectSettings.conversationThinking`). An older owner drops
    /// the field it does not know, so a client offers the Project's own reasoning choice only to an owner with this.
    public static let projectConversationThinkingCapability = "logicalProjects.conversationThinking.v1"
    public static let browserTabsCapability = "browser.tabs.v1"

    public static let moveThreadCapability = "agent.move.v1"
    /// The host lists and reads a thread's folder, read-only (`RemoteAgentQuery.files`, `.fileRead`; `ThreadFilesLimits`).
    /// Offered only to a client that lists it in `hello`; a client and an older host show Files as needing a newer host.
    public static let filesCapability = "files.v1"
    /// The host saves a file of a thread's folder (`RemoteAgentQuery.fileWrite`), only over the text the client
    /// edited from (`ThreadFileSaveResult.changed` otherwise). Served only to a client offered `filesCapability`.
    public static let filesWriteCapability = "files.write.v1"
    public static let capabilities = [nativeThreadRevisionsCapability, worktreeRecordCapability, worktreeMoveCapability, nativeFleetDigestCapability, filesCapability, filesWriteCapability, missionsCapability, missionsTrainCapability, pushNotificationsCapability, hostUpdateCapability, projectResultCapability, projectConversationThinkingCapability, moveThreadCapability, nativeQueueSubagentCapability, browserTabsCapability, projectPublicationsCapability, projectWorkerCapability, projectMessageImagesCapability, logicalProjectFilesCapability, projectPlacementCapability, projectExecutionCapability, logicalProjectRuntimeCapability, logicalProjectAutomationsCapability, logicalProjectsCapability, nativeThreadCapability, nativeThreadV2Capability, nativeThreadStartingCapability, nativeQueueCapability, nativeStartupDialogsCapability, nativeThreadPreviewCapability, pasteCapability, paneControlCapability, agentActionsCapability, agentInspectionCapability, worktreeActionsCapability, uploadCapability, creationOptionsCapability, creationBranchesCapability, reviewCommitCapability, automationsCapability, automationTriggersCapability, forgeCapability, forgeBrowseCapability, terminalActivityCapability, thinkingLevelsCapability, changesCapability, nativeContextCapability, instructionsCapability, suggestionsCapability, hostSettingsCapability, hostSettingsAgentDefaultsCapability, hostSettingsTextGenerationModelCapability, hostSettingsVisionModelCapability, hostInventoryCapability, changesRevertCapability, changesCwdCapability, projectsV2Capability, projectDetailsCapability, projectMCPCapability, projectResourcesCapability, projectInheritanceCapability, skillsCapability, piSkillsCapability, hooksCapability, createAgentImagesCapability, terminalControlCapability, terminalStartCapability, designContextCapability, designsCapability, designMarkupCapability, designAgentCapability, designLifecycleCapability, designSystemsCapability, designReferencesCapability, designImportCapability, designBoardsCapability, designThreadNotesCapability, designGitCapability, designDeleteCapability, nativeRetryCapability, checkpointRecoveryCapability, nativeInterruptCapability, browserTunnelCapability, browserDriveCapability, nativeServiceTierCapability, nativeImagesCapability, createAgentServiceTierCapability, nativeGoalCapability, goalExperimentCapability, projectsExperimentCapability, designToolExperimentCapability, missionsExperimentCapability, hostSettingsV2Capability, hostSettingsCloseOnMergeCapability, hostSettingsBackgroundServiceCapability, hostConfigCapability, appsCapability, appsV2Capability, agentRestartCapability, completionSeenCapability, projectInheritedResourcesCapability, projectParentCapability, pushMuteCapability, missionsRetryLaneCapability, checkoutReadCapability, pullRequestLinkCapability, fleetExperimentCapability, fleetCapability, fleetSyncCapability, fleetDevicesCapability, fleetPressureCapability]

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
    /// Nil from a host before creation could choose speed.
    public var serviceTier: ServiceTier?
    public init(base: String, note: String, fetchFirst: Bool, model: String?, thinking: ThinkingLevel, serviceTier: ServiceTier? = nil) {
        self.base = base; self.note = note; self.fetchFirst = fetchFirst
        self.model = model; self.thinking = thinking; self.serviceTier = serviceTier
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
    /// The host's offered tiers per model, using the running composer's support rules.
    public var serviceTiers: [String: [String]]?
    /// Context-window labels for picker rows, absent from older hosts.
    public var contexts: [String: String]?
    /// The models whose catalog input kinds lack images; nil when the host does not say, in
    /// which case every model is offered where an image-capable one is picked.
    public var withoutImages: [String]?

    public init(models: [String], defaultModel: String?, withoutThinking: [String]? = nil, thinkingLevels: [String: [String]]? = nil,
                serviceTiers: [String: [String]]? = nil, contexts: [String: String]? = nil, withoutImages: [String]? = nil) {
        self.models = models
        self.defaultModel = defaultModel
        self.withoutThinking = withoutThinking
        self.thinkingLevels = thinkingLevels
        self.serviceTiers = serviceTiers
        self.contexts = contexts
        self.withoutImages = withoutImages
    }

    /// The models an image reading pick may offer: all of them when the host does not say
    /// which take images, else the ones it does not list as text-only.
    public var imageCapableModels: [String] {
        guard let withoutImages else { return models }
        let blind = Set(withoutImages)
        return models.filter { !blind.contains($0) }
    }

    public func offeredServiceTiers(_ model: String?) -> [ServiceTier] {
        let trimmed = model?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let id = trimmed.isEmpty ? defaultModel : trimmed else { return [] }
        return (serviceTiers?[id] ?? []).compactMap(ServiceTier.init(rawValue:))
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
    case move(spaceID: SpaceID)
    /// Retires the agent only. A worktree checkout and branch are kept.
    case deleteKeepingWorktree
    case reorder(target: AgentID)
    /// Names a terminal tab (its first pane); nil goes back to naming it after what it runs
    /// (`terminalControlCapability`, like the one below).
    case renameTerminal(paneID: PaneID, title: String?)
    /// Kills the command running in a terminal pane (its foreground process group), never the
    /// shell at its prompt.
    case killTerminalProcess(paneID: PaneID)
    /// Explicit demand for one restored auxiliary terminal, including a stale persisted binding.
    case startTerminal(paneID: PaneID)
    /// Runs `command` in a new terminal pane of the agent's layout, in `cwd` (the thread's folder or
    /// one inside it): the Browser's "Start on demo-mac" (`browserTunnelCapability`). A host that
    /// does not know the action refuses the request, and one that lacks the capability would not
    /// know it, so a client checks first.
    case openTerminal(cwd: String, command: String)
    /// Starts the thread's stopped pi again, as its Can't start banner's Retry does; a pi that
    /// runs is left alone. `newConversation` starts without looking for the conversation it was
    /// resuming; `model` starts it on another model, once ("Use another model")
    /// (`agentRestartCapability`).
    case restartPi(newConversation: Bool, model: String? = nil)
    /// The person opened the thread's completion `upTo` (its `Agent.completedAt`): it leaves Done
    /// on every device. Never lowers what was seen (`completionSeenCapability`).
    case markSeen(upTo: Double)
    /// Mutes or unmutes the thread's pushes on its host, for every phone (`pushMuteCapability`).
    case mutePushes(Bool)
    /// Reads the thread's branch and changed files again, after a change no state carries (a
    /// file saved in the app) (`checkoutReadCapability`).
    case readCheckout

    /// The capability a host must advertise before the action is sent to it.
    public var capability: String {
        switch self {
        case .move: RemoteProtocol.moveThreadCapability
        case .rename, .deleteKeepingWorktree, .reorder: RemoteProtocol.agentActionsCapability
        case .renameTerminal, .killTerminalProcess: RemoteProtocol.terminalControlCapability
        case .startTerminal: RemoteProtocol.terminalStartCapability
        case .openTerminal: RemoteProtocol.browserTunnelCapability
        case .restartPi: RemoteProtocol.agentRestartCapability
        case .markSeen: RemoteProtocol.completionSeenCapability
        case .mutePushes: RemoteProtocol.pushMuteCapability
        case .readCheckout: RemoteProtocol.checkoutReadCapability
        }
    }
}

/// A new thread this Mac's own app starts on its background host (`RemoteRequest.startThread`),
/// with what `createAgent` doesn't carry: a fork's copied conversation, an existing checkout, a
/// standalone thread's own folder, its name and id.
public struct RemoteThreadStart: Codable, Hashable, Sendable {
    /// Nil: a standalone thread, in a folder of its own the host makes (needs `agentID`).
    public var spaceID: SpaceID?
    public var cwd: String?
    public var model: String?
    public var thinking: ThinkingLevel?
    public var serviceTier: ServiceTier?
    public var initialPrompt: String?
    public var initialImages: [NativeImage]?
    public var name: String?
    /// The pi session it resumes (a fork's copy, in the host's pi home).
    public var piSessionID: String?
    public var agentID: AgentID?
    /// A new worktree on this branch, or with `worktreePath` the existing checkout of it.
    public var worktreeBranch: String?
    public var worktreeBase: String?
    public var worktreePath: String?

    public init(spaceID: SpaceID?, cwd: String? = nil, model: String? = nil, thinking: ThinkingLevel? = nil, serviceTier: ServiceTier? = nil,
                initialPrompt: String? = nil, initialImages: [NativeImage]? = nil, name: String? = nil, piSessionID: String? = nil,
                agentID: AgentID? = nil, worktreeBranch: String? = nil, worktreeBase: String? = nil, worktreePath: String? = nil) {
        self.spaceID = spaceID; self.cwd = cwd; self.model = model; self.thinking = thinking; self.serviceTier = serviceTier
        self.initialPrompt = initialPrompt; self.initialImages = initialImages; self.name = name; self.piSessionID = piSessionID
        self.agentID = agentID; self.worktreeBranch = worktreeBranch; self.worktreeBase = worktreeBase; self.worktreePath = worktreePath
    }
}

/// What this Mac's own app does to a space of its background host (`RemoteRequest.spaceAction`),
/// the sidebar's project menu and the base picker.
public enum RemoteSpaceAction: Codable, Hashable, Sendable {
    case rename(name: String)
    /// The branch new worktrees start from; nil goes back to Settings ▸ Worktrees.
    case setWorktreeBase(base: String?)
    case setSidebarHidden(hidden: Bool)
    /// Before `target`, or last (nil).
    case move(before: SpaceID?)
    /// Stops its agents and forgets it; its folder stays.
    case delete
    /// Locate Folder…: points it, and everything recorded inside its old folder, at `path`. Its
    /// threads stop and their conversations move; the app starts them again (`restartPi`).
    case relocate(path: String)
}

/// What this Mac's own app asks of its background host's space registry (`RemoteRequest.projectRequest`),
/// as an agent's project tool does: Add space, Space settings, and a child space.
public enum RemoteProjectRequest: Codable, Hashable, Sendable {
    case register(path: String, name: String)
    case edit(spaceID: SpaceID, edit: ProjectEdit)
    case child(parentPath: String, path: String, name: String, create: Bool)
}

public struct RemoteWorktreeInfo: Codable, Hashable, Sendable {
    public var path: String
    public var branch: String
    public var warning: String?
    public var fingerprint: String?
    /// The removed Finalize form's defaults. Still sent, as placeholders, because clients from
    /// before its removal decode `worktreeInfo` with this key required.
    private var defaults = LegacyFinalizeDefaults()

    public init(path: String, branch: String, warning: String?, fingerprint: String? = nil) {
        self.path = path; self.branch = branch; self.warning = warning
        self.fingerprint = fingerprint
    }
}

/// The shape older clients require under `RemoteWorktreeInfo.defaults`; nothing reads it.
private struct LegacyFinalizeDefaults: Codable, Hashable, Sendable {
    var base = "", title = "", body = ""
    var autoCommit = false, deleteLocalBranch = false, autoMergePR = false
    var mergeMethod = "squash"
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
    case deleteWorktree(operationID: UUID, confirmedWarning: String?, fingerprint: String? = nil)
    case worktreeStatus(operationID: UUID)
    /// Record a worktree thread's branch or base (nil keeps it); answered `.ok` (`worktreeRecordCapability`).
    case setWorktree(branch: String?, base: String?)
    /// Re-point the thread at `path`, another checkout of its repository that has `branch`
    /// checked out, and restart its pi there; no git command runs. Answered `.ok`
    /// (`worktreeMoveCapability`); refused while the thread runs or asks.
    case moveToCheckout(path: String, branch: String)
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
    /// (`changesCapability`, like every `changes*` query). A read's `cwd` is the repository the
    /// agent's `review_diff` asked for (`changesCwdCapability`); nil, the agent's own folder.
    case changesOverview(cwd: String? = nil)
    /// A scope's files and counts, and the revision to fetch their hunks from.
    case changesList(scope: ChangesScope, options: ChangesOptions, cwd: String? = nil)
    /// One file's hunks from a list's revision; `oldPath` for a rename.
    case changesFile(revision: ChangesRevision, path: String, oldPath: String?, options: ChangesOptions, cwd: String? = nil)
    /// The base picker's branches.
    case changesBranches(cwd: String? = nil)
    /// A revision's diff as a patch (Copy as patch).
    case changesPatch(revision: ChangesRevision, options: ChangesOptions, cwd: String? = nil)
    /// Undo a turn's edits in the agent's working tree; Redo puts them back.
    case changesUndoTurn(turnID: UUID)
    case changesRedoTurn(turnID: UUID)
    /// Revert one file of a working-tree review to HEAD (`changesRevertCapability`): `revision` is
    /// the uncommitted list's (`old` HEAD's tree, `new` the working tree as shown), and the host
    /// refuses when the file changed since, so only the version the client displayed is undone. A
    /// modified or deleted file comes back from HEAD; a new one goes to the Trash; a rename
    /// restores `oldPath` and trashes `path`. The index is never touched, as with Undo.
    case changesRevertFile(revision: ChangesRevision, path: String, oldPath: String?)
    /// The dev servers the agent's folder on the host offers (`DevServerDiscovery`): the Browser's
    /// Nothing open (`browserTunnelCapability`). Answered by the host's server itself.
    case devServers
    /// A folder of the thread's own folder on the host, `path` relative to it ("" for the folder itself),
    /// hidden entries only when asked (`filesCapability`, like `fileRead`). Answered by the host's server itself.
    case files(path: String, showHidden: Bool)
    /// A UTF-8 text file in the thread's folder, at most `ThreadFilesLimits.readBytes`.
    case fileRead(path: String)
    /// Saves `text` over an existing UTF-8 file in the thread's folder only while it still holds `expected`, the
    /// text the client edited from; both at most `ThreadFilesLimits.readBytes` (`filesWriteCapability`).
    case fileWrite(path: String, text: String, expected: String)
    /// Looks the thread's branch's pull request up again and answers it (`pullRequestLinkCapability`):
    /// the side pane's Pull request tab.
    case pullRequest

    /// `files`, `fileRead` or `fileWrite`: answered by the host's server itself.
    public var isFiles: Bool {
        switch self {
        case .files, .fileRead, .fileWrite: true
        default: false
        }
    }

    /// The repository a `changes*` read reviews instead of the agent's own folder.
    public var changesCwd: String? {
        switch self {
        case .changesOverview(let cwd), .changesBranches(let cwd), .changesList(_, _, let cwd), .changesFile(_, _, _, _, let cwd),
             .changesPatch(_, _, let cwd): cwd
        default: nil
        }
    }

    /// Answered by the host's server itself, without the GUI.
    public var isChanges: Bool {
        switch self {
        case .changesOverview, .changesList, .changesFile, .changesBranches, .changesPatch, .changesUndoTurn, .changesRedoTurn, .changesRevertFile: true
        default: false
        }
    }
}

public enum RemoteAgentResult: Codable, Hashable, Sendable {
    case ok
    case worktreeInfo(RemoteWorktreeInfo)
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
    /// The dev servers the agent's folder on the host offers (`RemoteAgentQuery.devServers`).
    case devServers([DevServer])
    /// A folder's entries (`RemoteAgentQuery.files`).
    case files(ThreadFileListing)
    /// A file's bytes, UTF-8 text (`RemoteAgentQuery.fileRead`).
    case fileData(Data)
    /// A save's outcome (`RemoteAgentQuery.fileWrite`).
    case fileWrite(ThreadFileSaveResult)
    /// The thread's branch's pull request (`RemoteAgentQuery.pullRequest`); nil for none, or gh couldn't say.
    case pullRequest(ThreadPullRequest?)
}

/// Client → host. The first message on a connection must be a successful
/// `hello`; anything else closes the connection.
public enum RemoteRequest: Codable, Hashable, Sendable {
    case pushRegistration(id: Int, registration: RemotePushRegistration)
    case pushUnregister(id: Int, registrationID: String)
    case nativeThread(id: Int, agentID: AgentID, request: NativeThreadRequest)
    case nativeThreadSubscribe(id: Int, agentIDs: [AgentID])
    case fleetDigest(id: Int, agentID: AgentID, session: NativeThreadSession?, revision: UInt64?)
    /// Fleet (`RemoteProtocol.fleetCapability`). Before `hello`: who is there (answered
    /// `fleetIdentity`). A client never sends a token to an address that identifies as another
    /// host than the one it paired with. Rate limited; it says only what Bonjour already says.
    case fleetIdentify(id: Int)
    /// Before `hello`: pair with the code this Mac's Join screen shows. Answered `fleetPaired`.
    case fleetPair(id: Int, code: String, from: FleetIntroduction)
    /// After `hello` with the shared token: the same exchange as `fleetPair`, with the token
    /// standing for the code (an existing paired host becoming a peer). Answered `fleetPaired`.
    case fleetEstablish(id: Int, from: FleetIntroduction)
    /// After `hello` with a peer's token: introduce another member to this host (a step of
    /// `FleetIntroduce`). Answered `fleetPaired` with the token hash to relay, or `ok` when this
    /// host already knows the member.
    case fleetIntroduce(id: Int, introduction: FleetIntroduce)
    /// After `hello` with a peer's token: `hostID` was removed from the fleet at `at` (epoch
    /// milliseconds). Answered `ok`.
    case fleetRevoke(id: Int, hostID: UUID, at: Double)
    /// After `hello` with a peer's token (`RemoteProtocol.fleetSyncCapability`): sync ops, live ops
    /// and blobs between two Macs' stores. Answered `fleetSyncReply`.
    case fleetSync(id: Int, request: FleetSyncRequest)
    /// Before `hello`: a phone, iPad or Mac app pairs with the code Add a device shows (it asked who
    /// answers first, like `fleetPair`). Answered `fleetDevices` with the Macs it can now reach.
    case fleetPairDevice(id: Int, code: String, device: FleetDeviceIntroduction)
    /// After `hello` with the shared token: a client is given a token of its own, made by the client.
    /// Answered `fleetDevices`.
    case fleetEnrollDevice(id: Int, device: FleetDeviceIntroduction)
    /// After `hello` with a peer's token: the devices the sender holds, merged here (a revoked one wins).
    /// Answered `fleetDevices` with the ones this host holds.
    case fleetSyncDevices(id: Int, devices: [FleetDeviceEntry])
    /// Local clients only: this Mac's fleet as its app draws it. Answered `fleetResult`.
    case fleetRead(id: Int)
    /// Local clients only: this Mac's app acts on its host's fleet. Answered `fleetResult`.
    case fleetAction(id: Int, action: FleetAction)
    /// After `hello` with a peer's token (`fleetPressureCapability`): this Mac's newest sample. The
    /// receiver stamps its arrival by its own clock and files it under the Mac that authenticated.
    /// Answered `ok`.
    case fleetPressure(id: Int, sample: FleetPressureSample)
    /// After `hello` with a peer's token: what this Mac is and can run, pushed when it changes and
    /// each day. Answered `ok`.
    case fleetReadiness(id: Int, report: FleetReadinessReport)
    /// After `hello` with a peer's token: ask for a sample now, because the newest is stale.
    /// Answered `fleetPressureSample`.
    case fleetPressureNow(id: Int)
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
    /// Local clients only (`hostDrainCapability`): the app is newer than its background host,
    /// which keeps serving and exits once no agent is busy, so launchd starts the new build.
    /// Answered `ok`.
    case drain(id: Int)
    /// Local clients only: this Mac's app asks its background host about an update it installs
    /// (`HostUpdateGateStep`). Answered `ok` or an error carrying the reason.
    case hostUpdateGate(id: Int, step: HostUpdateGateStep)
    /// Create a space from a directory that exists on the host.
    case addSpace(id: Int, path: String)
    /// Local clients only (`localCapability`): this Mac's own app changes one of its background
    /// host's spaces. Answered `ok`.
    case spaceAction(id: Int, spaceID: SpaceID, action: RemoteSpaceAction)
    /// Local clients only (`localCapability`): this Mac's own app registers, edits or adds a child
    /// to one of its background host's spaces. Answered `spaceAdded` with the space.
    case projectRequest(id: Int, request: RemoteProjectRequest)
    /// Local clients only (`localCapability`): this Mac's own app starts a thread on its
    /// host. Answered `agentCreated`.
    case startThread(id: Int, thread: RemoteThreadStart)
    /// Local clients only (`localCapability`): the thread this Mac's own app shows with Shepherd
    /// in front (nil: none), so the host's phone pushes for it stay quiet, and the pane with its
    /// keyboard (`paneID`, nil: none; the terminal list's focused one). Answered `ok`.
    case focusThread(id: Int, agentID: AgentID?, paneID: PaneID? = nil)
    /// Local clients only (`appRelayCapability`): the paired Macs this Mac's own app is connected
    /// to, for the Projects its background host owns (`ProjectExecutorsUpdate`). Answered `ok`.
    case projectExecutors(id: Int, update: ProjectExecutorsUpdate)
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
        worktreeFetchFirst: Bool? = nil,
        /// The opening prompt's images (`createAgentImagesCapability`); absent on the wire when nil.
        initialImages: [NativeImage]? = nil,
        serviceTier: ServiceTier? = nil
    )

    case upload(id: Int, action: RemoteUploadAction)
    case creationOptions(id: Int, spaceID: SpaceID, cwd: String?, fetchFirst: Bool?)
    /// A space's branches for a new worktree's base (`creationBranchesCapability`), as the Mac's
    /// worktree base picker reads them. Answered `agentResult(.changesBranches)`.
    case creationBranches(id: Int, spaceID: SpaceID)
    case agentQuery(id: Int, agentID: AgentID, query: RemoteAgentQuery)
    case agentAction(id: Int, agentID: AgentID, action: RemoteAgentAction)
    /// Manage one automation (`RemoteProtocol.automationsCapability`). A `create` names the new
    /// automation's id.
    case automation(id: Int, automationID: AutomationID, request: RemoteAutomationRequest)
    /// Read or change GitHub issues and pull requests through the host's gh
    /// (`RemoteProtocol.forgeCapability`). Answered `forgeResult` or an error whose code is a
    /// `ForgeError.Code`.
    case forge(id: Int, request: RemoteForgeRequest)
    /// Read or save the host's root instructions (`RemoteProtocol.instructionsCapability`).
    case instructions(id: Int, request: RemoteInstructionsRequest)
    /// Read or act on the host's suggested instructions (`RemoteProtocol.suggestionsCapability`).
    case suggestions(id: Int, request: RemoteSuggestionsRequest)
    /// Read or change the host's settings (`RemoteProtocol.hostSettingsCapability`).
    case hostSettings(id: Int, request: RemoteHostSettingsRequest)
    /// Read the host's MCP servers, subagent profiles or providers (`RemoteProtocol.hostInventoryCapability`).
    case hostInventory(id: Int, request: RemoteHostInventoryRequest)
    /// Change the host's MCP servers, subagent profiles or sign-ins (`RemoteProtocol.hostConfigCapability`).
    case hostConfig(id: Int, request: RemoteHostConfigRequest)
    case hostUpdate(id: Int, request: RemoteHostUpdateRequest)
    /// Read or change the host's agent skills (`RemoteProtocol.skillsCapability`).
    case skills(id: Int, request: RemoteSkillsRequest)
    /// Read or change the host's hooks, or test one there (`RemoteProtocol.hooksCapability`).
    case hooks(id: Int, request: RemoteHooksRequest)
    /// List, run or stop a space's apps (`RemoteProtocol.appsCapability`). Answered `apps`.
    case apps(id: Int, request: RemoteAppsRequest)
    /// Project-only files, never the host's global settings (`projectsV2Capability`; older hosts use v1).
    case projects(id: Int, request: RemoteProjectsRequest)
    case logicalProjectRuntime(id: Int, request: ProjectRuntimeTransport)
    case logicalProjects(id: Int, request: LogicalProjectsRequest)
    case projectExecution(id: Int, request: ProjectExecutionRequest)
    /// Read or change the host's designs (`RemoteProtocol.designsCapability`).
    case design(id: Int, request: RemoteDesignRequest)
    /// A Missions request (`RemoteProtocol.missionsCapability`), answered `mission` or an error.
    case mission(id: Int, request: RemoteMissionRequest)
    /// One message of a Browser tunnel (`RemoteProtocol.browserTunnelCapability`). Nothing answers it
    /// by id: the host's frames come back as `RemoteReply.tunnel`.
    case tunnel(BrowserTunnelFrame)
    /// Claim `agentID`'s browser for this viewer (`RemoteProtocol.browserDriveCapability`): while it
    /// owns it, the host runs the agent's browser tools on this viewer's page. Answered
    /// `browserClaimed`, or an error (`no_such_agent`, `too_many`, `unsupported`). The most recent
    /// claim wins.
    case browserClaim(id: Int, agentID: AgentID)
    /// Give `agentID`'s browser back to the host. Nothing answers it; a viewer that does not own the
    /// agent's browser is ignored.
    case browserRelease(agentID: AgentID)
    /// The owner's answer to a `BrowserDrivePush.request` carrying `requestToken`. Nothing answers it;
    /// an answer that is not the owner's, or for a request that is over, is ignored.
    case browserAnswer(requestToken: Int, outcome: BrowserOutcome)
    /// The app's answer to a `RemoteReply.designRelay` carrying `requestToken`. Nothing answers
    /// it; one from anyone but the client the job went to, or for a job that is over, is ignored.
    case designRelayAnswer(requestToken: Int, result: DesignRelayResult)
    /// The app's answer to a `RemoteReply.appRelay` carrying `requestToken`. Nothing answers it;
    /// one from anyone but the client the job went to, or for a job that is over, is ignored.
    case appRelayAnswer(requestToken: Int, result: AppRelayResult)

    private enum CodingKeys: String, CodingKey {
        case registration, registrationID, agentIDs, session, revision
        case request, frame
        case type, id, token, clientName, protocolVersion, capabilities
        case sessionID, cols, rows, data, viewportGeneration
        case path, spaceID, cwd, model, thinking, initialPrompt, worktreeBranch
        case text, submit, agentID, paneID, axis, relativeTo, split, ratio, action, query, fetchFirst, worktreeBase, worktreeFetchFirst
        case automationID, initialImages, serviceTier
        case requestToken, outcome, result
        case thread, step, update
        case code, from, introduction, hostID, at, sync, device, devices
        case sample, report
    }

    private enum Kind: String, Codable {
        case pushRegistration, pushUnregister
        case fleetIdentify, fleetPair, fleetEstablish, fleetIntroduce, fleetRevoke, fleetRead, fleetAction
        case fleetPressure, fleetReadiness, fleetPressureNow
        case fleetSync
        case fleetPairDevice, fleetEnrollDevice, fleetSyncDevices
        case nativeThread, nativeThreadSubscribe, fleetDigest, projectExecution
        case hello, stateFetch, attach, detach, input, resize, paste
        case openPane, closePane, resizePaneSplit
        case listDir, listModels, drain, hostUpdateGate, addSpace, spaceAction, projectRequest, startThread, focusThread, projectExecutors, createAgent, agentAction, agentQuery, upload, creationOptions, creationBranches
        case automation, forge
        case logicalProjectRuntime
        case instructions, suggestions, hostSettings, hostInventory, hostUpdate, skills, projects, logicalProjects
        case hostConfig, hooks, apps
        case design, mission
        case tunnel
        case browserClaim, browserRelease, browserAnswer
        case designRelayAnswer, appRelayAnswer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .pushRegistration:
            self = .pushRegistration(id: try c.decode(Int.self, forKey: .id), registration: try c.decode(RemotePushRegistration.self, forKey: .registration))
        case .pushUnregister:
            self = .pushUnregister(id: try c.decode(Int.self, forKey: .id), registrationID: try c.decode(String.self, forKey: .registrationID))
        case .nativeThread:
            self = .nativeThread(id: try c.decode(Int.self, forKey: .id), agentID: try c.decode(AgentID.self, forKey: .agentID), request: try c.decode(NativeThreadRequest.self, forKey: .request))
        case .nativeThreadSubscribe:
            self = .nativeThreadSubscribe(id: try c.decode(Int.self, forKey: .id), agentIDs: try c.decode([AgentID].self, forKey: .agentIDs))
        case .fleetDigest:
            self = .fleetDigest(id: try c.decode(Int.self, forKey: .id), agentID: try c.decode(AgentID.self, forKey: .agentID), session: try c.decodeIfPresent(NativeThreadSession.self, forKey: .session), revision: try c.decodeIfPresent(UInt64.self, forKey: .revision))
        case .fleetIdentify:
            self = .fleetIdentify(id: try c.decode(Int.self, forKey: .id))
        case .fleetPair:
            self = .fleetPair(id: try c.decode(Int.self, forKey: .id), code: try c.decode(String.self, forKey: .code),
                              from: try c.decode(FleetIntroduction.self, forKey: .from))
        case .fleetEstablish:
            self = .fleetEstablish(id: try c.decode(Int.self, forKey: .id), from: try c.decode(FleetIntroduction.self, forKey: .from))
        case .fleetIntroduce:
            self = .fleetIntroduce(id: try c.decode(Int.self, forKey: .id), introduction: try c.decode(FleetIntroduce.self, forKey: .introduction))
        case .fleetRevoke:
            self = .fleetRevoke(id: try c.decode(Int.self, forKey: .id), hostID: try c.decode(UUID.self, forKey: .hostID),
                                at: try c.decode(Double.self, forKey: .at))
        case .fleetSync:
            self = .fleetSync(id: try c.decode(Int.self, forKey: .id), request: try c.decode(FleetSyncRequest.self, forKey: .sync))
        case .fleetPairDevice:
            self = .fleetPairDevice(id: try c.decode(Int.self, forKey: .id), code: try c.decode(String.self, forKey: .code),
                                    device: try c.decode(FleetDeviceIntroduction.self, forKey: .device))
        case .fleetEnrollDevice:
            self = .fleetEnrollDevice(id: try c.decode(Int.self, forKey: .id), device: try c.decode(FleetDeviceIntroduction.self, forKey: .device))
        case .fleetSyncDevices:
            self = .fleetSyncDevices(id: try c.decode(Int.self, forKey: .id), devices: try c.decode([FleetDeviceEntry].self, forKey: .devices))
        case .fleetRead:
            self = .fleetRead(id: try c.decode(Int.self, forKey: .id))
        case .fleetAction:
            self = .fleetAction(id: try c.decode(Int.self, forKey: .id), action: try c.decode(FleetAction.self, forKey: .action))
        case .fleetPressure:
            self = .fleetPressure(id: try c.decode(Int.self, forKey: .id), sample: try c.decode(FleetPressureSample.self, forKey: .sample))
        case .fleetReadiness:
            self = .fleetReadiness(id: try c.decode(Int.self, forKey: .id), report: try c.decode(FleetReadinessReport.self, forKey: .report))
        case .fleetPressureNow:
            self = .fleetPressureNow(id: try c.decode(Int.self, forKey: .id))
        case .tunnel:
            self = .tunnel(try c.decode(BrowserTunnelFrame.self, forKey: .frame))
        case .browserClaim:
            self = .browserClaim(id: try c.decode(Int.self, forKey: .id), agentID: try c.decode(AgentID.self, forKey: .agentID))
        case .browserRelease:
            self = .browserRelease(agentID: try c.decode(AgentID.self, forKey: .agentID))
        case .browserAnswer:
            self = .browserAnswer(requestToken: try c.decode(Int.self, forKey: .requestToken), outcome: try c.decode(BrowserOutcome.self, forKey: .outcome))
        case .designRelayAnswer:
            self = .designRelayAnswer(requestToken: try c.decode(Int.self, forKey: .requestToken), result: try c.decode(DesignRelayResult.self, forKey: .result))
        case .appRelayAnswer:
            self = .appRelayAnswer(requestToken: try c.decode(Int.self, forKey: .requestToken), result: try c.decode(AppRelayResult.self, forKey: .result))
        case .design:
            self = .design(id: try c.decode(Int.self, forKey: .id), request: try c.decode(RemoteDesignRequest.self, forKey: .request))
        case .mission:
            self = .mission(id: try c.decode(Int.self, forKey: .id), request: try c.decode(RemoteMissionRequest.self, forKey: .request))
        case .automation:
            self = .automation(id: try c.decode(Int.self, forKey: .id),
                               automationID: try c.decode(AutomationID.self, forKey: .automationID),
                               request: try c.decode(RemoteAutomationRequest.self, forKey: .request))
        case .forge:
            self = .forge(id: try c.decode(Int.self, forKey: .id), request: try c.decode(RemoteForgeRequest.self, forKey: .request))
        case .instructions:
            self = .instructions(id: try c.decode(Int.self, forKey: .id),
                                 request: try c.decode(RemoteInstructionsRequest.self, forKey: .request))
        case .suggestions:
            self = .suggestions(id: try c.decode(Int.self, forKey: .id),
                                request: try c.decode(RemoteSuggestionsRequest.self, forKey: .request))
        case .hostUpdate:
            self = .hostUpdate(id: try c.decode(Int.self, forKey: .id), request: try c.decode(RemoteHostUpdateRequest.self, forKey: .request))
        case .hostSettings:
            self = .hostSettings(id: try c.decode(Int.self, forKey: .id),
                                 request: try c.decode(RemoteHostSettingsRequest.self, forKey: .request))
        case .hostInventory:
            self = .hostInventory(id: try c.decode(Int.self, forKey: .id),
                                  request: try c.decode(RemoteHostInventoryRequest.self, forKey: .request))
        case .hostConfig:
            self = .hostConfig(id: try c.decode(Int.self, forKey: .id),
                               request: try c.decode(RemoteHostConfigRequest.self, forKey: .request))
        case .logicalProjectRuntime:
            self = .logicalProjectRuntime(id: try c.decode(Int.self, forKey: .id), request: try c.decode(ProjectRuntimeTransport.self, forKey: .request))
        case .projectExecution:
            self = .projectExecution(id: try c.decode(Int.self, forKey: .id), request: try c.decode(ProjectExecutionRequest.self, forKey: .request))
        case .logicalProjects:
            self = .logicalProjects(id: try c.decode(Int.self, forKey: .id), request: try c.decode(LogicalProjectsRequest.self, forKey: .request))
        case .projects:
            self = .projects(id: try c.decode(Int.self, forKey: .id), request: try c.decode(RemoteProjectsRequest.self, forKey: .request))
        case .skills:
            self = .skills(id: try c.decode(Int.self, forKey: .id),
                           request: try c.decode(RemoteSkillsRequest.self, forKey: .request))
        case .hooks:
            self = .hooks(id: try c.decode(Int.self, forKey: .id), request: try c.decode(RemoteHooksRequest.self, forKey: .request))
        case .apps:
            self = .apps(id: try c.decode(Int.self, forKey: .id), request: try c.decode(RemoteAppsRequest.self, forKey: .request))
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
        case .creationBranches:
            self = .creationBranches(id: try c.decode(Int.self, forKey: .id), spaceID: try c.decode(SpaceID.self, forKey: .spaceID))
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
        case .drain:
            self = .drain(id: try c.decode(Int.self, forKey: .id))
        case .hostUpdateGate:
            self = .hostUpdateGate(id: try c.decode(Int.self, forKey: .id), step: try c.decode(HostUpdateGateStep.self, forKey: .step))
        case .addSpace:
            self = .addSpace(
                id: try c.decode(Int.self, forKey: .id),
                path: try c.decode(String.self, forKey: .path)
            )
        case .focusThread:
            self = .focusThread(id: try c.decode(Int.self, forKey: .id), agentID: try c.decodeIfPresent(AgentID.self, forKey: .agentID),
                                paneID: try c.decodeIfPresent(PaneID.self, forKey: .paneID))
        case .projectExecutors:
            self = .projectExecutors(id: try c.decode(Int.self, forKey: .id), update: try c.decode(ProjectExecutorsUpdate.self, forKey: .update))
        case .startThread:
            self = .startThread(id: try c.decode(Int.self, forKey: .id), thread: try c.decode(RemoteThreadStart.self, forKey: .thread))
        case .projectRequest:
            self = .projectRequest(id: try c.decode(Int.self, forKey: .id), request: try c.decode(RemoteProjectRequest.self, forKey: .request))
        case .spaceAction:
            self = .spaceAction(
                id: try c.decode(Int.self, forKey: .id),
                spaceID: try c.decode(SpaceID.self, forKey: .spaceID),
                action: try c.decode(RemoteSpaceAction.self, forKey: .action)
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
                worktreeFetchFirst: try c.decodeIfPresent(Bool.self, forKey: .worktreeFetchFirst),
                initialImages: try c.decodeIfPresent([NativeImage].self, forKey: .initialImages),
                serviceTier: try c.decodeIfPresent(ServiceTier.self, forKey: .serviceTier)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fleetIdentify(let id):
            try c.encode(Kind.fleetIdentify, forKey: .type)
            try c.encode(id, forKey: .id)
        case .fleetPair(let id, let code, let from):
            try c.encode(Kind.fleetPair, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(code, forKey: .code)
            try c.encode(from, forKey: .from)
        case .fleetEstablish(let id, let from):
            try c.encode(Kind.fleetEstablish, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(from, forKey: .from)
        case .fleetIntroduce(let id, let introduction):
            try c.encode(Kind.fleetIntroduce, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(introduction, forKey: .introduction)
        case .fleetRevoke(let id, let hostID, let at):
            try c.encode(Kind.fleetRevoke, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(hostID, forKey: .hostID)
            try c.encode(at, forKey: .at)
        case .fleetSync(let id, let request):
            try c.encode(Kind.fleetSync, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .sync)
        case .fleetPairDevice(let id, let code, let device):
            try c.encode(Kind.fleetPairDevice, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(code, forKey: .code)
            try c.encode(device, forKey: .device)
        case .fleetEnrollDevice(let id, let device):
            try c.encode(Kind.fleetEnrollDevice, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(device, forKey: .device)
        case .fleetSyncDevices(let id, let devices):
            try c.encode(Kind.fleetSyncDevices, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(devices, forKey: .devices)
        case .fleetRead(let id):
            try c.encode(Kind.fleetRead, forKey: .type)
            try c.encode(id, forKey: .id)
        case .fleetAction(let id, let action):
            try c.encode(Kind.fleetAction, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(action, forKey: .action)
        case .fleetPressure(let id, let sample):
            try c.encode(Kind.fleetPressure, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(sample, forKey: .sample)
        case .fleetReadiness(let id, let report):
            try c.encode(Kind.fleetReadiness, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(report, forKey: .report)
        case .fleetPressureNow(let id):
            try c.encode(Kind.fleetPressureNow, forKey: .type)
            try c.encode(id, forKey: .id)
        case .nativeThreadSubscribe(let id, let agentIDs):
            try c.encode(Kind.nativeThreadSubscribe, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentIDs, forKey: .agentIDs)
        case .fleetDigest(let id, let agentID, let session, let revision):
            try c.encode(Kind.fleetDigest, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encodeIfPresent(session, forKey: .session)
            try c.encodeIfPresent(revision, forKey: .revision)
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
        case .creationBranches(let id, let spaceID):
            try c.encode(Kind.creationBranches, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(spaceID, forKey: .spaceID)
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
        case .forge(let id, let request):
            try c.encode(Kind.forge, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .instructions(let id, let request):
            try c.encode(Kind.instructions, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .suggestions(let id, let request):
            try c.encode(Kind.suggestions, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .pushRegistration(let id, let registration):
            try c.encode(Kind.pushRegistration, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(registration, forKey: .registration)
        case .pushUnregister(let id, let registrationID):
            try c.encode(Kind.pushUnregister, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(registrationID, forKey: .registrationID)
        case .hostUpdate(let id, let request):
            try c.encode(Kind.hostUpdate, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .hostSettings(let id, let request):
            try c.encode(Kind.hostSettings, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .hostInventory(let id, let request):
            try c.encode(Kind.hostInventory, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .hostConfig(let id, let request):
            try c.encode(Kind.hostConfig, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .logicalProjectRuntime(let id, let request):
            try c.encode(Kind.logicalProjectRuntime, forKey: .type)
            try c.encode(id, forKey: .id); try c.encode(request, forKey: .request)
        case .projectExecution(let id, let request):
            try c.encode(Kind.projectExecution, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .logicalProjects(let id, let request):
            try c.encode(Kind.logicalProjects, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .projects(let id, let request):
            try c.encode(Kind.projects, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .skills(let id, let request):
            try c.encode(Kind.skills, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .hooks(let id, let request):
            try c.encode(Kind.hooks, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .apps(let id, let request):
            try c.encode(Kind.apps, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .design(let id, let request):
            try c.encode(Kind.design, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .mission(let id, let request):
            try c.encode(Kind.mission, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .tunnel(let frame):
            try c.encode(Kind.tunnel, forKey: .type)
            try c.encode(frame, forKey: .frame)
        case .browserClaim(let id, let agentID):
            try c.encode(Kind.browserClaim, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
        case .browserRelease(let agentID):
            try c.encode(Kind.browserRelease, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
        case .browserAnswer(let requestToken, let outcome):
            try c.encode(Kind.browserAnswer, forKey: .type)
            try c.encode(requestToken, forKey: .requestToken)
            try c.encode(outcome, forKey: .outcome)
        case .designRelayAnswer(let requestToken, let result):
            try c.encode(Kind.designRelayAnswer, forKey: .type)
            try c.encode(requestToken, forKey: .requestToken)
            try c.encode(result, forKey: .result)
        case .appRelayAnswer(let requestToken, let result):
            try c.encode(Kind.appRelayAnswer, forKey: .type)
            try c.encode(requestToken, forKey: .requestToken)
            try c.encode(result, forKey: .result)
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
        case .drain(let id):
            try c.encode(Kind.drain, forKey: .type)
            try c.encode(id, forKey: .id)
        case .hostUpdateGate(let id, let step):
            try c.encode(Kind.hostUpdateGate, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(step, forKey: .step)
        case .addSpace(let id, let path):
            try c.encode(Kind.addSpace, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(path, forKey: .path)
        case .focusThread(let id, let agentID, let paneID):
            try c.encode(Kind.focusThread, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(agentID, forKey: .agentID)
            try c.encodeIfPresent(paneID, forKey: .paneID)
        case .projectExecutors(let id, let update):
            try c.encode(Kind.projectExecutors, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(update, forKey: .update)
        case .startThread(let id, let thread):
            try c.encode(Kind.startThread, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(thread, forKey: .thread)
        case .projectRequest(let id, let request):
            try c.encode(Kind.projectRequest, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(request, forKey: .request)
        case .spaceAction(let id, let spaceID, let action):
            try c.encode(Kind.spaceAction, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(spaceID, forKey: .spaceID)
            try c.encode(action, forKey: .action)
        case .createAgent(let id, let spaceID, let cwd, let model, let thinking, let initialPrompt, let worktreeBranch, let worktreeBase, let worktreeFetchFirst, let initialImages, let serviceTier):
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
            try c.encodeIfPresent(initialImages, forKey: .initialImages)
            try c.encodeIfPresent(serviceTier, forKey: .serviceTier)
        }
    }
}

/// The Settings pages of this Mac's app that read the background host's own stores
/// (`RemoteReply.settingsChanged`).
public enum RemoteSettingsPage: String, Codable, Hashable, Sendable, CaseIterable {
    case instructions, suggestions, skills, hooks, slashCommands
    /// Settings ▸ Fleet's Serve this Mac (with Fleet off): the listener opened, closed or failed.
    case remote
    /// The Fleet page: a sample or readiness report arrived, or this Mac took one (pushed every
    /// few seconds while the page is on screen).
    case fleetPressure
    /// Settings ▸ Fleet: a Mac was added or removed, a link came or went, or the join code window changed.
    case fleet
}

/// Host → client. Replies correlate by request `id`; `stateChanged` is an
/// unsolicited push after every host-side mutation.
public enum RemoteReply: Codable, Hashable, Sendable {
    case nativeThread(id: Int, result: NativeThreadResult)
    case nativeThreadChanged(agentID: AgentID)
    case fleetDigest(id: Int, result: NativeFleetDigestResult)
    case uploadResult(id: Int, result: RemoteUploadResult)
    case creationOptions(id: Int, options: RemoteCreationOptions)
    /// `hostBuild`: the host's build (`CFBundleVersion`); absent from an older host.
    /// `hostID`: this host's fleet identity (`FleetIdentity`), absent from an older host and while Fleet is off.
    case helloOk(id: Int, protocolVersion: Int, capabilities: [String], hostBuild: String? = nil, hostID: UUID? = nil)
    /// Who answers (`RemoteRequest.fleetIdentify`). `fleetEnabled`: this host takes part in a fleet.
    case fleetIdentity(id: Int, hostID: UUID, name: String, build: String?, fleetEnabled: Bool)
    /// A pairing, an establishing or an introduction went through: the id and name of the host
    /// that answers, and the hash of the token it will present to the one that asked.
    case fleetPaired(id: Int, hostID: UUID, name: String, myTokenHash: String)
    /// This Mac's fleet, for its app (`RemoteRequest.fleetRead`, `.fleetAction`).
    case fleetResult(id: Int, result: FleetResult)
    /// This Mac's newest sample and readiness report (`RemoteRequest.fleetPressureNow`).
    case fleetPressureSample(id: Int, sample: FleetPressureSample, readiness: FleetReadinessReport?)
    /// The answer to `RemoteRequest.fleetSync`.
    case fleetSyncReply(id: Int, reply: FleetSyncReply)
    /// A device paired or was given its token, or devices were synced (`fleetPairDevice`, `fleetEnrollDevice`, `fleetSyncDevices`).
    case fleetDevices(id: Int, result: FleetDevicesResult)
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
    case models(id: Int, models: [String], defaultModel: String?, withoutThinking: [String]? = nil, thinkingLevels: [String: [String]]? = nil,
                serviceTiers: [String: [String]]? = nil, contexts: [String: String]? = nil, withoutImages: [String]? = nil)
    /// Space created on the host (the state push carries the full snapshot).
    case spaceAdded(id: Int, spaceID: SpaceID)
    /// Agent created and its pi process spawned on the host.
    case agentCreated(id: Int, agentID: AgentID)
    /// An automation request's answer (`RemoteRequest.automation`).
    case automationResult(id: Int, result: RemoteAutomationResult)
    /// A forge request's answer (`RemoteRequest.forge`).
    case forgeResult(id: Int, result: RemoteForgeResult)
    /// The host's root instructions after an instructions request (`RemoteRequest.instructions`).
    case instructions(id: Int, snapshot: InstructionsSnapshot)
    /// The host's suggested instructions after a suggestions request (`RemoteRequest.suggestions`).
    case suggestions(id: Int, snapshot: SuggestionsSnapshot)
    /// The host's settings after a settings request (`RemoteRequest.hostSettings`).
    case hostSettings(id: Int, settings: HostSettings)
    /// An inventory request's answer (`RemoteRequest.hostInventory`).
    case hostInventory(id: Int, result: RemoteHostInventoryResult)
    /// A configuration request's answer (`RemoteRequest.hostConfig`): never a secret.
    case hostConfig(id: Int, result: RemoteHostConfigResult)
    case hostUpdate(id: Int, status: HostUpdateStatus)
    /// A skills request's answer (`RemoteRequest.skills`).
    case skills(id: Int, result: RemoteSkillsResult)
    /// A hooks request's answer (`RemoteRequest.hooks`).
    case hooks(id: Int, result: RemoteHooksResult)
    /// An apps request's answer (`RemoteRequest.apps`): the space's apps as they are now.
    case apps(id: Int, result: RemoteAppsResult)
    case projects(id: Int, result: RemoteProjectsResult)
    case logicalProjectRuntime(id: Int, result: ProjectRuntimeResult)
    case logicalProjects(id: Int, result: LogicalProjectsResult)
    case projectExecution(id: Int, result: ProjectExecutionResult)
    case projectExecutionChanged(key: ProjectExecutionKey, revision: UInt64)
    /// A design request's answer (`RemoteRequest.design`).
    case design(id: Int, result: RemoteDesignResult)
    /// Pushed to a client watching the design (`RemoteDesignRequest.watch`) after each change to
    /// it: its files' new `revision`, or its comments' (`commentsRevision`), or both. A hint to
    /// pull; it carries no files.
    case designChanged(designID: DesignID, revision: UInt64?, commentsRevision: UInt64?)
    /// Pushed to a client that lists `designSystemsCapability` after the host's design systems
    /// changed (one added, renamed, re-synced or deleted): a hint to list them again.
    case designSystemsChanged
    /// A Missions request's answer (`RemoteRequest.mission`).
    case mission(id: Int, result: RemoteMissionResult)
    /// Pushed to a client that lists `missionsCapability` while the host offers it, after a mission
    /// is made or changes (`revision`) or goes (nil). A hint to pull; it carries no record.
    case missionChanged(missionID: MissionID, revision: UInt64?)
    /// Pushed like `missionChanged`, at most every half second while a mission's agents talk: what they say
    /// now (`RemoteMissionLive`, bounded); empty once nothing runs.
    case missionLive(missionID: MissionID, live: RemoteMissionLive)
    /// Pushed to a client that lists `designsCapability` when what the host offers changes (its
    /// Design tool experiment turned on or off): the whole list, as `helloOk` gave it.
    case capabilitiesChanged(capabilities: [String])
    /// One message of a Browser tunnel, to the client that opened it (`RemoteRequest.tunnel`).
    case tunnel(BrowserTunnelFrame)
    /// The claim `RemoteRequest.browserClaim` made stands: this viewer owns the agent's browser. `url`
    /// is the page the host's own browser holds for the agent, for the viewer to open through its
    /// tunnel (`http` or `https` only; nil when the host's has none). Cookies are not carried over.
    case browserClaimed(id: Int, url: String?)
    /// A viewer's part in an agent's browser (`BrowserDrivePush`), pushed only to a client that lists
    /// `RemoteProtocol.browserDriveCapability`.
    case browserDrive(BrowserDrivePush)
    /// A design to draw off screen for the background host, pushed only to a local client that
    /// lists `RemoteProtocol.designRelayCapability`; answered `RemoteRequest.designRelayAnswer`
    /// with the same token. `jobFile` is the path of a `DesignRelayJob`'s JSON on this Mac, which
    /// the app reads (a design's files outgrow `NDJSON.maxPayloadBytes`); the host removes it.
    case designRelay(token: Int, jobFile: String)
    /// An agent's notify tool (or its goal) on the background host, pushed only to this Mac's
    /// app that shows its threads as its own (`RemoteProtocol.localThreadsCapability`), which
    /// posts the banner; the host doesn't.
    case agentNotify(agentID: AgentID, title: String, body: String)
    /// What a background host's agent asks of Shepherd's window (`AppRelayJob`), pushed only to
    /// a local client that lists `RemoteProtocol.appRelayCapability`; answered
    /// `RemoteRequest.appRelayAnswer` with the same token.
    case appRelay(token: Int, job: AppRelayJob)
    /// What a Settings page shows changed on the background host (a client's change, an agent's
    /// suggestion, a newly listed slash command), pushed only to this Mac's app that shows the
    /// host's threads as its own (`RemoteProtocol.localThreadsCapability`), whose pages read it
    /// again. A hint; it carries nothing.
    case settingsChanged(page: RemoteSettingsPage)
    /// A tool call one of the background host's threads finished, pushed only to this Mac's app
    /// that shows its threads as its own (`RemoteProtocol.localThreadsCapability`): its sidebar
    /// activity follows it.
    case toolFinished(agentID: AgentID, tool: String)
    /// A design's thread notes changed on the background host, pushed only to this Mac's app that
    /// shows its threads as its own: its canvas reads them again (`RemoteDesignRequest.threadNotes`).
    case designNotesChanged(designID: DesignID)
    /// A design's Git state changed on the background host, pushed only to this Mac's app that
    /// shows its threads as its own: its Git chip reads it again (`RemoteDesignRequest.gitState`).
    case designGitChanged(designID: DesignID)
    /// How this Mac's own Import is going on the background host (`RemoteDesignRequest.importPrepare`),
    /// pushed only to the app that asked: Designs' card fills as its boards land.
    case designImportProgress(DesignImportProgress)
    /// A line the background host says in one of its threads (its account rotation), pushed only
    /// to this Mac's app that shows its threads as its own; never persisted.
    case threadNotice(agentID: AgentID, message: String)
    /// Every app's run on the host (`RemoteAppsRequest.processes`), pushed when one changes (at
    /// most ten times a second) and when the app connects, only to this Mac's app that shows the
    /// host's threads as its own and lists `RemoteProtocol.appsV2Capability`.
    case appsChanged(processes: [RemoteAppProcess])
    /// Why one of the background host's agents waits with its pi stopped (it couldn't start, or
    /// stopped on its own), or nil once pi starts again. Pushed only to this Mac's app that shows
    /// its threads as its own, as it happens and for every waiting agent when the app connects:
    /// the thread's can't-start and sign-in cards, opened or not.
    case agentStartProblem(agentID: AgentID, problem: NativeStartProblem?)
    /// The background host's automations changed: a run's log, or a trigger's status. Pushed only
    /// to this Mac's app that shows its threads as its own, which reads them again. A hint; it
    /// carries nothing.
    case automationsChanged
    /// An automation's banner on the background host (`AutomationHosting.notify`), pushed only to
    /// this Mac's app that shows its threads as its own, which posts it; the host doesn't.
    case automationNotify(title: String, body: String)
    /// Each of the background host's threads' pull request links, and why a merged one was kept
    /// open (`PullRequestLinks`), pushed only to this Mac's app that shows its threads as its own,
    /// when they change and as it connects: the sidebar's badges.
    case pullRequestLinks(links: [AgentID: ThreadPullRequest], notes: [AgentID: String])

    private enum CodingKeys: String, CodingKey {
        case result, frame, executionKey, executionRevision
        case type, id, protocolVersion, capabilities, code, message, state
        case sessionID, data, exitCode, spaceID, agentID, paneID
        case hostBuild, hostID, name, build, fleetEnabled, myTokenHash, sync
        case sample, readiness
        case path, parent, dirs, models, defaultModel, withoutThinking, thinkingLevels, serviceTiers, contexts, withoutImages, attachment, options
        case snapshot, settings, status
        case designID, revision, commentsRevision
        case url, push, missionID, live
        case token, jobFile, job
        case title, body
        case page, tool, problem
        case processes
        case links, notes
    }

    private enum Kind: String, Codable {
        case nativeThread, nativeThreadChanged, fleetDigest, projectExecution, projectExecutionChanged
        case fleetIdentity, fleetPaired, fleetResult, fleetDevices, fleetPressureSample
        case fleetSyncReply
        case agentResult, helloOk, ok, paneOpened, error, state, stateChanged, attached, output, sessionExited
        case dirListing, models, spaceAdded, agentCreated, uploadResult, creationOptions
        case automationResult, forgeResult
        case instructions, suggestions, hostSettings, hostInventory, hostUpdate, skills, projects, logicalProjects
        case hostConfig, hooks, apps
        case design, designChanged, designSystemsChanged, capabilitiesChanged
        case mission, missionChanged, missionLive
        case tunnel
        case browserClaimed, browserDrive, logicalProjectRuntime
        case designRelay, agentNotify, appRelay, settingsChanged, toolFinished, threadNotice, agentStartProblem, automationsChanged, automationNotify, designNotesChanged, designGitChanged, designImportProgress, appsChanged
        case pullRequestLinks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .nativeThread:
            self = .nativeThread(id: try c.decode(Int.self, forKey: .id), result: try c.decode(NativeThreadResult.self, forKey: .result))
        case .nativeThreadChanged:
            self = .nativeThreadChanged(agentID: try c.decode(AgentID.self, forKey: .agentID))
        case .fleetDigest:
            self = .fleetDigest(id: try c.decode(Int.self, forKey: .id), result: try c.decode(NativeFleetDigestResult.self, forKey: .result))
        case .tunnel:
            self = .tunnel(try c.decode(BrowserTunnelFrame.self, forKey: .frame))
        case .browserClaimed:
            self = .browserClaimed(id: try c.decode(Int.self, forKey: .id), url: try c.decodeIfPresent(String.self, forKey: .url))
        case .browserDrive:
            self = .browserDrive(try c.decode(BrowserDrivePush.self, forKey: .push))
        case .designRelay:
            self = .designRelay(token: try c.decode(Int.self, forKey: .token), jobFile: try c.decode(String.self, forKey: .jobFile))
        case .appRelay:
            self = .appRelay(token: try c.decode(Int.self, forKey: .token), job: try c.decode(AppRelayJob.self, forKey: .job))
        case .agentNotify:
            self = .agentNotify(agentID: try c.decode(AgentID.self, forKey: .agentID), title: try c.decode(String.self, forKey: .title),
                                body: try c.decode(String.self, forKey: .body))
        case .settingsChanged:
            self = .settingsChanged(page: try c.decode(RemoteSettingsPage.self, forKey: .page))
        case .designNotesChanged:
            self = .designNotesChanged(designID: try c.decode(DesignID.self, forKey: .designID))
        case .designGitChanged:
            self = .designGitChanged(designID: try c.decode(DesignID.self, forKey: .designID))
        case .designImportProgress:
            self = .designImportProgress(try c.decode(DesignImportProgress.self, forKey: .status))
        case .toolFinished:
            self = .toolFinished(agentID: try c.decode(AgentID.self, forKey: .agentID), tool: try c.decode(String.self, forKey: .tool))
        case .threadNotice:
            self = .threadNotice(agentID: try c.decode(AgentID.self, forKey: .agentID), message: try c.decode(String.self, forKey: .message))
        case .agentStartProblem:
            self = .agentStartProblem(agentID: try c.decode(AgentID.self, forKey: .agentID),
                                      problem: try c.decodeIfPresent(NativeStartProblem.self, forKey: .problem))
        case .automationsChanged:
            self = .automationsChanged
        case .appsChanged:
            self = .appsChanged(processes: try c.decode([RemoteAppProcess].self, forKey: .processes))
        case .automationNotify:
            self = .automationNotify(title: try c.decode(String.self, forKey: .title), body: try c.decode(String.self, forKey: .body))
        case .pullRequestLinks:
            self = .pullRequestLinks(links: try c.decode([AgentID: ThreadPullRequest].self, forKey: .links),
                                     notes: try c.decode([AgentID: String].self, forKey: .notes))
        case .design:
            self = .design(id: try c.decode(Int.self, forKey: .id), result: try c.decode(RemoteDesignResult.self, forKey: .result))
        case .designChanged:
            self = .designChanged(designID: try c.decode(DesignID.self, forKey: .designID),
                                  revision: try c.decodeIfPresent(UInt64.self, forKey: .revision),
                                  commentsRevision: try c.decodeIfPresent(UInt64.self, forKey: .commentsRevision))
        case .designSystemsChanged:
            self = .designSystemsChanged
        case .capabilitiesChanged:
            self = .capabilitiesChanged(capabilities: try c.decode([String].self, forKey: .capabilities))
        case .mission:
            self = .mission(id: try c.decode(Int.self, forKey: .id), result: try c.decode(RemoteMissionResult.self, forKey: .result))
        case .missionChanged:
            self = .missionChanged(missionID: try c.decode(MissionID.self, forKey: .missionID),
                                   revision: try c.decodeIfPresent(UInt64.self, forKey: .revision))
        case .missionLive:
            self = .missionLive(missionID: try c.decode(MissionID.self, forKey: .missionID), live: try c.decode(RemoteMissionLive.self, forKey: .live))
        case .helloOk:
            self = .helloOk(
                id: try c.decode(Int.self, forKey: .id),
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                capabilities: try c.decodeIfPresent([String].self, forKey: .capabilities) ?? [],
                hostBuild: try c.decodeIfPresent(String.self, forKey: .hostBuild),
                hostID: try c.decodeIfPresent(UUID.self, forKey: .hostID)
            )
        case .fleetIdentity:
            self = .fleetIdentity(id: try c.decode(Int.self, forKey: .id), hostID: try c.decode(UUID.self, forKey: .hostID),
                                  name: try c.decode(String.self, forKey: .name), build: try c.decodeIfPresent(String.self, forKey: .build),
                                  fleetEnabled: try c.decodeIfPresent(Bool.self, forKey: .fleetEnabled) ?? false)
        case .fleetPaired:
            self = .fleetPaired(id: try c.decode(Int.self, forKey: .id), hostID: try c.decode(UUID.self, forKey: .hostID),
                                name: try c.decode(String.self, forKey: .name), myTokenHash: try c.decode(String.self, forKey: .myTokenHash))
        case .fleetResult:
            self = .fleetResult(id: try c.decode(Int.self, forKey: .id), result: try c.decode(FleetResult.self, forKey: .result))
        case .fleetPressureSample:
            self = .fleetPressureSample(id: try c.decode(Int.self, forKey: .id), sample: try c.decode(FleetPressureSample.self, forKey: .sample),
                                        readiness: try c.decodeIfPresent(FleetReadinessReport.self, forKey: .readiness))
        case .fleetSyncReply:
            self = .fleetSyncReply(id: try c.decode(Int.self, forKey: .id), reply: try c.decode(FleetSyncReply.self, forKey: .sync))
        case .fleetDevices:
            self = .fleetDevices(id: try c.decode(Int.self, forKey: .id), result: try c.decode(FleetDevicesResult.self, forKey: .result))
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
        case .forgeResult:
            self = .forgeResult(id: try c.decode(Int.self, forKey: .id), result: try c.decode(RemoteForgeResult.self, forKey: .result))
        case .instructions:
            self = .instructions(id: try c.decode(Int.self, forKey: .id),
                                 snapshot: try c.decode(InstructionsSnapshot.self, forKey: .snapshot))
        case .suggestions:
            self = .suggestions(id: try c.decode(Int.self, forKey: .id),
                                snapshot: try c.decode(SuggestionsSnapshot.self, forKey: .snapshot))
        case .hostUpdate:
            self = .hostUpdate(id: try c.decode(Int.self, forKey: .id), status: try c.decode(HostUpdateStatus.self, forKey: .status))
        case .hostSettings:
            self = .hostSettings(id: try c.decode(Int.self, forKey: .id),
                                 settings: try c.decode(HostSettings.self, forKey: .settings))
        case .hostInventory:
            self = .hostInventory(id: try c.decode(Int.self, forKey: .id),
                                  result: try c.decode(RemoteHostInventoryResult.self, forKey: .result))
        case .hostConfig:
            self = .hostConfig(id: try c.decode(Int.self, forKey: .id),
                               result: try c.decode(RemoteHostConfigResult.self, forKey: .result))
        case .logicalProjectRuntime:
            self = .logicalProjectRuntime(id: try c.decode(Int.self, forKey: .id), result: try c.decode(ProjectRuntimeResult.self, forKey: .result))
        case .projectExecution:
            self = .projectExecution(id: try c.decode(Int.self, forKey: .id), result: try c.decode(ProjectExecutionResult.self, forKey: .result))
        case .projectExecutionChanged:
            self = .projectExecutionChanged(key: try c.decode(ProjectExecutionKey.self, forKey: .executionKey), revision: try c.decode(UInt64.self, forKey: .executionRevision))
        case .logicalProjects:
            self = .logicalProjects(id: try c.decode(Int.self, forKey: .id), result: try c.decode(LogicalProjectsResult.self, forKey: .result))
        case .projects:
            self = .projects(id: try c.decode(Int.self, forKey: .id), result: try c.decode(RemoteProjectsResult.self, forKey: .result))
        case .skills:
            self = .skills(id: try c.decode(Int.self, forKey: .id),
                           result: try c.decode(RemoteSkillsResult.self, forKey: .result))
        case .hooks:
            self = .hooks(id: try c.decode(Int.self, forKey: .id), result: try c.decode(RemoteHooksResult.self, forKey: .result))
        case .apps:
            self = .apps(id: try c.decode(Int.self, forKey: .id), result: try c.decode(RemoteAppsResult.self, forKey: .result))
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
                thinkingLevels: try c.decodeIfPresent([String: [String]].self, forKey: .thinkingLevels),
                serviceTiers: try c.decodeIfPresent([String: [String]].self, forKey: .serviceTiers),
                contexts: try c.decodeIfPresent([String: String].self, forKey: .contexts),
                withoutImages: try c.decodeIfPresent([String].self, forKey: .withoutImages)
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
        case .nativeThreadChanged(let agentID):
            try c.encode(Kind.nativeThreadChanged, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
        case .fleetDigest(let id, let result):
            try c.encode(Kind.fleetDigest, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .nativeThread(let id, let result):
            try c.encode(Kind.nativeThread, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .helloOk(let id, let protocolVersion, let capabilities, let hostBuild, let hostID):
            try c.encode(Kind.helloOk, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(protocolVersion, forKey: .protocolVersion)
            try c.encode(capabilities, forKey: .capabilities)
            try c.encodeIfPresent(hostBuild, forKey: .hostBuild)
            try c.encodeIfPresent(hostID, forKey: .hostID)
        case .fleetIdentity(let id, let hostID, let name, let build, let fleetEnabled):
            try c.encode(Kind.fleetIdentity, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(hostID, forKey: .hostID)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(build, forKey: .build)
            try c.encode(fleetEnabled, forKey: .fleetEnabled)
        case .fleetPaired(let id, let hostID, let name, let myTokenHash):
            try c.encode(Kind.fleetPaired, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(hostID, forKey: .hostID)
            try c.encode(name, forKey: .name)
            try c.encode(myTokenHash, forKey: .myTokenHash)
        case .fleetResult(let id, let result):
            try c.encode(Kind.fleetResult, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .fleetPressureSample(let id, let sample, let readiness):
            try c.encode(Kind.fleetPressureSample, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(sample, forKey: .sample)
            try c.encodeIfPresent(readiness, forKey: .readiness)
        case .fleetSyncReply(let id, let reply):
            try c.encode(Kind.fleetSyncReply, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(reply, forKey: .sync)
        case .fleetDevices(let id, let result):
            try c.encode(Kind.fleetDevices, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
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
        case .forgeResult(let id, let result):
            try c.encode(Kind.forgeResult, forKey: .type)
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
        case .hostUpdate(let id, let status):
            try c.encode(Kind.hostUpdate, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(status, forKey: .status)
        case .hostSettings(let id, let settings):
            try c.encode(Kind.hostSettings, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(settings, forKey: .settings)
        case .hostInventory(let id, let result):
            try c.encode(Kind.hostInventory, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .hostConfig(let id, let result):
            try c.encode(Kind.hostConfig, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .logicalProjectRuntime(let id, let result):
            try c.encode(Kind.logicalProjectRuntime, forKey: .type)
            try c.encode(id, forKey: .id); try c.encode(result, forKey: .result)
        case .projectExecution(let id, let result):
            try c.encode(Kind.projectExecution, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .projectExecutionChanged(let key, let revision):
            try c.encode(Kind.projectExecutionChanged, forKey: .type)
            try c.encode(key, forKey: .executionKey)
            try c.encode(revision, forKey: .executionRevision)
        case .logicalProjects(let id, let result):
            try c.encode(Kind.logicalProjects, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .projects(let id, let result):
            try c.encode(Kind.projects, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .skills(let id, let result):
            try c.encode(Kind.skills, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .hooks(let id, let result):
            try c.encode(Kind.hooks, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .apps(let id, let result):
            try c.encode(Kind.apps, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .design(let id, let result):
            try c.encode(Kind.design, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .designChanged(let designID, let revision, let commentsRevision):
            try c.encode(Kind.designChanged, forKey: .type)
            try c.encode(designID, forKey: .designID)
            try c.encodeIfPresent(revision, forKey: .revision)
            try c.encodeIfPresent(commentsRevision, forKey: .commentsRevision)
        case .designSystemsChanged:
            try c.encode(Kind.designSystemsChanged, forKey: .type)
        case .capabilitiesChanged(let capabilities):
            try c.encode(Kind.capabilitiesChanged, forKey: .type)
            try c.encode(capabilities, forKey: .capabilities)
        case .mission(let id, let result):
            try c.encode(Kind.mission, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .missionChanged(let missionID, let revision):
            try c.encode(Kind.missionChanged, forKey: .type)
            try c.encode(missionID, forKey: .missionID)
            try c.encodeIfPresent(revision, forKey: .revision)
        case .missionLive(let missionID, let live):
            try c.encode(Kind.missionLive, forKey: .type)
            try c.encode(missionID, forKey: .missionID)
            try c.encode(live, forKey: .live)
        case .tunnel(let frame):
            try c.encode(Kind.tunnel, forKey: .type)
            try c.encode(frame, forKey: .frame)
        case .browserClaimed(let id, let url):
            try c.encode(Kind.browserClaimed, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(url, forKey: .url)
        case .browserDrive(let push):
            try c.encode(Kind.browserDrive, forKey: .type)
            try c.encode(push, forKey: .push)
        case .designRelay(let token, let jobFile):
            try c.encode(Kind.designRelay, forKey: .type)
            try c.encode(token, forKey: .token)
            try c.encode(jobFile, forKey: .jobFile)
        case .appRelay(let token, let job):
            try c.encode(Kind.appRelay, forKey: .type)
            try c.encode(token, forKey: .token)
            try c.encode(job, forKey: .job)
        case .agentNotify(let agentID, let title, let body):
            try c.encode(Kind.agentNotify, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(title, forKey: .title)
            try c.encode(body, forKey: .body)
        case .settingsChanged(let page):
            try c.encode(Kind.settingsChanged, forKey: .type)
            try c.encode(page, forKey: .page)
        case .designNotesChanged(let designID):
            try c.encode(Kind.designNotesChanged, forKey: .type)
            try c.encode(designID, forKey: .designID)
        case .designGitChanged(let designID):
            try c.encode(Kind.designGitChanged, forKey: .type)
            try c.encode(designID, forKey: .designID)
        case .designImportProgress(let step):
            try c.encode(Kind.designImportProgress, forKey: .type)
            try c.encode(step, forKey: .status)
        case .toolFinished(let agentID, let tool):
            try c.encode(Kind.toolFinished, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(tool, forKey: .tool)
        case .threadNotice(let agentID, let message):
            try c.encode(Kind.threadNotice, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(message, forKey: .message)
        case .agentStartProblem(let agentID, let problem):
            try c.encode(Kind.agentStartProblem, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
            try c.encodeIfPresent(problem, forKey: .problem)
        case .automationsChanged:
            try c.encode(Kind.automationsChanged, forKey: .type)
        case .appsChanged(let processes):
            try c.encode(Kind.appsChanged, forKey: .type)
            try c.encode(processes, forKey: .processes)
        case .automationNotify(let title, let body):
            try c.encode(Kind.automationNotify, forKey: .type)
            try c.encode(title, forKey: .title)
            try c.encode(body, forKey: .body)
        case .pullRequestLinks(let links, let notes):
            try c.encode(Kind.pullRequestLinks, forKey: .type)
            try c.encode(links, forKey: .links)
            try c.encode(notes, forKey: .notes)
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
        case .models(let id, let models, let defaultModel, let withoutThinking, let thinkingLevels, let serviceTiers, let contexts, let withoutImages):
            try c.encode(Kind.models, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(models, forKey: .models)
            try c.encodeIfPresent(defaultModel, forKey: .defaultModel)
            try c.encodeIfPresent(withoutThinking, forKey: .withoutThinking)
            try c.encodeIfPresent(thinkingLevels, forKey: .thinkingLevels)
            try c.encodeIfPresent(serviceTiers, forKey: .serviceTiers)
            try c.encodeIfPresent(contexts, forKey: .contexts)
            try c.encodeIfPresent(withoutImages, forKey: .withoutImages)
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
