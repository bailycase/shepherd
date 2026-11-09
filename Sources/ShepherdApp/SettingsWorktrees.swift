import ShepherdSessions
import SwiftUI
import ShepherdUI

// MARK: Worktrees

/// Settings ▸ Worktrees: how worktree agents are created, commit and are deleted. Every automated
/// behavior in the worktree flows is opt-out here. Only closing a merged pull request's thread
/// deletes a branch on GitHub.
struct WorktreeSettings: View {
    @Bindable var settings: AppSettings

    /// Tests pass their own isolated settings.
    init(settings: AppSettings? = nil) {
        self.settings = settings ?? .shared
    }

    var body: some View {
        SettingsPage(title: "Worktrees",
                     explanation: "How new worktrees are created, and what happens when an agent's work is done.") {
            SettingsGroup(title: "New worktrees") {
                SettingsRow(title: "Base branch",
                            subtitle: "**Remote default** starts clean from origin's default branch. **Current branch** stacks on your checkout's in-progress work. The New Worktree sheet lets you override it.") {
                    SHSegmentedPicker("Base branch", selection: $settings.worktreeBaseMode,
                                      options: [(WorktreeBaseMode.fresh, "Remote default"), (.head, "Current branch")])
                }
                SettingsRow(title: "Fetch before creating",
                            subtitle: "Fetch the base branch first so “remote default” is the remote's latest, not a stale local ref.") {
                    SettingsSwitch(label: "Fetch before creating", isOn: $settings.worktreeFetchBeforeCreate)
                }
            }
            SettingsGroup(title: "Commits") {
                SettingsRow(title: "Draft commit messages",
                            subtitle: "Commit from review drafts an editable message from the diff. Off writes it from the file list.") {
                    SettingsSwitch(label: "Draft commit messages", isOn: $settings.worktreeGeneratePRDescription)
                }
            }
            SettingsGroup(title: "Delete") {
                SettingsRow(title: "Deleting a worktree agent",
                            subtitle: "**Ask** shows the confirmation. A remembered removal still asks when the checkout has unreconciled work.") {
                    SHSegmentedPicker("Deleting a worktree agent", selection: $settings.worktreeDeleteAction,
                                      options: [(WorktreeDeleteAction.ask, "Ask"), (.keepWorktree, "Keep worktree"), (.removeWorktree, "Remove worktree")])
                }
                SettingsRow(title: "Close threads when their pull request merges",
                            subtitle: "Deletes the thread, its worktree and its branch, here and on GitHub. A thread that is running, asking, or holds uncommitted or unpushed work stays open with a note.") {
                    SettingsSwitch(label: "Close threads when their pull request merges", isOn: $settings.worktreeCloseOnMerge)
                }
            }
        }
    }
}
