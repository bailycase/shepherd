import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

extension ShepherdViewModel {
    /// Serves this Mac's settings to remote clients (Settings on the iPhone and the iPad): what
    /// Settings ▸ Agents, Worktrees and Pi set, and one change at a time, applied as the Mac's own
    /// Settings would. Installed once at startup.
    func installHostSettings() {
        server.onRemoteHostSettings = { [weak self] request, completion in
            MainActor.assumeIsolated {
                guard let self else {
                    completion(.failure(RemoteCreateAgentError("Host is shutting down")))
                    return
                }
                let missionsActive = self.state.missions.contains { $0.run?.phase.active == true }
                if case .change(let change) = request,
                   let refusal = HostSettingsMapping.apply(change, to: self.settings, missionsActive: missionsActive) {
                    completion(.failure(RemoteCreateAgentError(refusal)))
                    return
                }
                let settings = HostSettingsMapping.settings(
                    from: self.settings,
                    shepherdVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                    piVersion: self.server.pi.engine.version,
                    missionsActive: missionsActive,
                    slashCommands: self.server.slashCommandCatalog
                )
                let piHome = self.server.pi.home
                Task.detached(priority: .userInitiated) {
                    // pi's settings.json is read off the main actor.
                    var answer = settings
                    answer.installedExtensions = PiConfig.installedExtensions(in: piHome)
                    completion(.success(answer))
                }
            }
        }
    }
}

/// This Mac's `AppSettings` as a remote client sees them (`HostSettings`), and a client's change
/// applied to them.
@MainActor
enum HostSettingsMapping {
    /// The bundled extensions a client may turn on or off, in Settings ▸ Pi's order.
    static let bundled: [(id: String, name: String, keyPath: ReferenceWritableKeyPath<AppSettings, Bool>)] = [
        ("panes", "Terminals and agent tools", \.piPanesExtension),
        ("review", "Diff review tool", \.piReviewExtension),
        ("nativeSubagents", "Native subagents", \.piNativeSubagents),
        ("subagents", "Subagent display", \.subagentDisplay),
        ("mcp", "MCP servers", \.piMCPExtension),
        ("browser", "Browser tools", \.piBrowserExtension),
        // Settings ▸ Extensions shows it only while the Design tool is on; a client lists it always.
        ("designReferences", "Design references", \.piDesignReferences),
        // Settings ▸ Agents ▸ Context on the Mac; a client lists it with the other switches.
        ("context", "Trim old tool output from the model's context", \.trimToolOutput),
        ("deferTools", "Defer rarely used tools", \.deferTools),
        ("codemode", "Codemode", \.codemode),
    ]

    /// Why a client may not turn Missions off now.
    static let missionsLocked = "Pause or stop running missions before turning Missions off."

    static func settings(from app: AppSettings, shepherdVersion: String?, piVersion: String?,
                         missionsActive: Bool = false, slashCommands: [NativeCommand] = []) -> HostSettings {
        HostSettings(
            shepherdVersion: shepherdVersion,
            piVersion: piVersion,
            defaultModel: app.defaultModel.isEmpty ? nil : app.defaultModel,
            defaultThinking: app.defaultThinking,
            defaultServiceTier: app.defaultServiceTier,
            namingModel: app.namingModel.isEmpty ? nil : app.namingModel,
            compactAtPercent: app.compactAtPercent,
            queueDelivery: app.queueDelivery,
            goalCrossProviderEvaluation: app.goalCrossProviderEvaluation,
            goalsEnabled: app.goalsEnabled,
            projectsEnabled: app.projectsEnabled,
            worktreeBase: app.worktreeBaseMode == .head ? .head : .fresh,
            fetchBeforeCreating: app.worktreeFetchBeforeCreate,
            commitRemainingWork: app.worktreeAutoCommit,
            generatePRDescriptions: app.worktreeGeneratePRDescription,
            deleteLocalBranch: app.worktreeDeleteLocalBranch,
            mergePRAutomatically: app.worktreeAutoMergePR,
            mergeMethod: HostSettings.MergeMethod(rawValue: app.worktreeMergeMethod.rawValue) ?? .squash,
            designToolEnabled: app.designToolEnabled,
            missionsEnabled: app.missionsEnabled,
            missionsActive: missionsActive,
            subagentDefaults: HostSettings.SubagentDefaults(
                concurrency: app.childConcurrency,
                model: app.childModel.isEmpty ? nil : app.childModel,
                thinking: ThinkingLevel(rawValue: app.childThinking),
                context: HostSettings.SubagentDefaults.Context(rawValue: app.childContext) ?? .fresh),
            worktreeDeleteAction: HostSettings.WorktreeDeleteAction(rawValue: app.worktreeDeleteAction.rawValue) ?? .ask,
            skillsInSlashMenu: app.skillsInSlashMenu,
            mcpProjectConfig: app.mcpProjectConfig,
            slashCommands: slashCommands,
            hiddenSlashCommands: app.hiddenSlashCommands.sorted(),
            // Shepherd's pi updates with Shepherd: nothing runs `pi update` any more.
            bundledExtensions: bundled.map { HostSettings.BundledExtension(id: $0.id, name: $0.name, on: app[keyPath: $0.keyPath]) },
            updatePiDaily: false,
            updateExtensionsDaily: false
        )
    }

    /// Applies `change` as the Mac's own Settings would; returns why it was refused, or nil.
    @discardableResult
    static func apply(_ change: HostSettingChange, to app: AppSettings, missionsActive: Bool = false) -> String? {
        switch change {
        case .defaultModel(let model): app.defaultModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .defaultThinking(let level): app.defaultThinking = level
        case .defaultServiceTier(let tier): app.defaultServiceTier = tier
        case .namingModel(let model): app.namingModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .compactAtPercent(let percent):
            // A share Settings does not offer is left as it is, as the Mac's own loader does.
            guard percent == nil || PiCompactionThreshold.choices.contains(percent!) else { return nil }
            app.compactAtPercent = percent
        case .queueDelivery(let mode): app.queueDelivery = mode
        case .goalCrossProviderEvaluation(let on): app.goalCrossProviderEvaluation = on
        case .goalsEnabled(let on): app.goalsEnabled = on
        case .projectsEnabled(let on): app.projectsEnabled = on
        case .worktreeBase(let base): app.worktreeBaseMode = base == .head ? .head : .fresh
        case .fetchBeforeCreating(let on): app.worktreeFetchBeforeCreate = on
        case .commitRemainingWork(let on): app.worktreeAutoCommit = on
        case .generatePRDescriptions(let on): app.worktreeGeneratePRDescription = on
        case .deleteLocalBranch(let on): app.worktreeDeleteLocalBranch = on
        case .mergePRAutomatically(let on): app.worktreeAutoMergePR = on
        case .mergeMethod(let method): app.worktreeMergeMethod = WorktreeMergeMethod(rawValue: method.rawValue) ?? .squash
        case .bundledExtension(let id, let on):
            guard let keyPath = bundled.first(where: { $0.id == id })?.keyPath else { return nil }
            app[keyPath: keyPath] = on
        case .updatePiDaily, .updateExtensionsDaily:
            // An older client's switches: Shepherd's pi updates only with Shepherd.
            break
        case .designToolEnabled(let on): app.designToolEnabled = on
        case .missionsEnabled(let on):
            // The Mac's card locks the switch under a live mission; a client is refused the same.
            if !on, app.missionsEnabled, missionsActive { return missionsLocked }
            app.missionsEnabled = on
        case .subagentDefaults(let defaults):
            let range = HostSettings.SubagentDefaults.concurrencyRange
            app.childConcurrency = min(range.upperBound, max(range.lowerBound, defaults.concurrency))
            app.childModel = defaults.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            app.childThinking = defaults.thinking?.rawValue ?? ""
            app.childContext = defaults.context.rawValue
        case .worktreeDeleteAction(let action): app.worktreeDeleteAction = WorktreeDeleteAction(rawValue: action.rawValue) ?? .ask
        case .skillsInSlashMenu(let on): app.skillsInSlashMenu = on
        case .mcpProjectConfig(let on): app.mcpProjectConfig = on
        case .slashCommand(let name, let on):
            guard !name.isEmpty, name.utf8.count <= NativeCommand.maxNameBytes else { return "Not a slash command." }
            app.setSlashCommand(name, on: on)
        }
        return nil
    }
}
