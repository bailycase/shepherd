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
        /// "namer", "theme", "panes", "review", "nativeSubagents", "subagents".
        public var id: String
        /// The Mac's row title: "Name agents automatically".
        public var name: String
        public var on: Bool

        public init(id: String, name: String, on: Bool) {
            self.id = id
            self.name = name
            self.on = on
        }
    }

    /// "0.4.2": the host's Shepherd.
    public var shepherdVersion: String?
    /// "0.87.1": the pi the host runs, once it has read it.
    public var piVersion: String?

    /// The model a new agent starts with; nil for pi's own default.
    public var defaultModel: String?
    public var defaultThinking: ThinkingLevel
    /// When a turn ends, the queue goes one message per turn or all at once.
    public var queueDelivery: NativeQueueMode

    public var worktreeBase: WorktreeBase
    public var fetchBeforeCreating: Bool
    public var commitRemainingWork: Bool
    public var generatePRDescriptions: Bool
    public var deleteLocalBranch: Bool
    public var mergePRAutomatically: Bool
    public var mergeMethod: MergeMethod

    public var bundledExtensions: [BundledExtension]
    /// The pi packages and extensions the host's pi loads from its own settings, as declared
    /// there ("npm:@example/pi-tools@1.0.0", "~/pi/checks.ts").
    public var installedExtensions: [String]
    public var updatePiDaily: Bool
    public var updateExtensionsDaily: Bool

    public init(shepherdVersion: String? = nil, piVersion: String? = nil,
                defaultModel: String? = nil, defaultThinking: ThinkingLevel = .medium, queueDelivery: NativeQueueMode = .all,
                worktreeBase: WorktreeBase = .fresh, fetchBeforeCreating: Bool = true, commitRemainingWork: Bool = true,
                generatePRDescriptions: Bool = true, deleteLocalBranch: Bool = true, mergePRAutomatically: Bool = false,
                mergeMethod: MergeMethod = .squash,
                bundledExtensions: [BundledExtension] = [], installedExtensions: [String] = [],
                updatePiDaily: Bool = false, updateExtensionsDaily: Bool = false) {
        self.shepherdVersion = shepherdVersion
        self.piVersion = piVersion
        self.defaultModel = defaultModel
        self.defaultThinking = defaultThinking
        self.queueDelivery = queueDelivery
        self.worktreeBase = worktreeBase
        self.fetchBeforeCreating = fetchBeforeCreating
        self.commitRemainingWork = commitRemainingWork
        self.generatePRDescriptions = generatePRDescriptions
        self.deleteLocalBranch = deleteLocalBranch
        self.mergePRAutomatically = mergePRAutomatically
        self.mergeMethod = mergeMethod
        self.bundledExtensions = bundledExtensions
        self.installedExtensions = installedExtensions
        self.updatePiDaily = updatePiDaily
        self.updateExtensionsDaily = updateExtensionsDaily
    }

    /// Applies one change, as the host does.
    public mutating func apply(_ change: HostSettingChange) {
        switch change {
        case .defaultModel(let model): defaultModel = model
        case .defaultThinking(let level): defaultThinking = level
        case .queueDelivery(let mode): queueDelivery = mode
        case .worktreeBase(let base): worktreeBase = base
        case .fetchBeforeCreating(let on): fetchBeforeCreating = on
        case .commitRemainingWork(let on): commitRemainingWork = on
        case .generatePRDescriptions(let on): generatePRDescriptions = on
        case .deleteLocalBranch(let on): deleteLocalBranch = on
        case .mergePRAutomatically(let on): mergePRAutomatically = on
        case .mergeMethod(let method): mergeMethod = method
        case .bundledExtension(let id, let on):
            if let index = bundledExtensions.firstIndex(where: { $0.id == id }) { bundledExtensions[index].on = on }
        case .updatePiDaily(let on): updatePiDaily = on
        case .updateExtensionsDaily(let on): updateExtensionsDaily = on
        }
    }
}

/// One setting a client changes on a host.
public enum HostSettingChange: Codable, Hashable, Sendable {
    /// nil for pi's own default.
    case defaultModel(String?)
    case defaultThinking(ThinkingLevel)
    case queueDelivery(NativeQueueMode)
    case worktreeBase(HostSettings.WorktreeBase)
    case fetchBeforeCreating(Bool)
    case commitRemainingWork(Bool)
    case generatePRDescriptions(Bool)
    case deleteLocalBranch(Bool)
    case mergePRAutomatically(Bool)
    case mergeMethod(HostSettings.MergeMethod)
    /// Turns a bundled extension (`HostSettings.BundledExtension.id`) on or off.
    case bundledExtension(id: String, on: Bool)
    case updatePiDaily(Bool)
    case updateExtensionsDaily(Bool)
}

/// Settings on a remote host (`RemoteProtocol.hostSettingsCapability`). Every request answers
/// with the host's settings as they are afterwards (`RemoteReply.hostSettings`).
public enum RemoteHostSettingsRequest: Codable, Hashable, Sendable {
    case fetch
    case change(HostSettingChange)
}
