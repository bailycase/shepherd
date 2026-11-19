import ShepherdSessions
import SwiftUI
import ShepherdUI

// MARK: Worktrees

/// Settings ▸ Git: how worktree agents are created, commit and are deleted. Every automated
/// behavior in the worktree flows is opt-out here. Only closing a merged pull request's thread
/// deletes a branch on GitHub.
struct WorktreeSettings: View {
    @Bindable var settings: AppSettings

    /// Tests pass their own isolated settings.
    init(settings: AppSettings? = nil) {
        self.settings = settings ?? .shared
    }

    var body: some View {
        SettingsPage(title: "Git") {
            SettingsGroup(title: "New worktrees") {
                SettingsRow(title: "Branch from") {
                    SHSegmentedPicker("Base branch", selection: $settings.worktreeBaseMode,
                                      options: [(WorktreeBaseMode.fresh, "Remote default"), (.head, "Current branch")])
                }
                SettingsRow(title: "Fetch first", subtitle: "So remote default is the latest") {
                    SettingsSwitch(label: "Fetch before creating", isOn: $settings.worktreeFetchBeforeCreate)
                }
            }
            SettingsGroup(title: "When work is done") {
                SettingsRow(title: "Draft commit messages", subtitle: "Off writes them from the file list") {
                    SettingsSwitch(label: "Draft commit messages", isOn: $settings.worktreeGeneratePRDescription)
                }
                SettingsRow(title: "Close the thread when its PR merges", subtitle: "Deletes its worktree and branch") {
                    SettingsSwitch(label: "Close threads when their pull request merges", isOn: $settings.worktreeCloseOnMerge)
                }
            }
            SettingsGroup(title: "Deleting a worktree agent") {
                SettingsRow(title: "Worktree", subtitle: "Ask still asks when work isn’t saved") {
                    SHSegmentedPicker("Deleting a worktree agent", selection: $settings.worktreeDeleteAction,
                                      options: [(WorktreeDeleteAction.ask, "Ask"), (.keepWorktree, "Keep"), (.removeWorktree, "Remove")])
                }
            }
        }
    }
}
