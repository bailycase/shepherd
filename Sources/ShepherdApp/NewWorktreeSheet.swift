import SwiftUI
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("New Worktree")
                    .font(Fonts.mono(13.5, .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                Text("Creates a git worktree beside \(space.name) on a new branch and starts an agent in it.")
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(Tokens.textSecondary)
            }
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 6, trailing: 20))

            VStack(spacing: 0) {
                SheetRow("branch") {
                    TextField("", text: $branch,
                              prompt: Text("branch name").foregroundStyle(Tokens.textDim))
                        .textFieldStyle(.plain)
                        .font(Fonts.mono(11.5))
                        .foregroundStyle(Tokens.textSecondary)
                        .focused($branchFocused)
                        .onSubmit(create)
                }
                SheetRow("base") {
                    HStack(spacing: 8) {
                        TextField("", text: $base,
                                  prompt: Text("resolving…").foregroundStyle(Tokens.textDim))
                            .textFieldStyle(.plain)
                            .font(Fonts.mono(11.5))
                            .foregroundStyle(Tokens.textSecondary)
                            .frame(maxWidth: 200)
                        Text(baseNote)
                            .font(Fonts.mono(10.5))
                            .foregroundStyle(Tokens.textDim)
                            .lineLimit(1)
                    }
                }
                SheetRow("checkout") {
                    Text(destination)
                        .font(Fonts.mono(11))
                        .foregroundStyle(Tokens.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.top, 6)

            HStack(spacing: 10) {
                Text(errorText ?? "")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.statusBlocked)
                    .lineLimit(2)
                Spacer(minLength: 12)
                Button("Cancel") { vm.worktreeSheetTarget = nil }
                    .keyboardShortcut(.cancelAction)
                Button(creating ? "Creating…" : "Create & Open") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.accentButton)
                    .disabled(creating || trimmedBranch.isEmpty || !baseResolved)
            }
            .padding(EdgeInsets(top: 12, leading: 20, bottom: 16, trailing: 20))
        }
        .frame(width: 520)
        .background(Tokens.workspaceBg)
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
        guard !creating, !trimmedBranch.isEmpty else { return }
        creating = true
        errorText = nil

        // Worktree first, synchronously: a failure (branch exists, bad base)
        // must surface in the sheet before any agent exists. The base field
        // is the start point — empty falls back to git's HEAD default.
        let trimmedBase = base.trimmingCharacters(in: .whitespaces)
        let path: String
        do {
            path = try GitWorktree.add(
                repo: space.path,
                branch: trimmedBranch,
                from: trimmedBase.isEmpty ? nil : trimmedBase
            )
        } catch {
            errorText = error.localizedDescription
            creating = false
            return
        }

        // The agent starts as the branch leaf ("calm-stone-3831") and is
        // retitled by the namer once it gets its first prompt — worktree
        // identity lives in `worktreeBranch`, not the name.
        let config = NewAgentConfig(
            spaceID: space.id,
            workingDirectory: path,
            model: vm.settings.agentDefaults.model,
            thinking: vm.settings.agentDefaults.thinking,
            initialPrompt: nil,
            initialName: (trimmedBranch as NSString).lastPathComponent,
            worktreeBranch: trimmedBranch,
            worktreeBase: trimmedBase.isEmpty ? nil : trimmedBase
        )
        Task {
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
