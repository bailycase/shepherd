import SwiftUI
import ShepherdUI
import AppKit
import ShepherdCore

/// "Finalize Worktree…" on a worktree agent: the whole commit → push → PR →
/// cleanup pipeline inside one sheet. Phases:
///   checking → (setup wizard when prerequisites fail) → input → running →
///   done / failed
/// The setup phase is the guided wizard: each missing prerequisite shows an
/// in-app remedy, and re-running the checks is the visual verification that
/// everything is green before the feature unlocks.
struct FinalizeWorktreeSheet: View {
    var vm: ShepherdViewModel
    let agent: Agent
    let space: Space

    @State private var setup: WorktreeSetupModel
    @State private var finalizer = WorktreeFinalizer()
    @State private var descriptionGenerator = WorktreePRDescriptionGenerator()
    @State private var phase: Phase = .checking
    @State private var base = ""
    @State private var title = ""
    @State private var prBody = ""
    @State private var descriptionPrepared = false
    @State private var generatingDescription = false
    /// `rev-list --count <base>..HEAD` — the last-chance tripwire for a
    /// wrong base: an inflated count means the PR would include work that
    /// is not this worktree's.
    @State private var includedCommits: Int?
    /// Why Finalize could not start (another operation holds the checkout).
    @State private var startError: String?
    @FocusState private var focusedField: Field?
    /// Set only by previews: the sheet opens in that state and runs no probes.
    private let staged: Staged?

    enum Phase {
        case checking, setup, input, running, done, failed
    }

    /// A phase with its form and pipeline already filled, so a preview renders the sheet there
    /// without git, gh or the network.
    struct Staged {
        var phase: Phase
        var base = "main"
        var title = ""
        var body = ""
        var includedCommits: Int?
        var steps: [WorktreeFinalizer.Step: WorktreeFinalizer.StepState] = [:]
        var prURL: String?
    }

    private enum Field { case base, title, description }

    init(vm: ShepherdViewModel, agent: Agent, space: Space, staged: Staged? = nil) {
        self.vm = vm
        self.agent = agent
        self.space = space
        self.staged = staged
        _setup = State(initialValue: WorktreeSetupModel(repoPath: space.path))
        if let staged {
            _phase = State(initialValue: staged.phase)
            _base = State(initialValue: staged.base)
            _title = State(initialValue: staged.title)
            _prBody = State(initialValue: staged.body)
            _descriptionPrepared = State(initialValue: true)
            _includedCommits = State(initialValue: staged.includedCommits)
            _finalizer = State(initialValue: WorktreeFinalizer(staged: staged.steps, prURL: staged.prURL))
        }
    }

    private var branch: String { agent.worktreeBranch ?? "" }
    private var worktreePath: String {
        agent.worktreePath ?? GitWorktree.destination(repo: space.path, branch: branch)
    }

    var body: some View {
        NWDialog(headerTitle, message: headerSubtitle, width: AppLayout.finalizeSheetWidth) {
            switch phase {
            case .checking:
                EmptyView()
            case .setup:
                WorktreeSetupChecklist(model: setup) {
                    vm.finalizeRequest = nil
                    vm.openGhLogin(besideAgent: agent.id)
                }
            case .input:
                inputBody
            case .running, .done, .failed:
                pipelineBody
            }
        } status: {
            status
        } actions: {
            actions
        }
        // Each phase replaces the last in place (title, body, footer) while the sheet eases to
        // its new height; within a phase, late arrivals (the commit count, a generated
        // description, a start error, the PR link) settle without a jump.
        .nwAnimation(.disclosure, value: phase)
        .nwAnimation(.disclosure, value: startError)
        .nwAnimation(.content, value: generatingDescription)
        .nwAnimation(.content, value: includedCommits)
        .task {
            guard staged == nil else { return }
            await initialChecks()
        }
    }

    private var headerTitle: String {
        switch phase {
        case .setup: return "Set up Finalize"
        case .done: return "Worktree finalized"
        case .failed: return "Finalize stopped"
        default: return "Finalize worktree"
        }
    }

    private var headerSubtitle: String {
        switch phase {
        case .checking:
            return "Checking prerequisites…"
        case .setup:
            return "Shepherd finalizes worktrees fully in-app: commit, push, pull request, and cleanup. A few things need to be set up first."
        case .input:
            return "Commits remaining work on \(branch), pushes it, opens a pull request, then removes the worktree and local branch. The remote branch stays until the PR merges."
        case .running:
            return "Working — each step must succeed before the next runs. Nothing is deleted until the worktree is verified clean."
        case .done:
            return "The pull request is open and the worktree is cleaned up. The agent will be removed when you close this dialog."
        case .failed:
            return "A step failed, so the pipeline stopped. Your work is intact — fix the issue and finalize again."
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .checking:
            HStack(spacing: NW.Space.s) {
                ProgressView().progressViewStyle(.nwSpinner)
                NWDialogStatus("Checking git, origin and the GitHub CLI…")
            }
        case .setup:
            if setup.allPassed {
                HStack(spacing: NW.Space.s) {
                    NWStatusDot(.done)
                    NWDialogStatus("All set — ready to finalize")
                }
            }
        case .input:
            // Back into the wizard: prerequisite status plus the recommended per-repo GitHub
            // settings live there.
            SheetLinkButton(label: "Repo setup…") { phase = .setup }
        case .running:
            HStack(spacing: NW.Space.s) {
                ProgressView().progressViewStyle(.nwSpinner)
                NWDialogStatus("Working…")
            }
        case .done, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch phase {
        case .checking:
            Button("Cancel") { vm.finalizeRequest = nil }
                .buttonStyle(.nw(.ghost))
                .keyboardShortcut(.cancelAction)
        case .setup:
            Button(setup.running ? "Checking…" : "Re-run checks") {
                Task { await setup.runAll() }
            }
            .buttonStyle(.nw(.secondary))
            .disabled(setup.running)
            Button("Cancel") { vm.finalizeRequest = nil }
                .buttonStyle(.nw(.ghost))
                .keyboardShortcut(.cancelAction)
            Button("Continue") {
                Task {
                    await prepareInputDefaults()
                    phase = .input
                    await generateDescriptionIfNeeded()
                }
            }
            .buttonStyle(.nw(.primary))
            .keyboardShortcut(.defaultAction)
            .disabled(!setup.allPassed)
        case .input:
            Button("Cancel") { vm.finalizeRequest = nil }
                .buttonStyle(.nw(.ghost))
                .keyboardShortcut(.cancelAction)
            Button("Finalize") { start() }
                .buttonStyle(.nw(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(generatingDescription
                    || title.trimmingCharacters(in: .whitespaces).isEmpty
                    || base.trimmingCharacters(in: .whitespaces).isEmpty)
        case .running:
            EmptyView()
        case .failed:
            Button("Close") { vm.finalizeRequest = nil }
                .buttonStyle(.nw(.secondary))
                .keyboardShortcut(.cancelAction)
        case .done:
            Button("Done") { finishAndRetire() }
                .buttonStyle(.nw(.primary))
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Checking

    private func initialChecks() async {
        await setup.runAll()
        // Repo-settings status is informational — load it in the background
        // (needs gh auth) so the setup view has it whenever it is visited,
        // without delaying the fast path to input.
        if setup.states[.ghAuth]?.passed == true {
            Task { await setup.probeRepoSettings() }
        }
        if setup.allPassed {
            await prepareInputDefaults()
            phase = .input
            await generateDescriptionIfNeeded()
        } else {
            phase = .setup
        }
    }

    // MARK: Input

    private func prepareInputDefaults() async {
        if title.isEmpty { title = agent.name }
        if base.isEmpty {
            if let recorded = agent.worktreeBase {
                // The branch the work actually started from — recorded at
                // creation, so the PR targets it even when it is not the
                // repo's default branch.
                base = recorded.hasPrefix("origin/")
                    ? String(recorded.dropFirst("origin/".count))
                    : recorded
            } else {
                // Pre-base-recording agents: origin/HEAD if known, else "main".
                let head = await LoginShell.run(
                    "git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null",
                    cwd: space.path
                )
                let short = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                base = short.hasPrefix("origin/") ? String(short.dropFirst("origin/".count)) : "main"
            }
        }
        await refreshIncludedCommits()
    }

    /// Count what the PR would contain, preferring the remote-tracking ref
    /// (that is what GitHub compares against).
    private func refreshIncludedCommits() async {
        let requestedBase = base
        let count = await WorktreeCommitCount.load(base: requestedBase, worktree: worktreePath)
        if base == requestedBase { includedCommits = count }
    }

    private func generateDescriptionIfNeeded(force: Bool = false) async {
        guard WorktreePRDescriptionGenerator.shouldGenerate(
            enabled: vm.settings.worktreeGeneratePRDescription,
            prepared: descriptionPrepared,
            force: force
        ) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedBase.isEmpty else { return }

        let original = prBody
        generatingDescription = true
        let result = await descriptionGenerator.generate(
            base: trimmedBase,
            title: trimmedTitle,
            worktree: worktreePath
        )
        prBody = WorktreePRDescriptionGenerator.applying(
            result.body,
            replacing: original,
            current: prBody
        )
        descriptionPrepared = true
        generatingDescription = false
    }

    private var inputBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetRow("Worktree") {
                Text(worktreePath)
                    .font(.nw(.mono))
                    .foregroundStyle(Color.nw.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(worktreePath)
                    .textSelection(.enabled)
            }
            SheetRow("Branch") {
                Text(branch)
                    .font(.nw(.mono))
                    .foregroundStyle(Color.nw.textSecondary)
                    .textSelection(.enabled)
            }
            SheetRow("Base") {
                HStack(spacing: NW.Space.m) {
                    TextField("Base branch", text: $base)
                        .focused($focusedField, equals: .base)
                        .nwField(focused: focusedField == .base, mono: true)
                        .frame(maxWidth: AppLayout.baseFieldMaxWidth)
                    if let count = includedCommits {
                        // > 20 commits from a disposable worktree usually
                        // means the base is wrong — shout, don't block.
                        Text("Will include \(count) commit\(count == 1 ? "" : "s")")
                            .font(.nw(.caption))
                            .foregroundStyle(count > 20 ? Color.nw.lanternText : Color.nw.textTertiary)
                            .nwContentTransition(.numeric())
                            .help("Commits on \(branch) that are not on the base branch — what the pull request will contain")
                    }
                }
            }
            .task(id: base) {
                guard staged == nil else { return }
                // Debounced: each count runs git in a login shell.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await refreshIncludedCommits()
            }
            SheetRow("Title") {
                TextField("Pull request title", text: $title,
                          prompt: Text("pull request title").foregroundStyle(Color.nw.textTertiary))
                    .focused($focusedField, equals: .title)
                    .nwField(focused: focusedField == .title)
            }
            VStack(alignment: .leading, spacing: NW.Space.s) {
                HStack(spacing: NW.Space.m) {
                    Text("Description")
                        .font(.nw(.ui))
                        .foregroundStyle(Color.nw.textSecondary)
                        .accessibilityHidden(true)
                    Spacer(minLength: NW.Space.m)
                    if generatingDescription {
                        HStack(spacing: NW.Space.s) {
                            ProgressView().progressViewStyle(.nwSpinner(size: AppLayout.sheetSpinner))
                            Text("Generating…").font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
                        }
                    } else if vm.settings.worktreeGeneratePRDescription {
                        SheetLinkButton(label: descriptionPrepared ? "Regenerate…" : "Generate…") {
                            Task { await generateDescriptionIfNeeded(force: true) }
                        }
                    }
                }
                TextEditor(text: $prBody)
                    .focused($focusedField, equals: .description)
                    .nwText(.body)
                    .foregroundStyle(Color.nw.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(height: AppLayout.descriptionEditorHeight)
                    .padding(NW.Space.s)
                    .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.s))
                    .nwBorder(Color.nw.lineStrong, radius: NW.Radius.s)
                    .overlay {
                        // The ring fades on its own layer: the editor itself never animates.
                        Color.clear
                            .nwFocusRing(focusedField == .description, radius: NW.Radius.s)
                            .nwComponentAnimation(.hover, value: focusedField == .description)
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel("Pull request description")
            }
            .padding(EdgeInsets(top: NW.Space.l, leading: NWDialogMetrics.inset, bottom: 0, trailing: NWDialogMetrics.inset))
            if let startError {
                DialogBanner(state: .failed, title: "Finalize can't start yet", message: startError)
            }
        }
    }

    private func start() {
        let checkout = URL(fileURLWithPath: worktreePath).resolvingSymlinksInPath().standardized.path
        guard !vm.hostBusyWorktrees.contains(checkout) else {
            // Shown in this sheet: a second sheet cannot present over it.
            startError = "A worktree operation is running for this checkout."
            return
        }
        startError = nil
        vm.hostBusyWorktrees.insert(checkout)
        let (repo, branch) = (space.path, branch)
        finalizer.beforeCleanup = {
            try vm.verifyCheckoutUnused(checkout, except: agent.id)
            try await Task.detached { try GitWorktree.verifyIdentity(worktree: checkout, repo: repo, branch: branch) }.value
        }
        phase = .running
        let ctx = WorktreeFinalizer.Context(
            repo: space.path,
            worktree: worktreePath,
            branch: branch,
            base: base.trimmingCharacters(in: .whitespaces),
            title: title.trimmingCharacters(in: .whitespaces),
            body: prBody,
            autoCommit: vm.settings.worktreeAutoCommit,
            deleteLocalBranch: vm.settings.worktreeDeleteLocalBranch,
            autoMergePR: vm.settings.worktreeAutoMergePR,
            mergeMethod: vm.settings.worktreeMergeMethod.rawValue
        )
        Task {
            defer { vm.hostBusyWorktrees.remove(checkout) }
            await finalizer.run(ctx)
            phase = finalizer.phase == .succeeded ? .done : .failed
        }
    }

    // MARK: Pipeline display

    private var pipelineBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The merge step only renders when the user opted in — a
            // permanently-skipped row is noise, not information.
            ForEach(WorktreeFinalizer.Step.allCases.filter {
                $0 != .mergePR || vm.settings.worktreeAutoMergePR
            }) { step in
                let status = (finalizer.states[step] ?? .pending).checklist
                NWChecklistRow(step.label, state: status.state, stateLabel: status.word, detail: status.detail)
            }
            if phase == .done, let url = finalizer.prURL {
                SheetRow("Pull request") {
                    HStack(spacing: NW.Space.m) {
                        Text(url)
                            .font(.nw(.mono))
                            .foregroundStyle(Color.nw.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        SheetLinkButton(label: "Open…") {
                            if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                        }
                        .accessibilityLabel("Open the pull request")
                    }
                }
            }
        }
    }

    /// Success dialog closed: dismiss first, then retire the agent (same
    /// teardown choreography as the delete dialogs).
    private func finishAndRetire() {
        let agentID = agent.id
        vm.finalizeRequest = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            vm.deleteAgent(agentID)
        }
    }
}

// MARK: - Setup checklist (the wizard body)

/// The guided prerequisite checklist: one row per check with its state glyph; failing rows
/// grow their remedy inline. Re-running the checks is the visual verification pass.
struct WorktreeSetupChecklist: View {
    var model: WorktreeSetupModel
    /// gh login needs a real terminal — Shepherd opens a pane beside the agent's thread.
    let openLoginShell: () -> Void
    @State private var identityName = ""
    @State private var identityEmail = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(WorktreeSetupCheck.allCases) { check in
                let state = model.states[check] ?? .pending
                let status = state.checklist
                // One row whatever the state, so a check turning from checking to passed pops
                // in place and a failed one grows its remedy underneath.
                NWChecklistRow(check.label, state: status.state, stateLabel: status.word, detail: status.detail,
                               showsRemedy: status.state == .failed) {
                    remedy(for: check)
                }
            }
            repoSettingsSection
            if let error = model.actionError {
                DialogBanner(state: .failed, title: "Setup step failed", message: error)
            }
        }
        .disabled(model.running)
        // Re-running the checks is the visual verification pass: remedies and the failure
        // banner disclose and withdraw as the answers come in.
        .nwAnimation(.disclosure, value: model.states)
        .nwAnimation(.disclosure, value: model.repoSettings)
        .nwAnimation(.disclosure, value: model.actionError)
    }

    /// Recommended GitHub repo settings: status + explanation + one-click
    /// enable when the user has admin. Informational — an "off" here never
    /// blocks Continue; that's why off renders idle, not failed.
    private var repoSettingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            NWSectionHeader("Recommended GitHub repo settings")
                .padding(EdgeInsets(top: NW.Space.l, leading: NWDialogMetrics.inset, bottom: NW.Space.xs, trailing: NWDialogMetrics.inset))
            ForEach(WorktreeRepoSetting.allCases) { setting in
                let state = model.repoSettings[setting] ?? .unknown
                let status = state.checklist
                NWChecklistRow(setting.label, state: status.state, stateLabel: status.word, detail: status.detail) {
                    HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
                        Text(setting.explanation)
                            .nwText(.caption)
                            .foregroundStyle(Color.nw.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if state == .disabled {
                            SheetLinkButton(label: "Enable…") {
                                Task { await model.enableRepoSetting(setting) }
                            }
                            .accessibilityLabel("Enable \(setting.label)")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func remedy(for check: WorktreeSetupCheck) -> some View {
        switch check {
        case .git:
            HStack(spacing: NW.Space.m) {
                remedyText(model.remoteAction == nil ? "Apple's installer opens outside Shepherd." : "Apple's installer opens on the host Mac.")
                SheetLinkButton(label: "Install command line tools…") {
                    model.installCommandLineTools()
                }
            }
        case .identity:
            HStack(spacing: NW.Space.m) {
                TextField("Git user name", text: $identityName, prompt: Text("name").foregroundStyle(Color.nw.textTertiary))
                    .textFieldStyle(.nw)
                    .frame(maxWidth: AppLayout.identityNameFieldMaxWidth)
                TextField("Git user email", text: $identityEmail, prompt: Text("email").foregroundStyle(Color.nw.textTertiary))
                    .textFieldStyle(.nw)
                    .frame(maxWidth: AppLayout.baseFieldMaxWidth)
                SheetLinkButton(label: model.remoteAction == nil ? "Apply" : "Apply on host") {
                    Task { await model.applyIdentity(name: identityName, email: identityEmail) }
                }
            }
        case .remote:
            remedyText("Add an `origin` remote to \(model.repoPath) and make sure you can push to it from a terminal.")
        case .gh:
            HStack(spacing: NW.Space.m) {
                Text("brew install gh")
                    .font(.nw(.mono))
                    .foregroundStyle(Color.nw.textPrimary)
                    .textSelection(.enabled)
                SheetLinkButton(label: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install gh", forType: .string)
                }
                .accessibilityLabel("Copy brew install gh")
                remedyText("Then re-run the checks.")
            }
        case .ghAuth:
            HStack(spacing: NW.Space.m) {
                remedyText("Sign in with GitHub in a terminal pane beside the thread, then come back.")
                SheetLinkButton(label: "Open a terminal for gh login…", action: openLoginShell)
            }
        }
    }

    private func remedyText(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .nwText(.caption)
            .foregroundStyle(Color.nw.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
