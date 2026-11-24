import ShepherdSessions
import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdUI
import ShepherdRemote

/// The branch card's Commit… (BranchCommit board): the checkout's changed files, all ticked; the
/// message written from the file list, or generated from the diff on Generate from diff (the
/// model commit from review drafts with); Amend the last commit; then Commit, or Commit & push
/// through the card's Push (never forced, so off when amending a pushed commit). All in `BranchGit`.
struct BranchCommitSheet: View {
    let vm: ShepherdViewModel
    let agentID: AgentID
    let cwd: String

    /// What the sheet shows; previews pass one and the sheet runs no git.
    struct Form: Equatable {
        var info: RemoteCommitInfo
        var selected: Set<String>
        var title: String
        var details: String
        /// Why Amend is off, else nil.
        var amendBlocked: String?
        /// The remote-tracking ref that already has the last commit ("origin/agent/x").
        var pushedTo: String?
    }

    /// Why Commit & push is off, else nil: no remote, or an amend of a commit a remote already has
    /// (the push would need force, which Shepherd never does).
    static func pushProblem(_ form: Form, amend: Bool) -> String? {
        if form.info.pushRemote == nil { return "This checkout has no remote to push to." }
        return amendedPushNote(form, amend: amend)
    }

    /// Under Amend: why it turns Commit & push off.
    static func amendedPushNote(_ form: Form, amend: Bool) -> String? {
        guard amend, let ref = form.pushedTo else { return nil }
        return "Commit & push is off: the amended commit will differ from \(ref)."
    }

    @State private var form: Form?
    @State private var unavailable: String?
    @State private var amend = false
    /// The last commit's message, which Amend starts from while the message is untouched.
    @State private var headMessage: (title: String, body: String)?
    @State private var drafting = false
    @State private var drafted = false
    @State private var running = false
    @State private var error: String?

    init(vm: ShepherdViewModel, agentID: AgentID, cwd: String, staged: Form? = nil, amend: Bool = false) {
        self.vm = vm
        self.agentID = agentID
        self.cwd = cwd
        _form = State(initialValue: staged)
        _amend = State(initialValue: amend)
    }

    var body: some View {
        SHCardSheet("Commit", width: AppLayout.branchCommitSheetWidth) {
            content
        } actions: {
            Button("Cancel") { vm.branchSheet = nil }.buttonStyle(.shCardSheet(.dim)).keyboardShortcut(.cancelAction)
            Button("Commit & push") { commit(push: true) }
                .buttonStyle(.shCardSheet(.link))
                .disabled(problem != nil || running || pushProblem != nil)
                .help(pushProblem ?? "Push without force after committing")
            Button("Commit") { commit(push: false) }
                .buttonStyle(.shCardSheet(.pill)).keyboardShortcut(.defaultAction)
                .disabled(problem != nil || running)
        }
        .shAnimation(.content, value: drafting)
        .task {
            guard form == nil else { return }
            await read()
        }
    }

    private var pushProblem: String? {
        guard let form else { return "" }
        return Self.pushProblem(form, amend: amend)
    }

    /// Why Commit can't run yet, else nil.
    private var problem: String? {
        guard let form else { return unavailable ?? "" }
        if let blocked = form.info.blocked { return blocked }
        if amend, let reason = form.amendBlocked { return reason }
        if !amend && form.info.files.isEmpty { return "Nothing to commit." }
        if !amend && form.selected.isEmpty { return "Choose at least one file." }
        if form.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write a commit message." }
        return nil
    }

    @ViewBuilder private var content: some View {
        if let unavailable {
            SHBanner(.failed, title: "Can’t commit here", message: unavailable).padding(.top, SHCardSheetMetrics.labelTop)
        } else if let form = Binding($form) {
            fields(form)
        } else {
            Text("Reading the checkout…").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textTertiary)
                .padding(.top, SHCardSheetMetrics.labelTop)
        }
    }

    private func fields(_ form: Binding<Form>) -> some View {
        let sh = Color.sh
        let files = form.wrappedValue.info.files
        let selected = form.wrappedValue.selected
        return VStack(alignment: .leading, spacing: 0) {
            // The label takes all of them or none: the board has no header row.
            Button {
                form.wrappedValue.selected = selected.count == files.count ? [] : Set(files.map(\.id))
            } label: {
                SHCardSheetLabel("Changes", count: "\(selected.count) of \(files.count)")
            }
            .buttonStyle(.plain)
            .help(selected.count == files.count ? "Untick every file" : "Tick every file")
            SHCardSheetList {
                ScrollView {
                    LazyVStack(spacing: SHCardSheetMetrics.rowGap) {
                        ForEach(reviewCommitRows(files, selected: selected)) { row in
                            SHCardSheetFileRow(name: row.name, directory: row.directory.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                                               checked: row.selected, added: row.added, removed: row.removed, help: SHFileStatus(row.status).label) {
                                if form.wrappedValue.selected.remove(row.id) == nil { form.wrappedValue.selected.insert(row.id) }
                            }
                            .equatable()
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: AppLayout.commitFileListMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
            SHCardSheetLabel("Message") {
                Button("Generate from diff", action: generate)
                    .buttonStyle(.shCardSheet(.small))
                    .disabled(drafting || selected.isEmpty)
            }
            SHCardSheetField {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    TextField("Summary", text: form.title, prompt: Text("Summary").foregroundStyle(sh.textTertiary), axis: .vertical)
                        .lineLimit(1...3)
                        .font(.sh(.ui, weight: .regular))
                        .foregroundStyle(sh.textPrimary)
                        .accessibilityLabel("Commit summary")
                    TextField("Description", text: form.details, prompt: Text("Description (optional)").foregroundStyle(sh.textTertiary), axis: .vertical)
                        .lineLimit(1...8)
                        .font(.sh(.ui, weight: .regular))
                        .foregroundStyle(sh.textSecondary)
                        .accessibilityLabel("Commit description")
                    if drafting || drafted {
                        Text(drafting ? "Drafting from the diff…" : "Drafted from the diff · edit anything")
                            .font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                    }
                }
                .textFieldStyle(.plain)
                .tint(sh.lantern)
            }
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Toggle("Amend the last commit", isOn: Binding(get: { amend }, set: setAmend))
                    .toggleStyle(.shCheckbox)
                    .font(.sh(.ui, weight: .regular))
                    .foregroundStyle(sh.textPrimary)
                    .disabled(form.wrappedValue.amendBlocked != nil)
                if let reason = form.wrappedValue.amendBlocked ?? Self.amendedPushNote(form.wrappedValue, amend: amend) {
                    Text(reason).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                }
            }
            .padding(.top, SHCardSheetMetrics.amendTop)
            if let text = error ?? problem, !text.isEmpty {
                Text(text).font(.sh(.caption)).foregroundStyle(error != nil ? sh.failed : sh.textSecondary)
                    .textSelection(.enabled)
                    .padding(.top, SH.Space.m)
            }
        }
        .disabled(running || form.wrappedValue.info.blocked != nil)
    }

    // MARK: Git

    private func read() async {
        let cwd = cwd
        do {
            let info = try await ReviewCommitGit.info(cwd: cwd, agentWorking: false, draftsMessage: false) { await LoginShell.run($0, cwd: $1) }
            let (blocked, pushed) = await Task.detached { (BranchGit.amendBlocked(cwd: cwd), BranchGit.pushedTo(cwd: cwd)) }.value
            form = Form(info: info, selected: Set(info.files.map(\.id)), title: info.title, details: info.body,
                        amendBlocked: blocked, pushedTo: pushed)
        } catch {
            unavailable = ActionError.describe(error)
        }
    }

    /// Amend starts from the last commit's message, and unticking it puts the written one back,
    /// as long as the person hasn't edited it.
    private func setAmend(_ on: Bool) {
        amend = on
        guard let current = form else { return }
        let written = (current.info.title, current.info.body)
        if on, (current.title, current.details) == written {
            let cwd = cwd
            Task {
                guard let text = await Task.detached(operation: { try? BranchGit.git(["log", "-1", "--format=%B"], cwd: cwd) }).value,
                      let message = reviewCommitMessage(fromModel: text), amend, form?.title == written.0 else { return }
                headMessage = message
                form?.title = message.title
                form?.details = message.body
            }
        } else if !on, let head = headMessage, (current.title, current.details) == head {
            form?.title = written.0
            form?.details = written.1
            headMessage = nil
        }
    }

    private func generate() {
        guard let current = form else { return }
        drafting = true
        error = nil
        let paths = current.info.files.filter { current.selected.contains($0.id) }.flatMap(\.paths)
        let model = vm.settings.textGenerationModel
        Task {
            let message = await ReviewCommitGit.draftMessage(root: current.info.repository, paths: paths, model: model, pi: vm.pi) {
                await LoginShell.run($0, cwd: $1, timeout: 45)
            }
            form?.title = message.title
            form?.details = message.body
            drafted = message.drafted
            if !message.drafted { error = "Couldn’t generate a message, so it’s written from the file list." }
            drafting = false
        }
    }

    private func commit(push: Bool) {
        guard let current = form, problem == nil else { return }
        running = true
        error = nil
        let paths = current.info.files.filter { current.selected.contains($0.id) }.flatMap(\.paths)
        let message = reviewCommitMessageText(title: current.title, body: current.details)
        let (cwd, amend, branch, id) = (current.info.repository, amend, current.info.branch, agentID)
        Task {
            // Its hooks can rewrite files under a turn running here.
            let end = await vm.personWriteBegan(id)
            do {
                defer { end?() }
                let commit = try await Task.detached { try BranchGit.commit(cwd: cwd, paths: paths, message: message, amend: amend) }.value
                vm.branchSheet = nil
                if push, let branch {
                    vm.branchGit(id, "Committed \(commit), but couldn’t push \(branch)") { try BranchGit.push(cwd: cwd, branch: branch) }
                } else {
                    vm.readCheckoutOnHost(id)
                }
            } catch {
                self.error = ActionError.describe(error)
                running = false
            }
        }
    }
}
