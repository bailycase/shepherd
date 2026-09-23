import SwiftUI
import ShepherdUI
import ShepherdCore

/// The space context menu's "New Worktree…": create a git worktree beside
/// the checkout on a fresh branch and immediately open an agent on it. The
/// agent starts wearing the branch's leaf name; pi's namer retitles it from
/// the first prompt (the ⎇ treatment and tooltip keep the branch identity).
/// Cleanup is the confirmed Delete Worktree Agent dialog — or the user's own
/// `git worktree remove`; nothing else touches the checkout.
struct NewWorktreeSheet: View {
    var vm: ShepherdViewModel
    let space: Space

    @State private var branch = GitWorktree.generatedBranch()
    /// The start point the worktree branches from. Resolved per Settings ▸
    /// Worktrees on appear, visible and editable — a silently inherited base
    /// is how unrelated work ends up in a PR.
    @State private var base = ""
    @State private var baseNote = "resolving…"
    @State private var baseResolved = false
    @State private var errorText: String?
    @State private var creating = false
    @FocusState private var branchFocused: Bool

    private var trimmedBranch: String {
        branch.trimmingCharacters(in: .whitespaces)
    }

    private var destination: String {
        GitWorktree.destination(repo: space.path, branch: trimmedBranch.isEmpty ? "…" : trimmedBranch)
    }

    var body: some View {
        NWDialog("New worktree",
                 message: "Creates a git worktree beside \(space.name) on a new branch and starts an agent in it.",
                 width: AppLayout.newWorktreeSheetWidth) {
            SheetRow("Branch") {
                TextField("Branch", text: $branch, prompt: Text("branch name").foregroundStyle(Color.nw.textTertiary))
                    .focused($branchFocused)
                    .nwField(focused: branchFocused, mono: true)
                    .onSubmit(create)
            }
            SheetRow("Base") {
                HStack(spacing: NW.Space.m) {
                    TextField("Base", text: $base, prompt: Text("resolving…").foregroundStyle(Color.nw.textTertiary))
                        .textFieldStyle(.nw(mono: true))
                        .frame(maxWidth: AppLayout.baseFieldMaxWidth)
                    Text(baseNote)
                        .font(.nw(.caption))
                        .foregroundStyle(Color.nw.textTertiary)
                        .lineLimit(1)
                        .nwContentTransition(.crossFade)
                }
                .nwComponentAnimation(.content, value: baseNote)
            }
            SheetRow("Checkout") {
                Text(destination)
                    .font(.nw(.mono))
                    .foregroundStyle(Color.nw.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(destination)
                    .textSelection(.enabled)
            }
            if let errorText {
                DialogBanner(state: .failed, title: "Couldn't create the worktree", message: errorText)
            }
        } status: {
            if creating { NWDialogStatus("Creating the worktree…") }
        } actions: {
            Button("Cancel") { vm.worktreeSheetTarget = nil }
                .buttonStyle(.nw(.secondary))
                .keyboardShortcut(.cancelAction)
            Button(creating ? "Creating…" : "Create and open") { create() }
                .buttonStyle(.nw(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(creating || trimmedBranch.isEmpty || !baseResolved)
        }
        // Creating… shows in the footer and the button; a failure discloses as a banner.
        .nwAnimation(.content, value: creating)
        .nwAnimation(.disclosure, value: errorText)
        .onAppear { branchFocused = true }
        .task { await resolveBase() }
    }

    /// Resolve off-main: `fresh` may fetch from origin. ponytail: no fetch
    /// timeout — an unreachable host can stall the note until TCP gives up;
    /// add a cap if it ever bites. Creation is disabled until resolution so
    /// a fast ⏎ cannot silently branch from HEAD.
    private func resolveBase() async {
        let repo = space.path
        let mode = vm.settings.worktreeBaseMode
        let fetchFirst = vm.settings.worktreeFetchBeforeCreate
        let resolution = await Task.detached(priority: .userInitiated) {
            GitWorktree.resolveBase(repo: repo, mode: mode, fetchFirst: fetchFirst)
        }.value
        if base.isEmpty { base = resolution.display }
        baseNote = resolution.note
        baseResolved = true
    }

    private func create() {
        guard !creating, baseResolved, !trimmedBranch.isEmpty else { return }
        creating = true
        errorText = nil
        let repo = space.path
        let branch = trimmedBranch
        // The base field is the start point — empty falls back to git's HEAD default.
        let trimmedBase = base.trimmingCharacters(in: .whitespaces)

        Task {
            // Worktree first, off the main thread: a failure (branch exists, bad base) must
            // surface in the sheet before any agent exists.
            let path: String
            do {
                path = try await Task.detached(priority: .userInitiated) {
                    try GitWorktree.add(repo: repo, branch: branch, from: trimmedBase.isEmpty ? nil : trimmedBase)
                }.value
            } catch {
                errorText = error.localizedDescription
                creating = false
                return
            }

            // The agent starts as the branch leaf ("calm-stone-3831") and is retitled by the
            // namer once it gets its first prompt — worktree identity lives in
            // `worktreeBranch`, not the name.
            let config = NewAgentConfig(
                spaceID: space.id,
                workingDirectory: path,
                model: vm.settings.agentDefaults.model,
                thinking: vm.settings.agentDefaults.thinking,
                initialPrompt: nil,
                initialName: (branch as NSString).lastPathComponent,
                worktreeBranch: branch,
                worktreeBase: trimmedBase.isEmpty ? nil : trimmedBase
            )
            do {
                try await vm.startAgent(config)
                vm.worktreeSheetTarget = nil
            } catch {
                errorText = "\(error)"
                creating = false
            }
        }
    }
}
