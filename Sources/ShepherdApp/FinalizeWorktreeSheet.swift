import SwiftUI
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

    @StateObject private var setup: WorktreeSetupModel
    @StateObject private var finalizer = WorktreeFinalizer()
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

    private enum Phase {
        case checking, setup, input, running, done, failed
    }

    init(vm: ShepherdViewModel, agent: Agent, space: Space) {
        self.vm = vm
        self.agent = agent
        self.space = space
        _setup = StateObject(wrappedValue: WorktreeSetupModel(repoPath: space.path))
    }

    private var branch: String { agent.worktreeBranch ?? "" }
    private var worktreePath: String {
        agent.worktreePath ?? GitWorktree.destination(repo: space.path, branch: branch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(Fonts.mono(13.5, .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                Text(headerSubtitle)
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 10, trailing: 20))

            switch phase {
            case .checking:
                checkingBody
            case .setup:
                WorktreeSetupChecklist(model: setup) {
                    vm.finalizeRequest = nil
                    vm.openGhLoginShell()
                }
                setupFooter
            case .input:
                inputBody
            case .running, .done, .failed:
                pipelineBody
            }
        }
        .frame(width: 560)
        .background(Tokens.workspaceBg)
        .task { await initialChecks() }
    }

    private var headerTitle: String {
        switch phase {
        case .setup: return "Set Up Worktree Finalize"
        case .done: return "Worktree Finalized"
        case .failed: return "Finalize Stopped"
        default: return "Finalize Worktree"
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

    // MARK: Checking

    private var checkingBody: some View {
        HStack(spacing: 8) {
            Circle().fill(Tokens.statusWorking).frame(width: 6, height: 6)
            Text("probing git, origin, and GitHub CLI…")
                .font(Fonts.mono(11))
                .foregroundStyle(Tokens.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 4, leading: 20, bottom: 16, trailing: 20))
    }

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

    // MARK: Setup wizard footer

    private var setupFooter: some View {
        HStack(spacing: 10) {
            if setup.allPassed {
                Text("✓ all set — ready to finalize")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.statusDone)
            }
            Spacer(minLength: 12)
            Button(setup.running ? "Checking…" : "Re-run Checks") {
                Task { await setup.runAll() }
            }
            .disabled(setup.running)
            Button("Cancel") { vm.finalizeRequest = nil }
                .keyboardShortcut(.cancelAction)
            Button("Continue") {
                Task {
                    await prepareInputDefaults()
                    phase = .input
                    await generateDescriptionIfNeeded()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(Tokens.accentButton)
            .disabled(!setup.allPassed)
        }
        .padding(EdgeInsets(top: 14, leading: 20, bottom: 16, trailing: 20))
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
        let baseName = base.trimmingCharacters(in: .whitespaces)
        guard !baseName.isEmpty else {
            includedCommits = nil
            return
        }
        let count = await LoginShell.run(
            "git rev-list --count \(shellQuoted("origin/" + baseName))..HEAD 2>/dev/null "
            + "|| git rev-list --count \(shellQuoted(baseName))..HEAD 2>/dev/null",
            cwd: worktreePath
        )
        includedCommits = Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
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
            SheetRow("worktree") {
                Text(worktreePath)
                    .font(Fonts.mono(11))
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(worktreePath)
            }
            SheetRow("branch") {
                Text(branch)
                    .font(Fonts.mono(11))
                    .foregroundStyle(Tokens.textSecondary)
            }
            SheetRow("base") {
                HStack(spacing: 8) {
                    TextField("", text: $base)
                        .textFieldStyle(.plain)
                        .font(Fonts.mono(11.5))
                        .foregroundStyle(Tokens.textSecondary)
                        .frame(maxWidth: 200)
                        .onSubmit { Task { await refreshIncludedCommits() } }
                    if let count = includedCommits {
                        // > 20 commits from a disposable worktree usually
                        // means the base is wrong — shout, don't block.
                        Text("will include \(count) commit\(count == 1 ? "" : "s")")
                            .font(Fonts.mono(10.5))
                            .foregroundStyle(count > 20 ? Tokens.statusBlocked : Tokens.textDim)
                            .help("Commits on \(branch) that are not on the base branch — what the pull request will contain")
                    }
                }
            }
            .onChange(of: base) { Task { await refreshIncludedCommits() } }
            SheetRow("title") {
                TextField("", text: $title,
                          prompt: Text("pull request title").foregroundStyle(Tokens.textDim))
                    .textFieldStyle(.plain)
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(Tokens.textSecondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("description")
                        .font(Fonts.mono(10.5, .semibold))
                        .tracking(0.74)
                        .foregroundStyle(Tokens.textDim)
                    Spacer(minLength: 8)
                    if generatingDescription {
                        Text("generating…")
                            .font(Fonts.mono(10.5))
                            .foregroundStyle(Tokens.textTertiary)
                    } else if vm.settings.worktreeGeneratePRDescription {
                        SheetLinkButton(label: descriptionPrepared ? "regenerate…" : "generate…") {
                            Task { await generateDescriptionIfNeeded(force: true) }
                        }
                    }
                }
                TextEditor(text: $prBody)
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(Tokens.textPrimary)
                    .frame(height: 66)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.black.opacity(0.25))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Tokens.chipBorder, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .padding(EdgeInsets(top: 12, leading: 20, bottom: 4, trailing: 20))

            HStack(spacing: 10) {
                // Back into the wizard: prerequisite status plus the
                // recommended per-repo GitHub settings live there.
                SheetLinkButton(label: "repo setup…") { phase = .setup }
                Spacer(minLength: 12)
                Button("Cancel") { vm.finalizeRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Finalize") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.accentButton)
                    .disabled(generatingDescription
                        || title.trimmingCharacters(in: .whitespaces).isEmpty
                        || base.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(EdgeInsets(top: 14, leading: 20, bottom: 16, trailing: 20))
        }
    }

    private func start() {
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
                stepRow(step)
            }
            if phase == .done, let url = finalizer.prURL {
                SheetRow("pull request") {
                    HStack(spacing: 8) {
                        Text(url)
                            .font(Fonts.mono(11))
                            .foregroundStyle(Tokens.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        SheetLinkButton(label: "open…") {
                            if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Spacer(minLength: 12)
                switch phase {
                case .running:
                    Text("working…")
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(Tokens.textTertiary)
                case .failed:
                    Button("Close") { vm.finalizeRequest = nil }
                        .keyboardShortcut(.cancelAction)
                case .done:
                    Button("Done") { finishAndRetire() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(Tokens.accentButton)
                default:
                    EmptyView()
                }
            }
            .padding(EdgeInsets(top: 14, leading: 20, bottom: 16, trailing: 20))
        }
    }

    private func stepRow(_ step: WorktreeFinalizer.Step) -> some View {
        let state = finalizer.states[step] ?? .pending
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(stepColor(state))
                    .frame(width: 6, height: 6)
                Text(step.label)
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(stepTextColor(state))
                Spacer(minLength: 8)
                Text(stepDetail(state))
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(stepDetailColor(state))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(stepDetail(state))
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 30)
            Rectangle().fill(Tokens.separator).frame(height: 1)
                .padding(.leading, 20)
        }
    }

    private func stepColor(_ state: WorktreeFinalizer.StepState) -> Color {
        switch state {
        case .pending: return Tokens.textDim.opacity(0.4)
        case .running: return Tokens.statusWorking
        case .done, .skipped: return Tokens.statusDone
        case .failed: return Tokens.statusBlocked
        }
    }

    private func stepTextColor(_ state: WorktreeFinalizer.StepState) -> Color {
        switch state {
        case .pending: return Tokens.textDim
        case .running: return Tokens.textPrimary
        case .done, .skipped: return Tokens.textSecondary
        case .failed: return Tokens.statusBlocked
        }
    }

    private func stepDetail(_ state: WorktreeFinalizer.StepState) -> String {
        switch state {
        case .pending: return ""
        case .running: return "…"
        case .done(let detail): return detail
        case .skipped(let detail): return detail
        case .failed(let detail): return detail
        }
    }

    private func stepDetailColor(_ state: WorktreeFinalizer.StepState) -> Color {
        if case .failed = state { return Tokens.statusBlocked }
        return Tokens.textMetadata
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

/// The guided prerequisite checklist: one row per check with a live status
/// dot; failing rows grow their remedy inline. Re-running the checks is the
/// visual verification pass.
struct WorktreeSetupChecklist: View {
    @ObservedObject var model: WorktreeSetupModel
    /// gh login needs a real terminal — Shepherd opens one of its own shells.
    let openLoginShell: () -> Void
    @State private var identityName = ""
    @State private var identityEmail = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(WorktreeSetupCheck.allCases) { check in
                let state = model.states[check] ?? .pending
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(color(state))
                            .frame(width: 6, height: 6)
                        Text(check.label)
                            .font(Fonts.mono(11.5))
                            .foregroundStyle(state.passed ? Tokens.textSecondary : Tokens.textPrimary)
                        Spacer(minLength: 8)
                        Text(detail(state))
                            .font(Fonts.mono(10.5))
                            .foregroundStyle(detailColor(state))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(detail(state))
                    }
                    .padding(.horizontal, 20)
                    .frame(minHeight: 30)
                    if case .fail = state {
                        remedy(for: check)
                            .padding(EdgeInsets(top: 0, leading: 36, bottom: 8, trailing: 20))
                    }
                    Rectangle().fill(Tokens.separator).frame(height: 1)
                        .padding(.leading, 20)
                }
            }
            repoSettingsSection
        }
    }

    /// Recommended GitHub repo settings: status + explanation + one-click
    /// enable when the user has admin. Informational — an "off" here never
    /// blocks Continue; that's why off renders dim, not blocked-red.
    private var repoSettingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("recommended · github repo settings")
                .font(Fonts.mono(10.5, .semibold))
                .tracking(0.74)
                .foregroundStyle(Tokens.textDim)
                .padding(EdgeInsets(top: 12, leading: 20, bottom: 6, trailing: 20))
            ForEach(WorktreeRepoSetting.allCases) { setting in
                let state = model.repoSettings[setting] ?? .unknown
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(repoColor(state))
                            .frame(width: 6, height: 6)
                        Text(setting.label)
                            .font(Fonts.mono(11.5))
                            .foregroundStyle(Tokens.textSecondary)
                        Spacer(minLength: 8)
                        Text(repoDetail(state))
                            .font(Fonts.mono(10.5))
                            .foregroundStyle(Tokens.textMetadata)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if state == .disabled {
                            SheetLinkButton(label: "enable…") {
                                Task { await model.enableRepoSetting(setting) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(minHeight: 30)
                    Text(setting.explanation)
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(Tokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(EdgeInsets(top: 0, leading: 36, bottom: 8, trailing: 20))
                    Rectangle().fill(Tokens.separator).frame(height: 1)
                        .padding(.leading, 20)
                }
            }
        }
    }

    private func repoColor(_ state: WorktreeRepoSettingState) -> Color {
        switch state {
        case .unknown: return Tokens.textDim.opacity(0.4)
        case .checking: return Tokens.statusWorking
        case .enabled: return Tokens.statusDone
        case .disabled, .unavailable: return Tokens.textDim
        }
    }

    private func repoDetail(_ state: WorktreeRepoSettingState) -> String {
        switch state {
        case .unknown: return ""
        case .checking: return "…"
        case .enabled: return "on"
        case .disabled: return "off"
        case .unavailable(let reason): return reason
        }
    }

    @ViewBuilder
    private func remedy(for check: WorktreeSetupCheck) -> some View {
        switch check {
        case .git:
            HStack(spacing: 8) {
                Text("Apple's installer opens outside Shepherd.")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.textTertiary)
                SheetLinkButton(label: "install command line tools…") {
                    model.installCommandLineTools()
                }
            }
        case .identity:
            HStack(spacing: 8) {
                TextField("", text: $identityName,
                          prompt: Text("name").foregroundStyle(Tokens.textDim))
                    .textFieldStyle(.plain)
                    .font(Fonts.mono(11))
                    .frame(maxWidth: 140)
                TextField("", text: $identityEmail,
                          prompt: Text("email").foregroundStyle(Tokens.textDim))
                    .textFieldStyle(.plain)
                    .font(Fonts.mono(11))
                    .frame(maxWidth: 200)
                SheetLinkButton(label: "apply") {
                    Task { await model.applyIdentity(name: identityName, email: identityEmail) }
                }
            }
        case .remote:
            Text("Add an `origin` remote to \(model.repoPath) and make sure you can push to it from a terminal.")
                .font(Fonts.mono(10.5))
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .gh:
            HStack(spacing: 8) {
                Text("brew install gh")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.textSecondary)
                SheetLinkButton(label: "copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install gh", forType: .string)
                }
                Text("then re-run checks")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.textTertiary)
            }
        case .ghAuth:
            HStack(spacing: 8) {
                Text("Sign in with GitHub in a Shepherd shell, then come back.")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.textTertiary)
                SheetLinkButton(label: "open login shell…", action: openLoginShell)
            }
        }
    }

    private func color(_ state: WorktreeCheckState) -> Color {
        switch state {
        case .pending: return Tokens.textDim.opacity(0.4)
        case .checking: return Tokens.statusWorking
        case .pass: return Tokens.statusDone
        case .fail: return Tokens.statusBlocked
        }
    }

    private func detail(_ state: WorktreeCheckState) -> String {
        switch state {
        case .pending: return ""
        case .checking: return "…"
        case .pass(let detail): return detail
        case .fail(let detail): return detail
        }
    }

    private func detailColor(_ state: WorktreeCheckState) -> Color {
        if case .fail = state { return Tokens.statusBlocked }
        return Tokens.textMetadata
    }
}
