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
        SHCardSheet("Update from origin/\(base)", message: message, width: AppLayout.branchSheetWidth) {
            VStack(alignment: .leading, spacing: 0) {
                switch stage {
                case .conflict(let conflict):
                    SHCardSheetLabel(Self.conflictLabel(conflict))
                    SHCardSheetList {
                        ForEach(conflict.files, id: \.self) { file in
                            let (directory, name) = reviewPathParts(file)
                            SHCardSheetFileRow(name: name, directory: directory.trimmingCharacters(in: CharacterSet(charactersIn: "/")), word: "Conflict")
                        }
                    }
                    Text("Nothing is lost. Abort puts the branch back exactly as it was.")
                        .font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textSecondary)
                        .padding(.top, SH.Space.l)
                case .failed(let text):
                    updateBy
                    Text(text).font(.sh(.caption)).foregroundStyle(Color.sh.failed).textSelection(.enabled).padding(.top, SH.Space.m)
                default:
                    updateBy
                }
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

    private var updateBy: some View {
        SHSegmentedPicker("Update by", selection: $rebase, options: [(true, "Rebase"), (false, "Merge")])
            .fixedSize()
            .disabled(!isReady)
            .padding(.top, SHCardSheetMetrics.labelTop)
    }

    private var isReady: Bool { if case .ready = stage { true } else { false } }

    /// What the sheet says under its title: the state of the update, or where a conflict stopped it.
    private var message: Text {
        func code(_ text: String) -> Text { Text(text).font(.sh(.mono)) }
        switch stage {
        case .reading: return Text("Fetching origin/\(base)…")
        case .ready(let behind): return Text(behind == 0 ? "\(branch) is up to date. Fetched just now." : "\(branch) is \(behind) behind. Fetched just now.")
        case .running: return Text("Updating \(branch)…")
        case .conflict(let conflict):
            return Text("Updating ") + code(branch) + Text(" from ") + code("origin/\(base)")
                + Text(" stopped on conflicts in \(conflict.files.count) file\(conflict.files.count == 1 ? "" : "s").")
        case .failed: return code(branch) + Text(" onto ") + code("origin/\(base)") + Text(".")
        }
    }

    @ViewBuilder private var actions: some View {
        switch stage {
        case .conflict(let conflict):
            Button("Abort") { abort(conflict.kind) }.buttonStyle(.shCardSheet(.dim))
            Button("Open in editor") { openFiles(conflict.files) }.buttonStyle(.shCardSheet(.dim))
            Button("Ask the agent to resolve") { ask(conflict) }.buttonStyle(.shCardSheet(.pill)).keyboardShortcut(.defaultAction)
        default:
            Button("Cancel") { vm.branchSheet = nil }.buttonStyle(.shCardSheet(.dim)).keyboardShortcut(.cancelAction)
            Button(rebase ? "Rebase" : "Merge") { update() }
                .buttonStyle(.shCardSheet(.pill)).keyboardShortcut(.defaultAction)
                .disabled(!isReady)
        }
    }

    /// "Stopped at commit 2 of 3", or "Stopped" for a merge.
    static func conflictLabel(_ conflict: BranchGit.Conflict) -> String {
        if let step = conflict.step, let steps = conflict.steps { return "Stopped at commit \(step) of \(steps)" }
        return "Stopped"
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
            let end = await vm.personWriteBegan(agentID)
            defer { end?() }
            do {
                switch try await Task.detached(operation: { try BranchGit.update(cwd: cwd, base: base, rebase: rebase) }).value {
                case .done: vm.branchSheet = nil
                case .conflict(let conflict): stage = .conflict(conflict)
                }
            } catch {
                stage = .failed(ActionError.describe(error))
            }
            vm.readCheckoutOnHost(agentID)
        }
    }

    private func abort(_ kind: BranchGit.Conflict.Kind) {
        let cwd = cwd
        Task {
            let end = await vm.personWriteBegan(agentID)
            defer { end?() }
            do {
                try await Task.detached { try BranchGit.abort(cwd: cwd, kind) }.value
                vm.branchSheet = nil
            } catch {
                stage = .failed(ActionError.describe(error))
            }
            vm.readCheckoutOnHost(agentID)
        }
    }

    private func openFiles(_ files: [String]) {
        let root = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
        for file in files.map(root.appendingPathComponent) { ShepherdViewModel.openInEditor(file, editor: vm.settings.editor(for: file)) }
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
        SHCardSheet(rename ? "Rename branch" : "New branch from here",
                    message: Text(rename ? "Renames \(branch) here. A pushed branch keeps its name on origin."
                                         : "Starts a branch at \(branch)’s last commit and switches to it. Uncommitted changes come along."),
                    width: AppLayout.branchSheetWidth) {
            VStack(alignment: .leading, spacing: SH.Space.s) {
                TextField("Branch name", text: $name)
                    .focused($focused)
                    .shField(focused: focused, mono: true)
                    .onSubmit(save)
                if let problem, name != branch { Text(problem).font(.sh(.caption)).foregroundStyle(Color.sh.failed).textSelection(.enabled) }
            }
            .padding(.top, SHCardSheetMetrics.labelTop)
        } actions: {
            Button("Cancel") { vm.branchSheet = nil }.buttonStyle(.shCardSheet(.dim)).keyboardShortcut(.cancelAction)
            Button(rename ? "Rename" : "Create") { save() }
                .buttonStyle(.shCardSheet(.pill)).keyboardShortcut(.defaultAction)
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

    private func agent(_ id: AgentID) -> Agent? { vm.state.agents.first { $0.id == id } }
}
