import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

extension AppSettings {
    /// Settings ▸ Worktrees, as the worktree queries read them (here and in the headless host).
    var worktreeHostingDefaults: WorktreeHosting.Defaults {
        WorktreeHosting.Defaults(generateDescription: worktreeGeneratePRDescription)
    }
}
