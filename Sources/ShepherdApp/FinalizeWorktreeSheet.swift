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
                    .font(Font.nw(.title))
                    .foregroundStyle(Color.nw.textPrimary)
                Text(headerSubtitle)
                    .font(Font.nw(.body))
                    .foregroundStyle(Color.nw.textSecondary)
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
                    vm.openGhLogin(besideAgent: agent.id)
                }
                setupFooter
            case .input:
                inputBody
            case .running, .done, .failed:
                pipelineBody
            }
        }
        .frame(width: 560)
        .background(Color.nw.bgWindow)
        .buttonStyle(NWButtonStyle(.secondary))
        .task { await initialChecks() }
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

    // MARK: Checking

    private var checkingBody: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.nw.done).frame(width: 6, height: 6)
            Text("Checking git, origin and the GitHub CLI…")
                .font(Font.nw(.caption))
                .foregroundStyle(Color.nw.textSecondary)
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
                Text("All set — ready to finalize")
                    .font(Font.nw(.caption))
                    .foregroundStyle(Color.nw.running)
            }
            Spacer(minLength: 12)
            Button(setup.running ? "Checking…" : "Re-run checks") {
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
            .buttonStyle(NWButtonStyle(.primary))
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
                    .font(Font.nw(.mono))
                    .foregroundStyle(Color.nw.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(worktreePath)
            }
            SheetRow("Branch") {
                Text(branch)
                    .font(Font.nw(.mono))
                    .foregroundStyle(Color.nw.textSecondary)
            }
            SheetRow("Base") {
                HStack(spacing: 8) {
                    TextField("", text: $base)
                        .textFieldStyle(.plain)
                        .font(Font.nw(.mono))
                        .foregroundStyle(Color.nw.textSecondary)
                        .frame(maxWidth: 200)
                        .onSubmit { Task { await refreshIncludedCommits() } }
                    if let count = includedCommits {
                        // > 20 commits from a disposable worktree usually
                        // means the base is wrong — shout, don't block.
                        Text("Will include \(count) commit\(count == 1 ? "" : "s")")
                            .font(Font.nw(.caption))
                            .foregroundStyle(count > 20 ? Color.nw.lanternText : Color.nw.textTertiary)
                            .help("Commits on \(branch) that are not on the base branch — what the pull request will contain")
                    }
                }
            }
            .onChange(of: base) { Task { await refreshIncludedCommits() } }
            SheetRow("Title") {
                TextField("", text: $title,
                          prompt: Text("pull request title").foregroundStyle(Color.nw.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Font.nw(.body))
                    .foregroundStyle(Color.nw.textSecondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Description")
                        .font(Font.nw(.ui))
                        .tracking(0.74)
                        .foregroundStyle(Color.nw.textTertiary)
                    Spacer(minLength: 8)
                    if generatingDescription {
                        Text("Generating…")
                            .font(Font.nw(.caption))
                            .foregroundStyle(Color.nw.textSecondary)
                    } else if vm.settings.worktreeGeneratePRDescription {
                        SheetLinkButton(label: descriptionPrepared ? "Regenerate…" : "Generate…") {
                            Task { await generateDescriptionIfNeeded(force: true) }
                        }
                    }
                }
                TextEditor(text: $prBody)
                    .font(Font.nw(.body))
                    .foregroundStyle(Color.nw.textPrimary)
                    .frame(height: 66)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.s))
                    .overlay { RoundedRectangle(cornerRadius: NW.Radius.s).strokeBorder(Color.nw.lineStrong, lineWidth: 1) }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .padding(EdgeInsets(top: 12, leading: 20, bottom: 4, trailing: 20))

            HStack(spacing: 10) {
                // Back into the wizard: prerequisite status plus the
                // recommended per-repo GitHub settings live there.
                SheetLinkButton(label: "Repo setup…") { phase = .setup }
                Spacer(minLength: 12)
                Button("Cancel") { vm.finalizeRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Finalize") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(NWButtonStyle(.primary))
                    .disabled(generatingDescription
                        || title.trimmingCharacters(in: .whitespaces).isEmpty
                        || base.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(EdgeInsets(top: 14, leading: 20, bottom: 16, trailing: 20))
        }
    }

    private func start() {
        let checkout = URL(fileURLWithPath: worktreePath).resolvingSymlinksInPath().standardized.path
        guard !vm.hostBusyWorktrees.contains(checkout) else {
            vm.remoteActionError = "A worktree operation is running for this checkout"
            return
        }
        vm.hostBusyWorktrees.insert(checkout)
        finalizer.beforeCleanup = {
            try vm.verifyCheckoutUnused(checkout, except: agent.id)
            try await Task.detached { try GitWorktree.verifyIdentity(worktree: checkout, repo: space.path, branch: branch) }.value
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
                stepRow(step)
            }
            if phase == .done, let url = finalizer.prURL {
                SheetRow("Pull request") {
                    HStack(spacing: 8) {
                        Text(url)
                            .font(Font.nw(.mono))
                            .foregroundStyle(Color.nw.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        SheetLinkButton(label: "Open…") {
                            if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Spacer(minLength: 12)
                switch phase {
                case .running:
                    Text("Working…")
                        .font(Font.nw(.caption))
                        .foregroundStyle(Color.nw.textSecondary)
                case .failed:
                    Button("Close") { vm.finalizeRequest = nil }
                        .keyboardShortcut(.cancelAction)
                case .done:
                    Button("Done") { finishAndRetire() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(NWButtonStyle(.primary))
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
                    .font(Font.nw(.body))
                    .foregroundStyle(stepTextColor(state))
                Spacer(minLength: 8)
                Text(stepDetail(state))
                    .font(Font.nw(.caption))
                    .foregroundStyle(stepDetailColor(state))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(stepDetail(state))
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 30)
            NWHairline()
                .padding(.leading, 20)
        }
    }

    private func stepColor(_ state: WorktreeFinalizer.StepState) -> Color {
        switch state {
        case .pending: return Color.nw.textTertiary.opacity(0.4)
        case .running: return Color.nw.done
        case .done, .skipped: return Color.nw.running
        case .failed: return Color.nw.failed
        }
    }

    private func stepTextColor(_ state: WorktreeFinalizer.StepState) -> Color {
        switch state {
        case .pending: return Color.nw.textTertiary
        case .running: return Color.nw.textPrimary
        case .done, .skipped: return Color.nw.textSecondary
        case .failed: return Color.nw.failed
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
        if case .failed = state { return Color.nw.failed }
        return Color.nw.textTertiary
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
    /// gh login needs a real terminal — Shepherd opens a pane beside the agent's thread.
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
                            .font(Font.nw(.body))
                            .foregroundStyle(state.passed ? Color.nw.textSecondary : Color.nw.textPrimary)
                        Spacer(minLength: 8)
                        Text(detail(state))
                            .font(Font.nw(.caption))
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
                    NWHairline()
                        .padding(.leading, 20)
                }
            }
            repoSettingsSection
            if let error = model.actionError { DialogWarning(text: error) }
        }
        .disabled(model.running)
    }

    /// Recommended GitHub repo settings: status + explanation + one-click
    /// enable when the user has admin. Informational — an "off" here never
    /// blocks Continue; that's why off renders dim, not blocked-red.
    private var repoSettingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recommended GitHub repo settings".uppercased())
                .font(Font.nw(.micro))
                .tracking(0.74)
                .foregroundStyle(Color.nw.textTertiary)
                .padding(EdgeInsets(top: 12, leading: 20, bottom: 6, trailing: 20))
            ForEach(WorktreeRepoSetting.allCases) { setting in
                let state = model.repoSettings[setting] ?? .unknown
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(repoColor(state))
                            .frame(width: 6, height: 6)
                        Text(setting.label)
                            .font(Font.nw(.body))
                            .foregroundStyle(Color.nw.textSecondary)
                        Spacer(minLength: 8)
                        Text(repoDetail(state))
                            .font(Font.nw(.caption))
                            .foregroundStyle(Color.nw.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if state == .disabled {
                            SheetLinkButton(label: "Enable…") {
                                Task { await model.enableRepoSetting(setting) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(minHeight: 30)
                    Text(setting.explanation)
                        .font(Font.nw(.caption))
                        .foregroundStyle(Color.nw.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(EdgeInsets(top: 0, leading: 36, bottom: 8, trailing: 20))
                    NWHairline()
                        .padding(.leading, 20)
                }
            }
        }
    }

    private func repoColor(_ state: WorktreeRepoSettingState) -> Color {
        switch state {
        case .unknown: return Color.nw.textTertiary.opacity(0.4)
        case .checking: return Color.nw.done
        case .enabled: return Color.nw.running
        case .disabled, .unavailable: return Color.nw.textTertiary
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
                Text(model.remoteAction == nil ? "Apple's installer opens outside Shepherd." : "Apple's installer opens on the host Mac.")
                    .font(Font.nw(.caption))
                    .foregroundStyle(Color.nw.textSecondary)
                SheetLinkButton(label: "Install command line tools…") {
                    model.installCommandLineTools()
                }
            }
        case .identity:
            HStack(spacing: 8) {
                TextField("", text: $identityName,
                          prompt: Text("name").foregroundStyle(Color.nw.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Font.nw(.body))
                    .frame(maxWidth: 140)
                TextField("", text: $identityEmail,
                          prompt: Text("email").foregroundStyle(Color.nw.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Font.nw(.body))
                    .frame(maxWidth: 200)
                SheetLinkButton(label: model.remoteAction == nil ? "Apply" : "Apply on host") {
                    Task { await model.applyIdentity(name: identityName, email: identityEmail) }
                }
            }
        case .remote:
            Text("Add an `origin` remote to \(model.repoPath) and make sure you can push to it from a terminal.")
                .font(Font.nw(.caption))
                .foregroundStyle(Color.nw.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .gh:
            HStack(spacing: 8) {
                Text("brew install gh")
                    .font(Font.nw(.micro))
                    .foregroundStyle(Color.nw.textSecondary)
                SheetLinkButton(label: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install gh", forType: .string)
                }
                Text("Then re-run the checks.")
                    .font(Font.nw(.caption))
                    .foregroundStyle(Color.nw.textSecondary)
            }
        case .ghAuth:
            HStack(spacing: 8) {
                Text("Sign in with GitHub in a terminal pane beside the thread, then come back.")
                    .font(Font.nw(.caption))
                    .foregroundStyle(Color.nw.textSecondary)
                SheetLinkButton(label: "Open a terminal for gh login…", action: openLoginShell)
            }
        }
    }

    private func color(_ state: WorktreeCheckState) -> Color {
        switch state {
        case .pending: return Color.nw.textTertiary.opacity(0.4)
        case .checking: return Color.nw.done
        case .pass: return Color.nw.running
        case .fail: return Color.nw.failed
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
        if case .fail = state { return Color.nw.failed }
        return Color.nw.textTertiary
    }
}
