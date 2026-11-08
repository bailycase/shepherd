import ShepherdSessions
import SwiftUI
import ShepherdCore
import ShepherdUI
import ShepherdRemote

/// Update from the base (BranchUpdateBase board): fetches origin's base when it opens, then
/// rebases or merges on Update. A conflict stops there: the files both sides changed, Abort
/// (the branch exactly as it was), Open in editor, or Ask the agent to resolve.
struct BranchUpdateSheet: View {
    let vm: ShepherdViewModel
    let agentID: AgentID
    let branch: String
    /// The worktree's recorded base; nil reads origin's default branch when the sheet opens.
    let recordedBase: String?
    let cwd: String
    /// Set by previews: the sheet opens there and runs no git.
    var staged: Stage?
    @State private var resolvedBase: String?
    private var base: String { resolvedBase ?? recordedBase ?? "main" }

    enum Stage: Equatable {
        case reading
        case ready(behind: Int)
        case running
        case conflict(BranchGit.Conflict)
        case failed(String)
    }

    @State private var stage: Stage = .reading
    @State private var rebase = true

    var body: some View {
        SHDialog("Update from origin/\(base)", message: subtitle, width: AppLayout.branchSheetWidth) {
            VStack(alignment: .leading, spacing: SH.Space.l) {
                SHSegmentedPicker("Update by", selection: $rebase, options: [(true, "Rebase"), (false, "Merge")])
                    .fixedSize()
                    .disabled(!isReady)
                switch stage {
                case .conflict(let conflict):
                    SHBanner(.failed, title: Self.conflictTitle(conflict),
                             message: "Nothing is lost. Abort puts the branch back exactly as it was.") { EmptyView() }
                    VStack(spacing: 0) {
                        ForEach(conflict.files, id: \.self) { file in
                            HStack {
                                Text(file).font(.sh(.code)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: SH.Space.m)
                                Text("both changed").font(.sh(.caption)).foregroundStyle(Color.sh.failed)
                            }
                            .frame(minHeight: SH.Height.row)
                        }
                    }
                case .failed(let message):
                    SHDialogStatus(message, isError: true)
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, SHDialogMetrics.inset)
        } status: {
            // Abort leads the footer, away from the ways forward.
            if case .conflict(let conflict) = stage {
                Button("Abort") { abort(conflict.kind) }.buttonStyle(.sh(.danger)).fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            actions
        }
        .shAnimation(.disclosure, value: stage)
        .task {
            if let staged { stage = staged; return }
            await read()
        }
    }

    private var isReady: Bool { if case .ready = stage { true } else { false } }

    private var subtitle: String {
        switch stage {
        case .reading: "Fetching origin/\(base)…"
        case .ready(let behind): behind == 0 ? "\(branch) is up to date. Fetched just now." : "\(branch) is \(behind) behind. Fetched just now."
        case .running: "Updating \(branch)…"
        case .conflict, .failed: "\(branch) onto origin/\(base)."
        }
    }

    @ViewBuilder private var actions: some View {
        switch stage {
        case .conflict(let conflict):
            Button("Open in editor") { openFiles(conflict.files) }.buttonStyle(.sh(.secondary))
            Button("Ask the agent to resolve") { ask(conflict) }.buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
        default:
            Button("Cancel") { vm.branchSheet = nil }.buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
            Button(rebase ? "Rebase" : "Merge") { update() }
                .buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
                .disabled(!isReady)
        }
    }

    static func conflictTitle(_ conflict: BranchGit.Conflict) -> String {
        let files = "\(conflict.files.count) file\(conflict.files.count == 1 ? "" : "s") conflict"
        if let step = conflict.step, let steps = conflict.steps { return "Stopped at commit \(step) of \(steps): \(files)" }
        return "Stopped: \(files)"
    }

    private func read() async {
        let (cwd, recorded) = (cwd, recordedBase)
        let (conflict, base, behind) = await Task.detached { () -> (BranchGit.Conflict?, String?, Int) in
            let base = recorded ?? BranchCardGitReader.read(cwd: cwd, base: nil).base
            if let conflict = BranchGit.conflict(cwd: cwd) { return (conflict, base, 0) }
            if let base { _ = GitWorktree.fetch(repo: cwd, branch: base) }
            return (nil, base, BranchCardGitReader.read(cwd: cwd, base: base).behind)
        }.value
        resolvedBase = base
        if conflict == nil, base == nil { stage = .failed("This checkout has no base to update from: origin has no default branch."); return }
        stage = conflict.map(Stage.conflict) ?? .ready(behind: behind)
    }

    private func update() {
        stage = .running
        let (cwd, base, rebase) = (cwd, base, rebase)
        Task {
            do {
                switch try await Task.detached(operation: { try BranchGit.update(cwd: cwd, base: base, rebase: rebase) }).value {
                case .done: vm.branchSheet = nil
                case .conflict(let conflict): stage = .conflict(conflict)
                }
            } catch {
                stage = .failed(ActionError.describe(error))
            }
            vm.checkouts?.refresh(agentID, priority: true)
        }
    }

    private func abort(_ kind: BranchGit.Conflict.Kind) {
        let cwd = cwd
        Task {
            do {
                try await Task.detached { try BranchGit.abort(cwd: cwd, kind) }.value
                vm.branchSheet = nil
            } catch {
                stage = .failed(ActionError.describe(error))
            }
            vm.checkouts?.refresh(agentID, priority: true)
        }
    }

    private func openFiles(_ files: [String]) {
        let root = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
        for file in files { ShepherdViewModel.openInEditor(root.appendingPathComponent(file), editor: vm.settings.editor) }
    }

    private func ask(_ conflict: BranchGit.Conflict) {
        let verb = conflict.kind == .rebase ? "rebase" : "merge"
        let text = "Updating \(branch) from origin/\(base) stopped on conflicts in "
            + conflict.files.map { "`\($0)`" }.joined(separator: ", ")
            + ". Resolve them keeping both sides' intent, stage the files, and run `git \(verb) --continue` until the \(verb) finishes."
        vm.branchSheet = nil
        Task {
            do { try await vm.sendUserMessage(text, to: agentID) }
            catch { vm.actionError = ActionError(title: "Couldn’t ask the agent", message: ActionError.describe(error)) }
        }
    }
}

/// New branch from here… and Rename branch…: one name field, checked as it is typed.
struct BranchNameSheet: View {
    let vm: ShepherdViewModel
    let agentID: AgentID
    let branch: String
    let cwd: String
    let rename: Bool
    @State private var name: String
    @State private var problem: String?
    @FocusState private var focused: Bool

    init(vm: ShepherdViewModel, agentID: AgentID, branch: String, cwd: String, rename: Bool) {
        self.vm = vm
        self.agentID = agentID
        self.branch = branch
        self.cwd = cwd
        self.rename = rename
        _name = State(initialValue: rename ? branch : "")
    }

    var body: some View {
        SHDialog(rename ? "Rename branch" : "New branch from here",
                 message: rename ? "Renames \(branch) here. A pushed branch keeps its name on origin."
                                 : "Starts a branch at \(branch)’s last commit and switches to it. Uncommitted changes come along.",
                 width: AppLayout.branchSheetWidth) {
            VStack(alignment: .leading, spacing: SH.Space.s) {
                TextField("Branch name", text: $name)
                    .focused($focused)
                    .shField(focused: focused, mono: true)
                    .onSubmit(save)
                if let problem, name != branch { SHDialogStatus(problem, isError: true) }
            }
            .padding(.horizontal, SHDialogMetrics.inset)
        } actions: {
            Button("Cancel") { vm.branchSheet = nil }.buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
            Button(rename ? "Rename" : "Create") { save() }
                .buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
                .disabled(problem != nil || name == branch)
        }
        .onAppear { focused = true }
        .task(id: name) {
            let (cwd, name) = (cwd, name)
            problem = await Task.detached { BranchGit.invalidName(name, cwd: cwd) }.value
        }
    }

    private func save() {
        guard problem == nil, name != branch else { return }
        let (cwd, old, new) = (cwd, branch, name.trimmingCharacters(in: .whitespacesAndNewlines))
        vm.branchSheet = nil
        if rename {
            vm.branchGit(agentID, "Couldn’t rename \(old)", record: { _ in (new, nil) }) { try BranchGit.renameBranch(cwd: cwd, from: old, to: new) }
        } else {
            vm.branchGit(agentID, "Couldn’t create \(new)", record: { _ in (new, nil) }) { try BranchGit.createBranch(cwd: cwd, name: new) }
        }
    }
}

/// The sheet `vm.branchSheet` names, for the agent as it is now.
struct BranchSheetView: View {
    let vm: ShepherdViewModel
    let sheet: BranchSheet

    var body: some View {
        switch sheet {
        case .commit(let id):
            if let cwd = vm.checkoutDirectory(of: id) { BranchCommitSheet(vm: vm, agentID: id, cwd: cwd) }
        case .update(let id):
            if let agent = agent(id), let label = AgentBranchLabel(agent: agent), let cwd = vm.checkoutDirectory(of: id) {
                BranchUpdateSheet(vm: vm, agentID: id, branch: label.branch, recordedBase: agent.worktreeBase.map(BranchCardGitReader.baseName), cwd: cwd)
            }
        case .newBranch(let id), .renameBranch(let id):
            if let agent = agent(id), let label = AgentBranchLabel(agent: agent), let cwd = vm.checkoutDirectory(of: id) {
                BranchNameSheet(vm: vm, agentID: id, branch: label.branch, cwd: cwd, rename: sheet == .renameBranch(id))
            }
        }
    }

    private func agent(_ id: AgentID) -> Agent? { vm.state.agents.first { $0.id == id } ?? vm.thisMacAgent(id)?.agent }
}
