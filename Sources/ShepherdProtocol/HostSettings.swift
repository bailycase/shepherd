import Foundation
import ShepherdCore

// A host's settings as a client shows and changes them (Settings on the iPhone and the iPad):
// what the Mac's Settings ▸ Agents, Worktrees and Pi set on that host, and what it runs. The
// host's GUI answers (`SessionServer.onRemoteHostSettings`); a headless host has none.

/// A host's settings (`RemoteRequest.hostSettings`, `RemoteProtocol.hostSettingsCapability`).
public struct HostSettings: Codable, Hashable, Sendable {
    /// What a new worktree branches from: the remote default branch, fetched first when
    /// `fetchBeforeCreating`, or the checkout's current branch.
    public enum WorktreeBase: String, Codable, Hashable, Sendable, CaseIterable {
        case fresh, head
    }

    /// How a finished worktree's pull request merges when it merges automatically.
    public enum MergeMethod: String, Codable, Hashable, Sendable, CaseIterable {
        case merge, squash, rebase
    }

    /// One of the pi extensions Shepherd bundles, as Settings ▸ Pi turns it on or off. Agents
    /// started afterwards follow a change.
    public struct BundledExtension: Codable, Hashable, Sendable, Identifiable {
        /// "panes", "review", "nativeSubagents", "subagents".
        public var id: String
        /// The Mac's row title: "Diff review tool".
        public var name: String
        public var on: Bool

        public init(id: String, name: String, on: Bool) {
            self.id = id
            self.name = name
            self.on = on
        }
    }

    /// Settings ▸ Subagents ▸ Defaults: what a subagent starts with unless its profile says.
    public struct SubagentDefaults: Codable, Hashable, Sendable {
        /// How subagents start: in a fresh context or forked from the parent's.
        public enum Context: String, Codable, Hashable, Sendable, CaseIterable {
            case fresh, fork
        }

        public static let concurrencyRange = 1...16

        /// How many run at once, in `concurrencyRange`.
        public var concurrency: Int
        /// "provider/id"; nil inherits the parent's.
        public var model: String?
        /// nil inherits the parent's.
        public var thinking: ThinkingLevel?
        public var context: Context

        public init(concurrency: Int = 4, model: String? = nil, thinking: ThinkingLevel? = nil, context: Context = .fresh) {
            self.concurrency = concurrency
            self.model = model
            self.thinking = thinking
            self.context = context
        }
    }

    /// Settings ▸ Worktrees ▸ Deleting a worktree agent: ask, or the delete the dialog remembered.
    public enum WorktreeDeleteAction: String, Codable, Hashable, Sendable, CaseIterable {
        case ask, keepWorktree, removeWorktree
    }

    /// "0.4.2": the host's Shepherd.
    public var shepherdVersion: String?
    /// "0.87.1": the pi the host runs, once it has read it.
    public var piVersion: String?

    /// The model a new agent starts with; nil for pi's own default.
    public var defaultModel: String?
    public var defaultThinking: ThinkingLevel
    /// Settings ▸ Agents ▸ Speed for new threads (`hostSettingsAgentDefaultsCapability`, with the
    /// two below). Older hosts omit it, which reads as Standard.
    public var defaultServiceTier: ServiceTier
    /// Settings ▸ Agents ▸ Text generation model; nil for Automatic.
    public var textGenerationModel: String?
    /// Settings ▸ Agents ▸ Image reading model; nil for Automatic. Older hosts omit it
    /// (`RemoteProtocol.hostSettingsVisionModelCapability`).
    public var visionModel: String?
    /// Settings ▸ Agents ▸ Compact at: a share of the model's window (`compactAtChoices`); nil
    /// for pi's own default.
    public var compactAtPercent: Int?
    /// The shares Compact at offers, as the Mac's Settings does.
    public static let compactAtChoices = [60, 70, 80, 90]
    /// When a turn ends, the queue goes one message per turn or all at once.
    public var queueDelivery: NativeQueueMode
    /// Legacy: goals no longer use a checker model. Kept so older peers still decode; hosts send false.
    public var goalCrossProviderEvaluation: Bool
    /// Settings ▸ Experiments ▸ Goals, default off, applied to running agents too.
    public var goalsEnabled: Bool
    /// Settings ▸ Experiments ▸ Projects, default off on each owner and executor.
    public var projectsEnabled: Bool
    /// Settings ▸ Experiments ▸ Fleet (`fleetExperimentCapability`), default off. Older hosts omit
    /// it, which reads as off.
    public var fleetEnabled: Bool

    public var worktreeBase: WorktreeBase
    public var fetchBeforeCreating: Bool
    /// Legacy: the removed Finalize's settings. Kept so older peers still decode; hosts send
    /// the defaults and ignore changes to them.
    public var commitRemainingWork: Bool
    /// Draft commit messages from review with a model.
    public var generatePRDescriptions: Bool
    /// Legacy, like `commitRemainingWork`.
    public var deleteLocalBranch: Bool
    /// Legacy, like `commitRemainingWork`.
    public var mergePRAutomatically: Bool
    /// Legacy, like `commitRemainingWork`.
    public var mergeMethod: MergeMethod
    /// Settings ▸ Worktrees ▸ Close threads when their pull request merges
    /// (`hostSettingsCloseOnMergeCapability`). Older hosts omit it, which reads as off.
    public var closeOnMerge: Bool
    /// Whether the Mac keeps its agents running when Shepherd is quit: true while its background
    /// service runs them, false while that is turned off in Login Items, nil where the Mac has no
    /// service or is older (`hostSettingsBackgroundServiceCapability`).
    public var backgroundService: Bool?
    /// Serve this Mac: the port the host's listener is bound to, nil when it isn't. Older hosts omit it.
    public var listenerPort: UInt16?
    /// Why the host's listener couldn't start: a sentence for Settings ▸ Fleet and the technical reason.
    public var listenerProblem: String?
    public var listenerProblemDetail: String?

    /// Settings ▸ Experiments ▸ Design tool (`designToolExperimentCapability`). Older hosts omit
    /// it, which reads as false.
    public var designToolEnabled: Bool
    /// Settings ▸ Experiments ▸ Missions (`missionsExperimentCapability`). Older hosts: false.
    public var missionsEnabled: Bool
    /// A mission is planning, running or publishing: the host refuses to turn Missions off.
    public var missionsActive: Bool

    /// The fields below need `hostSettingsV2Capability`; an older host omits them and they read
    /// as the Mac's own defaults.
    public var subagentDefaults: SubagentDefaults
    public var worktreeDeleteAction: WorktreeDeleteAction
    /// Settings ▸ Skills ▸ Skills in the / menu.
    public var skillsInSlashMenu: Bool
    /// Settings ▸ MCP servers ▸ Also use a repo's .mcp.json.
    public var mcpProjectConfig: Bool
    /// Every slash command a pi on the host has listed since its app started (Settings ▸ Slash
    /// commands), hidden or not.
    public var slashCommands: [NativeCommand]
    /// The names, without the slash, left out of the / menu.
    public var hiddenSlashCommands: [String]

    public var bundledExtensions: [BundledExtension]
    /// The pi packages and extensions the host's pi loads from its own settings, as declared
    /// there ("npm:@example/pi-tools@1.0.0", "~/pi/checks.ts").
    public var installedExtensions: [String]
    public var updatePiDaily: Bool
    public var updateExtensionsDaily: Bool

    /// The Fleet page's Send work here choice per Mac: the settings `fleet.weight.<hostID>`
    /// (`FleetSendWeight.settingKey`), keyed by that name. A Mac with no entry is Normal.
    public var fleetWeights: [String: FleetSendWeight]
    /// Settings ▸ Fleet ▸ Threads can send work: a thread may dispatch work to another Mac without being
    /// asked. The same on every Mac (a synced setting). Off until the person turns it on.
    public var fleetThreadsCanSend: Bool
    /// How many dispatches one thread may have in flight (`FleetDispatchState.countsAgainstCap`); more are held.
    public var fleetThreadCap: Int
    /// Settings ▸ Fleet ▸ Code ▸ Uncommitted changes: whether a dispatch carries the checkout's edits, new files and ignored files. Synced.
    public var fleetUncommitted: FleetUncommittedChanges
    /// Settings ▸ Fleet ▸ Code ▸ Ignored files ▸ Per space: what a space keeps home or sends against the defaults, under the setting
    /// keys `fleet.snapshotExcludes.<spaceID>` (`FleetSnapshotExcludes.settingKey`). Synced.
    public var fleetSnapshotExcludes: [String: FleetSnapshotExcludes]

    public static let fleetThreadCapDefault = 3
    public static let fleetThreadCapRange = 1...10

    public init(shepherdVersion: String? = nil, piVersion: String? = nil,
                defaultModel: String? = nil, defaultThinking: ThinkingLevel = .medium,
                defaultServiceTier: ServiceTier = .standard, textGenerationModel: String? = nil, visionModel: String? = nil, compactAtPercent: Int? = nil,
                queueDelivery: NativeQueueMode = .all,
                goalCrossProviderEvaluation: Bool = false, goalsEnabled: Bool = false, projectsEnabled: Bool = false, fleetEnabled: Bool = false,
                worktreeBase: WorktreeBase = .fresh, fetchBeforeCreating: Bool = true, commitRemainingWork: Bool = true,
                generatePRDescriptions: Bool = true, deleteLocalBranch: Bool = true, mergePRAutomatically: Bool = false,
                mergeMethod: MergeMethod = .squash, closeOnMerge: Bool = false, backgroundService: Bool? = nil,
                designToolEnabled: Bool = false, missionsEnabled: Bool = false, missionsActive: Bool = false,
                subagentDefaults: SubagentDefaults = SubagentDefaults(), worktreeDeleteAction: WorktreeDeleteAction = .ask,
                skillsInSlashMenu: Bool = true, mcpProjectConfig: Bool = false,
                slashCommands: [NativeCommand] = [], hiddenSlashCommands: [String] = [],
                bundledExtensions: [BundledExtension] = [], installedExtensions: [String] = [],
                updatePiDaily: Bool = false, updateExtensionsDaily: Bool = false,
                fleetWeights: [String: FleetSendWeight] = [:], fleetThreadsCanSend: Bool = false,
                fleetThreadCap: Int = HostSettings.fleetThreadCapDefault, fleetUncommitted: FleetUncommittedChanges = .sendThem,
                fleetSnapshotExcludes: [String: FleetSnapshotExcludes] = [:]) {
        self.shepherdVersion = shepherdVersion
        self.piVersion = piVersion
        self.defaultModel = defaultModel
        self.defaultThinking = defaultThinking
        self.defaultServiceTier = defaultServiceTier
        self.textGenerationModel = textGenerationModel
        self.visionModel = visionModel
        self.compactAtPercent = compactAtPercent
        self.queueDelivery = queueDelivery
        self.goalCrossProviderEvaluation = goalCrossProviderEvaluation
        self.goalsEnabled = goalsEnabled
        self.projectsEnabled = projectsEnabled
        self.fleetEnabled = fleetEnabled
        self.worktreeBase = worktreeBase
        self.fetchBeforeCreating = fetchBeforeCreating
        self.commitRemainingWork = commitRemainingWork
        self.generatePRDescriptions = generatePRDescriptions
        self.deleteLocalBranch = deleteLocalBranch
        self.mergePRAutomatically = mergePRAutomatically
        self.mergeMethod = mergeMethod
        self.closeOnMerge = closeOnMerge
        self.backgroundService = backgroundService
        self.designToolEnabled = designToolEnabled
        self.missionsEnabled = missionsEnabled
        self.missionsActive = missionsActive
        self.subagentDefaults = subagentDefaults
        self.worktreeDeleteAction = worktreeDeleteAction
        self.skillsInSlashMenu = skillsInSlashMenu
        self.mcpProjectConfig = mcpProjectConfig
        self.slashCommands = slashCommands
        self.hiddenSlashCommands = hiddenSlashCommands
        self.bundledExtensions = bundledExtensions
        self.installedExtensions = installedExtensions
        self.updatePiDaily = updatePiDaily
        self.updateExtensionsDaily = updateExtensionsDaily
        self.fleetWeights = fleetWeights
        self.fleetThreadsCanSend = fleetThreadsCanSend
        self.fleetThreadCap = Self.clampedThreadCap(fleetThreadCap)
        self.fleetUncommitted = fleetUncommitted
        self.fleetSnapshotExcludes = fleetSnapshotExcludes
    }

    public static func clampedThreadCap(_ cap: Int) -> Int { min(fleetThreadCapRange.upperBound, max(fleetThreadCapRange.lowerBound, cap)) }

    private enum CodingKeys: String, CodingKey {
        case shepherdVersion, piVersion, defaultModel, defaultThinking, defaultServiceTier, textGenerationModel, visionModel, compactAtPercent
        case queueDelivery, goalCrossProviderEvaluation, goalsEnabled, projectsEnabled, fleetEnabled
        case worktreeBase, fetchBeforeCreating, commitRemainingWork, generatePRDescriptions
        case deleteLocalBranch, mergePRAutomatically, mergeMethod, closeOnMerge, backgroundService, listenerPort, listenerProblem, listenerProblemDetail, bundledExtensions, installedExtensions
        case updatePiDaily, updateExtensionsDaily, fleetWeights, fleetThreadsCanSend, fleetThreadCap, fleetUncommitted, fleetSnapshotExcludes
        case designToolEnabled, missionsEnabled, missionsActive, subagentDefaults, worktreeDeleteAction
        case skillsInSlashMenu, mcpProjectConfig, slashCommands, hiddenSlashCommands
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shepherdVersion = try c.decodeIfPresent(String.self, forKey: .shepherdVersion)
        piVersion = try c.decodeIfPresent(String.self, forKey: .piVersion)
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        defaultThinking = try c.decode(ThinkingLevel.self, forKey: .defaultThinking)
        // A tier this client does not know reads as Standard.
        defaultServiceTier = (try? c.decodeIfPresent(ServiceTier.self, forKey: .defaultServiceTier)) ?? nil ?? .standard
        textGenerationModel = try c.decodeIfPresent(String.self, forKey: .textGenerationModel)
        visionModel = try c.decodeIfPresent(String.self, forKey: .visionModel)
        compactAtPercent = try c.decodeIfPresent(Int.self, forKey: .compactAtPercent)
        queueDelivery = try c.decode(NativeQueueMode.self, forKey: .queueDelivery)
        goalCrossProviderEvaluation = try c.decodeIfPresent(Bool.self, forKey: .goalCrossProviderEvaluation) ?? false
        goalsEnabled = try c.decodeIfPresent(Bool.self, forKey: .goalsEnabled) ?? false
        projectsEnabled = try c.decodeIfPresent(Bool.self, forKey: .projectsEnabled) ?? false
        fleetEnabled = try c.decodeIfPresent(Bool.self, forKey: .fleetEnabled) ?? false
        worktreeBase = try c.decode(WorktreeBase.self, forKey: .worktreeBase)
        fetchBeforeCreating = try c.decode(Bool.self, forKey: .fetchBeforeCreating)
        commitRemainingWork = try c.decodeIfPresent(Bool.self, forKey: .commitRemainingWork) ?? true
        generatePRDescriptions = try c.decode(Bool.self, forKey: .generatePRDescriptions)
        deleteLocalBranch = try c.decodeIfPresent(Bool.self, forKey: .deleteLocalBranch) ?? true
        mergePRAutomatically = try c.decodeIfPresent(Bool.self, forKey: .mergePRAutomatically) ?? false
        mergeMethod = (try? c.decodeIfPresent(MergeMethod.self, forKey: .mergeMethod)) ?? nil ?? .squash
        closeOnMerge = try c.decodeIfPresent(Bool.self, forKey: .closeOnMerge) ?? false
        backgroundService = try c.decodeIfPresent(Bool.self, forKey: .backgroundService)
        listenerPort = try c.decodeIfPresent(UInt16.self, forKey: .listenerPort)
        listenerProblem = try c.decodeIfPresent(String.self, forKey: .listenerProblem)
        listenerProblemDetail = try c.decodeIfPresent(String.self, forKey: .listenerProblemDetail)
        designToolEnabled = try c.decodeIfPresent(Bool.self, forKey: .designToolEnabled) ?? false
        missionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .missionsEnabled) ?? false
        missionsActive = try c.decodeIfPresent(Bool.self, forKey: .missionsActive) ?? false
        subagentDefaults = (try? c.decodeIfPresent(SubagentDefaults.self, forKey: .subagentDefaults)) ?? nil ?? SubagentDefaults()
        worktreeDeleteAction = (try? c.decodeIfPresent(WorktreeDeleteAction.self, forKey: .worktreeDeleteAction)) ?? nil ?? .ask
        skillsInSlashMenu = try c.decodeIfPresent(Bool.self, forKey: .skillsInSlashMenu) ?? true
        mcpProjectConfig = try c.decodeIfPresent(Bool.self, forKey: .mcpProjectConfig) ?? false
        slashCommands = try c.decodeIfPresent([NativeCommand].self, forKey: .slashCommands) ?? []
        hiddenSlashCommands = try c.decodeIfPresent([String].self, forKey: .hiddenSlashCommands) ?? []
        bundledExtensions = try c.decode([BundledExtension].self, forKey: .bundledExtensions)
        installedExtensions = try c.decode([String].self, forKey: .installedExtensions)
        updatePiDaily = try c.decode(Bool.self, forKey: .updatePiDaily)
        updateExtensionsDaily = try c.decode(Bool.self, forKey: .updateExtensionsDaily)
        // A weight this client doesn't know reads as Normal (it is left out).
        fleetWeights = ((try? c.decodeIfPresent([String: String].self, forKey: .fleetWeights)) ?? nil ?? [:])
            .compactMapValues(FleetSendWeight.init(rawValue:))
        fleetThreadsCanSend = (try? c.decodeIfPresent(Bool.self, forKey: .fleetThreadsCanSend)) ?? false
        fleetThreadCap = Self.clampedThreadCap((try? c.decodeIfPresent(Int.self, forKey: .fleetThreadCap)) ?? Self.fleetThreadCapDefault)
        fleetUncommitted = (try? c.decodeIfPresent(FleetUncommittedChanges.self, forKey: .fleetUncommitted)) ?? .sendThem
        fleetSnapshotExcludes = (try? c.decodeIfPresent([String: FleetSnapshotExcludes].self, forKey: .fleetSnapshotExcludes)) ?? [:]
    }

    /// Applies one change, as the host does.
    public mutating func apply(_ change: HostSettingChange) {
        switch change {
        case .defaultModel(let model): defaultModel = model
        case .defaultThinking(let level): defaultThinking = level
        case .defaultServiceTier(let tier): defaultServiceTier = tier
        case .textGenerationModel(let model), .namingModel(let model): textGenerationModel = model
        case .visionModel(let model): visionModel = model
        case .compactAtPercent(let percent): compactAtPercent = percent
        case .queueDelivery(let mode): queueDelivery = mode
        case .goalCrossProviderEvaluation(let on): goalCrossProviderEvaluation = on
        case .goalsEnabled(let on): goalsEnabled = on
        case .projectsEnabled(let on): projectsEnabled = on
        case .fleetEnabled(let on): fleetEnabled = on
        case .worktreeBase(let base): worktreeBase = base
        case .fetchBeforeCreating(let on): fetchBeforeCreating = on
        case .commitRemainingWork(let on): commitRemainingWork = on
        case .generatePRDescriptions(let on): generatePRDescriptions = on
        case .deleteLocalBranch(let on): deleteLocalBranch = on
        case .mergePRAutomatically(let on): mergePRAutomatically = on
        case .mergeMethod(let method): mergeMethod = method
        case .closeOnMerge(let on): closeOnMerge = on
        case .bundledExtension(let id, let on):
            if let index = bundledExtensions.firstIndex(where: { $0.id == id }) { bundledExtensions[index].on = on }
        case .updatePiDaily(let on): updatePiDaily = on
        case .updateExtensionsDaily(let on): updateExtensionsDaily = on
        case .fleetWeight(let hostID, let weight): fleetWeights[FleetSendWeight.settingKey(hostID: hostID)] = weight
        case .fleetThreadsCanSend(let on): fleetThreadsCanSend = on
        case .fleetThreadCap(let cap): fleetThreadCap = Self.clampedThreadCap(cap)
        case .fleetUncommitted(let choice): fleetUncommitted = choice
        case .fleetSnapshotExcludes(let spaceID, let excludes):
            let key = FleetSnapshotExcludes.settingKey(spaceID: spaceID)
            if excludes.isEmpty { fleetSnapshotExcludes[key] = nil } else { fleetSnapshotExcludes[key] = excludes }
        case .designToolEnabled(let on): designToolEnabled = on
        case .missionsEnabled(let on):
            // The host refuses Missions off under a live mission; a client shows that at once.
            if on || !missionsActive { missionsEnabled = on }
        case .subagentDefaults(var defaults):
            defaults.concurrency = min(SubagentDefaults.concurrencyRange.upperBound, max(SubagentDefaults.concurrencyRange.lowerBound, defaults.concurrency))
            subagentDefaults = defaults
        case .worktreeDeleteAction(let action): worktreeDeleteAction = action
        case .skillsInSlashMenu(let on): skillsInSlashMenu = on
        case .mcpProjectConfig(let on): mcpProjectConfig = on
        case .slashCommand(let name, let on):
            var hidden = Set(hiddenSlashCommands)
            if on { hidden.remove(name) } else { hidden.insert(name) }
            hiddenSlashCommands = hidden.sorted()
        }
    }
}

/// One setting a client changes on a host.
public enum HostSettingChange: Codable, Hashable, Sendable {
    /// nil for pi's own default.
    case defaultModel(String?)
    case defaultThinking(ThinkingLevel)
    /// The two below need `RemoteProtocol.hostSettingsAgentDefaultsCapability`; an older host
    /// refuses them as unknown.
    case defaultServiceTier(ServiceTier)
    /// The text generation model; nil for Automatic.
    /// `RemoteProtocol.hostSettingsTextGenerationModelCapability`.
    case textGenerationModel(String?)
    /// The image reading model; nil for Automatic.
    /// `RemoteProtocol.hostSettingsVisionModelCapability`.
    case visionModel(String?)
    /// Legacy: the same choice as an older client sends it, from when the setting was the session
    /// naming model. A host applies it to the text generation model; no client sends it now.
    case namingModel(String?)
    /// One of `HostSettings.compactAtChoices`, or nil for pi's own default.
    case compactAtPercent(Int?)
    case queueDelivery(NativeQueueMode)
    case goalCrossProviderEvaluation(Bool)
    case goalsEnabled(Bool)
    case projectsEnabled(Bool)
    /// `RemoteProtocol.fleetExperimentCapability`.
    case fleetEnabled(Bool)
    case worktreeBase(HostSettings.WorktreeBase)
    case fetchBeforeCreating(Bool)
    /// Legacy: older clients' Finalize settings. A host ignores `commitRemainingWork`,
    /// `deleteLocalBranch`, `mergePRAutomatically` and `mergeMethod`.
    case commitRemainingWork(Bool)
    case generatePRDescriptions(Bool)
    case deleteLocalBranch(Bool)
    case mergePRAutomatically(Bool)
    case mergeMethod(HostSettings.MergeMethod)
    /// `RemoteProtocol.hostSettingsCloseOnMergeCapability`.
    case closeOnMerge(Bool)
    /// Turns a bundled extension (`HostSettings.BundledExtension.id`) on or off.
    case bundledExtension(id: String, on: Bool)
    case updatePiDaily(Bool)
    case updateExtensionsDaily(Bool)
    /// How much auto placed work the Mac `hostID` gets (`RemoteProtocol.fleetViewCapability`: a device sets it too).
    case fleetWeight(hostID: UUID, weight: FleetSendWeight)
    /// Threads may send work to other Macs on their own (`RemoteProtocol.fleetDispatchCapability`).
    case fleetThreadsCanSend(Bool)
    /// How many dispatches one thread may have in flight (`RemoteProtocol.fleetDispatchCapability`).
    case fleetThreadCap(Int)
    /// Whether a dispatch carries the checkout's uncommitted changes (`RemoteProtocol.fleetSnapshotCapability`).
    case fleetUncommitted(FleetUncommittedChanges)
    /// What a space keeps home or sends against the defaults, by space id; empty is back to the defaults (`RemoteProtocol.fleetSnapshotCapability`).
    case fleetSnapshotExcludes(spaceID: String, excludes: FleetSnapshotExcludes)
    /// `RemoteProtocol.designToolExperimentCapability`: offered while the tool is off too.
    case designToolEnabled(Bool)
    /// `RemoteProtocol.missionsExperimentCapability`. Off is refused while a mission is active
    /// (`HostSettings.missionsActive`).
    case missionsEnabled(Bool)
    /// The cases below need `RemoteProtocol.hostSettingsV2Capability`.
    case subagentDefaults(HostSettings.SubagentDefaults)
    case worktreeDeleteAction(HostSettings.WorktreeDeleteAction)
    case skillsInSlashMenu(Bool)
    case mcpProjectConfig(Bool)
    /// Lists (`on`) or hides one slash command, by name without the slash.
    case slashCommand(name: String, on: Bool)

    /// The capability a host must advertise, beyond `hostSettingsCapability`, before the change is
    /// sent to it; nil when none.
    public var capability: String? {
        switch self {
        case .goalsEnabled: RemoteProtocol.goalExperimentCapability
        case .projectsEnabled: RemoteProtocol.projectsExperimentCapability
        case .fleetEnabled: RemoteProtocol.fleetExperimentCapability
        case .fleetWeight: RemoteProtocol.fleetViewCapability
        case .fleetThreadsCanSend, .fleetThreadCap: RemoteProtocol.fleetDispatchCapability
        case .fleetUncommitted, .fleetSnapshotExcludes: RemoteProtocol.fleetSnapshotCapability
        case .defaultServiceTier, .namingModel, .compactAtPercent: RemoteProtocol.hostSettingsAgentDefaultsCapability
        case .textGenerationModel: RemoteProtocol.hostSettingsTextGenerationModelCapability
        case .visionModel: RemoteProtocol.hostSettingsVisionModelCapability
        case .designToolEnabled: RemoteProtocol.designToolExperimentCapability
        case .missionsEnabled: RemoteProtocol.missionsExperimentCapability
        case .subagentDefaults, .worktreeDeleteAction, .skillsInSlashMenu, .mcpProjectConfig, .slashCommand:
            RemoteProtocol.hostSettingsV2Capability
        case .closeOnMerge: RemoteProtocol.hostSettingsCloseOnMergeCapability
        default: nil
        }
    }
}

/// Settings on a remote host (`RemoteProtocol.hostSettingsCapability`). Every request answers
/// with the host's settings as they are afterwards (`RemoteReply.hostSettings`).
public enum RemoteHostSettingsRequest: Codable, Hashable, Sendable {
    case fetch
    case change(HostSettingChange)
}
