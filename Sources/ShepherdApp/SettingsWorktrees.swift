import SwiftUI
import ShepherdDesign

// MARK: Worktrees

/// Settings ▸ Worktrees: how worktree agents are created and finalized. Every automated
/// behavior in the worktree flows is opt-out here. The remote branch is never Shepherd's to
/// delete regardless (deleting an open PR's head branch closes the PR).
struct WorktreeSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsPage(title: "Worktrees",
                     explanation: "How new worktrees are created, and what Finalize does when an agent's work is done.") {
            SettingsGroup(title: "New worktrees") {
                SettingsRow(title: "Base branch",
                            subtitle: "Remote default starts clean from origin's default branch. Current branch stacks on your checkout's in-progress work. The New Worktree sheet lets you override it.") {
                    SegmentedControl(selection: $settings.worktreeBaseMode,
                                     options: [(WorktreeBaseMode.fresh, "Remote default"), (.head, "Current branch")])
                }
                SettingsRow(title: "Fetch before creating",
                            subtitle: "Fetch the base branch first so “remote default” is the remote's latest, not a stale local ref.") {
                    SettingsSwitch(label: "Fetch before creating", isOn: $settings.worktreeFetchBeforeCreate)
                }
            }
            SettingsGroup(title: "Finalize",
                          footnote: "The remote branch is never deleted by Shepherd — merging the PR cleans it up on GitHub. Per-repo GitHub settings live in the Finalize sheet.") {
                SettingsRow(title: "Commit remaining work",
                            subtitle: "Commits anything left in the worktree using the PR title. Off stops Finalize on a dirty worktree.") {
                    SettingsSwitch(label: "Commit remaining work", isOn: $settings.worktreeAutoCommit)
                }
                SettingsRow(title: "Generate PR descriptions",
                            subtitle: "Drafts an editable description from the branch's commits and diff; falls back to commit subjects.") {
                    SettingsSwitch(label: "Generate PR descriptions", isOn: $settings.worktreeGeneratePRDescription)
                }
                SettingsRow(title: "Delete local branch",
                            subtitle: "After the worktree is removed, once Finalize has verified everything is on the remote.") {
                    SettingsSwitch(label: "Delete local branch", isOn: $settings.worktreeDeleteLocalBranch)
                }
                SettingsRow(title: "Merge PR automatically",
                            subtitle: "Tries GitHub auto-merge, so branch protection and required checks still gate it. A PR that can't merge is left open.") {
                    SettingsSwitch(label: "Merge PR automatically", isOn: $settings.worktreeAutoMergePR)
                }
                if settings.worktreeAutoMergePR {
                    SettingsRow(title: "Merge method", subtitle: "Must be allowed by the repository's settings.") {
                        SegmentedControl(selection: $settings.worktreeMergeMethod,
                                         options: [(WorktreeMergeMethod.squash, "Squash"), (.merge, "Merge"), (.rebase, "Rebase")])
                    }
                }
            }
        }
    }
}
