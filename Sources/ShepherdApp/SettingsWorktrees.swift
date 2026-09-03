import SwiftUI

// MARK: Worktrees

/// Settings ▸ Worktrees: how worktree agents are created and finalized.
/// Every automated behavior in the worktree flows is opt-out here — base
/// selection, the pre-create fetch, finalize's auto-commit, and local-branch
/// cleanup. The remote branch is never Shepherd's to delete regardless
/// (deleting an open PR's head branch closes the PR).
struct WorktreeSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsGroup(title: "New Worktrees") {
            SettingsRow(
                title: "Base Branch",
                subtitle: "What a new worktree branches from. \"Remote default\" starts clean from origin's default branch — unrelated work on your current checkout stays out of the PR. \"Current branch\" deliberately stacks on the checkout's in-progress work. The New Worktree sheet shows the resolved base and lets you override it either way.",
                isFirst: true
            ) {
                Picker("", selection: $settings.worktreeBaseMode) {
                    Text("Remote default").tag(WorktreeBaseMode.fresh)
                    Text("Current branch").tag(WorktreeBaseMode.head)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            SettingsRow(
                title: "Fetch Before Creating",
                subtitle: "Fetch the base branch from origin first, so \"remote default\" means the remote's latest — not a stale local snapshot. Off skips the network at creation and uses the cached ref."
            ) {
                Toggle("", isOn: $settings.worktreeFetchBeforeCreate)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }

        SettingsGroup(title: "Finalize") {
            SettingsRow(
                title: "Commit Remaining Work",
                subtitle: "Finalize commits anything left in the worktree automatically (using the PR title). Off stops the pipeline on a dirty worktree so you commit on your own terms.",
                isFirst: true
            ) {
                Toggle("", isOn: $settings.worktreeAutoCommit)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRow(
                title: "Generate PR Descriptions",
                subtitle: "Generate an editable pull request description from the branch's commits and diff. If generation fails, Finalize uses the commit subjects instead."
            ) {
                Toggle("", isOn: $settings.worktreeGeneratePRDescription)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRow(
                title: "Delete Local Branch",
                subtitle: "After the worktree is removed, delete its local branch too (everything is on the remote by then — finalize verifies that first). Off keeps the local branch around."
            ) {
                Toggle("", isOn: $settings.worktreeDeleteLocalBranch)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRow(
                title: "Merge PR Automatically",
                subtitle: "Merge the pull request finalize just created. GitHub auto-merge is tried first, so branch protection and required checks still gate the merge; a PR that can't be merged is left open and cleanup continues. Off (the default) leaves merging to you."
            ) {
                Toggle("", isOn: $settings.worktreeAutoMergePR)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            if settings.worktreeAutoMergePR {
                SettingsRow(
                    title: "Merge Method",
                    subtitle: "Must be allowed by the repository's settings."
                ) {
                    Picker("", selection: $settings.worktreeMergeMethod) {
                        Text("Squash").tag(WorktreeMergeMethod.squash)
                        Text("Merge").tag(WorktreeMergeMethod.merge)
                        Text("Rebase").tag(WorktreeMergeMethod.rebase)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
            }
        }
        SettingsNote(text: "the remote branch is never deleted — merging the PR cleans it up on GitHub · per-repo GitHub settings (auto-delete merged branches, allow auto-merge) live in the finalize sheet's repo setup view")
    }
}
