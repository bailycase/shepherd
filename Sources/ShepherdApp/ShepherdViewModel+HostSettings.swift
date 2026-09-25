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
                if case .change(let change) = request { HostSettingsMapping.apply(change, to: self.settings) }
                let settings = HostSettingsMapping.settings(
                    from: self.settings,
                    shepherdVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                    piVersion: PiUpdateManager.shared.currentVersion
                )
                Task.detached(priority: .userInitiated) {
                    // pi's settings.json is read off the main actor.
                    var answer = settings
                    answer.installedExtensions = PiConfig.installedExtensions()
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
        ("namer", "Name agents automatically", \.autoNameAgents),
        ("panes", "Panes and agent tools", \.piPanesExtension),
        ("review", "Diff review tool", \.piReviewExtension),
        ("nativeSubagents", "Native subagents", \.piNativeSubagents),
        ("subagents", "Subagent display", \.piSubagentsExtension),
    ]

    static func settings(from app: AppSettings, shepherdVersion: String?, piVersion: String?) -> HostSettings {
        HostSettings(
            shepherdVersion: shepherdVersion,
            piVersion: piVersion,
            defaultModel: app.defaultModel.isEmpty ? nil : app.defaultModel,
            defaultThinking: app.defaultThinking,
            queueDelivery: app.queueDelivery,
            worktreeBase: app.worktreeBaseMode == .head ? .head : .fresh,
            fetchBeforeCreating: app.worktreeFetchBeforeCreate,
            commitRemainingWork: app.worktreeAutoCommit,
            generatePRDescriptions: app.worktreeGeneratePRDescription,
            deleteLocalBranch: app.worktreeDeleteLocalBranch,
            mergePRAutomatically: app.worktreeAutoMergePR,
            mergeMethod: HostSettings.MergeMethod(rawValue: app.worktreeMergeMethod.rawValue) ?? .squash,
            bundledExtensions: bundled.map { HostSettings.BundledExtension(id: $0.id, name: $0.name, on: app[keyPath: $0.keyPath]) },
            updatePiDaily: app.autoUpdatePi,
            updateExtensionsDaily: app.autoUpdateExtensions
        )
    }

    static func apply(_ change: HostSettingChange, to app: AppSettings) {
        switch change {
        case .defaultModel(let model): app.defaultModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .defaultThinking(let level): app.defaultThinking = level
        case .queueDelivery(let mode): app.queueDelivery = mode
        case .worktreeBase(let base): app.worktreeBaseMode = base == .head ? .head : .fresh
        case .fetchBeforeCreating(let on): app.worktreeFetchBeforeCreate = on
        case .commitRemainingWork(let on): app.worktreeAutoCommit = on
        case .generatePRDescriptions(let on): app.worktreeGeneratePRDescription = on
        case .deleteLocalBranch(let on): app.worktreeDeleteLocalBranch = on
        case .mergePRAutomatically(let on): app.worktreeAutoMergePR = on
        case .mergeMethod(let method): app.worktreeMergeMethod = WorktreeMergeMethod(rawValue: method.rawValue) ?? .squash
        case .bundledExtension(let id, let on):
            guard let keyPath = bundled.first(where: { $0.id == id })?.keyPath else { return }
            app[keyPath: keyPath] = on
        case .updatePiDaily(let on):
            app.autoUpdatePi = on
            if on { PiUpdateManager.shared.applyAutoUpdateSetting() }
        case .updateExtensionsDaily(let on):
            app.autoUpdateExtensions = on
            if on { PiUpdateManager.shared.applyAutoUpdateSetting() }
        }
    }
}
