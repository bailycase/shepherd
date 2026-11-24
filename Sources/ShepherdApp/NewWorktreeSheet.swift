import ShepherdSessions
import SwiftUI
import ShepherdUI
import ShepherdCore

/// The space context menu's "New Worktree…": create a git worktree of
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
    @State private var choosing = false
    /// The base came from the picker, so creating fetches it as the default is.
    @State private var picked = false
    @FocusState private var branchFocused: Bool

    private var trimmedBranch: String {
        branch.trimmingCharacters(in: .whitespaces)
    }

    private var destination: String {
        GitWorktree.destination(repo: space.path, branch: trimmedBranch.isEmpty ? "…" : trimmedBranch)
    }

    var body: some View {
        let sh = Color.sh
        let M = NewWorktreeSheetMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            Text("New worktree in \(space.name)")
                .font(.shSans(M.titleSize, .semibold))
                .foregroundStyle(sh.textPrimary)
                .frame(minHeight: M.titleLine, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Text("The new worktree starts this branch from the base.")
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textSecondary)
                .lineSpacing(M.messageLine - 18)
                .padding(.top, M.messageTop)
            SheetLabel("Branch name")
            SheetField {
                TextField("Branch name", text: $branch, prompt: Text("branch name").foregroundStyle(sh.textTertiary))
                    .textFieldStyle(.plain)
                    .font(.shMono(M.codeSize))
                    .focused($branchFocused)
                    .onSubmit(create)
            }
            SheetLabel("Base")
            SheetField {
                TextField("Base", text: $base, prompt: Text("resolving…").foregroundStyle(sh.textTertiary))
                    .textFieldStyle(.plain)
                    .font(.shMono(M.codeSize))
                Button { choosing = true } label: {
                    Image(systemName: "chevron.down").font(.system(size: M.chevron, weight: .medium)).foregroundStyle(sh.textSecondary)
                        .frame(width: M.chevronTarget, height: M.chevronTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(creating)
                .help("Choose the base branch")
                .accessibilityLabel("Choose base")
                .popover(isPresented: $choosing, arrowEdge: .bottom) {
                    WorktreeBasePicker(vm: vm, space: space.id, repo: space.path, selected: base.isEmpty ? nil : base) { branch in
                        base = branch
                        self.picked = true
                        baseNote = "chosen"
                        baseResolved = true
                        choosing = false
                    } close: { choosing = false }
                }
            }
            // What the base resolved from, and where the checkout will be.
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Text(baseNote)
                    .font(.sh(.caption))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                    .shContentTransition(.crossFade)
                Text(destination)
                    .font(.sh(.mono))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(destination)
                    .textSelection(.enabled)
                    .accessibilityLabel("Checkout \(destination)")
            }
            .padding(.top, SH.Space.m)
            .shComponentAnimation(.content, value: baseNote)
            if let errorText {
                DialogBanner(state: .failed, title: "Couldn't create the worktree", message: errorText)
                    .padding(.top, SH.Space.l)
            }
            HStack(spacing: M.footGap) {
                if creating { SHDialogStatus("Creating the worktree…") }
                Spacer(minLength: 0)
                Button("Cancel") { vm.worktreeSheetTarget = nil }
                    .buttonStyle(SheetActionStyle(pill: false))
                    .keyboardShortcut(.cancelAction)
                Button(creating ? "Creating…" : "Create") { create() }
                    .buttonStyle(SheetActionStyle(pill: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || trimmedBranch.isEmpty || !baseResolved)
            }
            .padding(.top, M.footTop)
        }
        .padding(M.padding)
        .frame(width: AppLayout.newWorktreeSheetWidth)
        .background(sh.bgRaised)
        // Creating… shows in the footer and the button; a failure discloses as a banner.
        .shAnimation(.content, value: creating)
        .shAnimation(.disclosure, value: errorText)
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
        let projectBase = vm.state.spaces.first { $0.id == space.id }?.worktreeBase
        let resolution = await Task.detached(priority: .userInitiated) {
            GitWorktree.resolveBase(repo: repo, mode: mode, fetchFirst: fetchFirst, projectBase: projectBase)
        }.value
        // A branch the user chose (or typed) while this resolved keeps its own note.
        if base.isEmpty {
            base = resolution.display
            baseNote = resolution.note
        }
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
        let fetchPicked = picked && vm.settings.worktreeFetchBeforeCreate

        Task {
            // Worktree first, off the main thread: a failure (branch exists, bad base) must
            // surface in the sheet before any agent exists.
            let path: String
            do {
                path = try await Task.detached(priority: .userInitiated) {
                    GitWorktree.fetchPicked(repo: repo, base: trimmedBase, fetchFirst: fetchPicked)
                    return try GitWorktree.add(repo: repo, branch: branch, from: trimmedBase.isEmpty ? nil : trimmedBase)
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
                model: vm.settings.defaultModel(piHome: vm.pi.home),
                thinking: vm.settings.agentDefaults.thinking,
                initialPrompt: nil,
                initialName: (branch as NSString).lastPathComponent,
                worktreeBranch: branch,
                worktreeBase: trimmedBase.isEmpty ? nil : trimmedBase,
                // The checkout made above: the host starts the thread in it rather than making another.
                worktreePath: path
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

/// The sheet's measures (GXNewWorktree): a 480pt card with 18pt over 20pt of padding, its title in 15 semibold, fields 32pt tall.
private enum NewWorktreeSheetMetrics {
    static let padding = EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20)
    static let titleSize: CGFloat = 15
    static let titleLine: CGFloat = 20
    static let messageTop: CGFloat = SH.Space.s
    static let messageLine: CGFloat = 19
    static let labelTop: CGFloat = 14
    static let fieldHeight: CGFloat = 32
    static let fieldPadding: CGFloat = 10
    static let codeSize: CGFloat = 12.5
    static let chevron: CGFloat = 10
    static let chevronTarget: CGFloat = 24
    static let footTop: CGFloat = 18
    static let footGap: CGFloat = 18
    static let pillHeight: CGFloat = 26
    static let pillPadding: CGFloat = 11
}

/// A label over a field: 12pt in `textSecondary`, 14pt below the last thing and 6pt over the field.
private struct SheetLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
            .padding(.top, NewWorktreeSheetMetrics.labelTop)
            .padding(.bottom, SH.Space.s)
    }
}

/// A bordered field: 32pt tall, the line, radius 8.
private struct SheetField<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: SH.Space.m) { content }
            .padding(.horizontal, NewWorktreeSheetMetrics.fieldPadding)
            .frame(maxWidth: .infinity, minHeight: NewWorktreeSheetMetrics.fieldHeight, alignment: .leading)
            .overlay { RoundedRectangle(cornerRadius: SH.Radius.m).strokeBorder(Color.sh.lineSubtle, lineWidth: 1) }
    }
}

/// A foot action: "Cancel" as a word in `textSecondary`, or the ink pill.
private struct SheetActionStyle: ButtonStyle {
    let pill: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let sh = Color.sh
        let M = NewWorktreeSheetMetrics.self
        if pill {
            configuration.label
                .font(.sh(.caption, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(sh.textOnPrimary)
                .padding(.horizontal, M.pillPadding)
                .frame(height: M.pillHeight)
                .background(configuration.isPressed ? sh.primaryPressed : sh.primary, in: Capsule())
                .contentShape(Capsule())
                .shEnabledOpacity(enabled)
                .shFocusRing(radius: M.pillHeight / 2)
        } else {
            configuration.label
                .font(.sh(.ui, weight: .regular))
                .lineLimit(1)
                .foregroundStyle(sh.textSecondary)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .shFocusRing(radius: SH.Radius.xs)
        }
    }
}
