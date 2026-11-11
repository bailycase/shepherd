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
        SHDialog("Commit", message: subtitle, monoMessage: true, width: AppLayout.branchCommitSheetWidth) {
            content
        } status: {
            if let text = error ?? problem {
                SHDialogStatus(text, isError: error != nil)
            }
        } actions: {
            Button("Cancel") { vm.branchSheet = nil }.buttonStyle(.sh(.secondary)).keyboardShortcut(.cancelAction)
            Button("Commit") { commit(push: false) }.buttonStyle(.sh(.secondary)).disabled(problem != nil || running)
            Button("Commit & push") { commit(push: true) }
                .buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
                .disabled(problem != nil || running || pushProblem != nil)
                .help(pushProblem ?? "Push without force after committing")
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

    private var subtitle: String? {
        guard let form else { return unavailable == nil ? "Reading the checkout…" : nil }
        let files = "\(form.selected.count) of \(form.info.files.count) file\(form.info.files.count == 1 ? "" : "s")"
        return form.info.branch.map { "\($0) · \(files)" } ?? files
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
            SHBanner(.failed, title: "Can’t commit here", message: unavailable).padding(.horizontal, SHDialogMetrics.inset)
        } else if let form = Binding($form) {
            fields(form)
        }
    }

    private func fields(_ form: Binding<Form>) -> some View {
        let sh = Color.sh
        let files = form.wrappedValue.info.files
        return VStack(alignment: .leading, spacing: SH.Space.l) {
            VStack(spacing: 0) {
                HStack(spacing: SH.Space.m) {
                    Toggle(sources: Binding(get: { files.map { form.wrappedValue.selected.contains($0.id) } }, set: { ticks in
                        form.wrappedValue.selected = Set(zip(files, ticks).filter(\.1).map(\.0.id))
                    }), isOn: \.self) { Text("Changes").font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary) }
                    .toggleStyle(.shCheckbox)
                    Spacer(minLength: SH.Space.s)
                    SHDiffStat(added: files.reduce(0) { $0 + $1.added }, removed: files.reduce(0) { $0 + $1.removed },
                               font: .sh(.micro, weight: .regular))
                }
                .padding(.horizontal, SH.Space.l + SH.Space.xxs)
                .frame(minHeight: SH.Height.row)
                SHHairline()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(reviewCommitRows(files, selected: form.wrappedValue.selected)) { row in
                            SHCommitFileRow(SHCommitFileRow.Item(row), showsStatus: true) {
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
            .shCard()
            VStack(alignment: .leading, spacing: SH.Space.s) {
                HStack {
                    Text("Message").font(.sh(.caption)).foregroundStyle(sh.textSecondary)
                    Spacer(minLength: SH.Space.s)
                    Button("Generate from diff", action: generate)
                        .buttonStyle(.shLink(font: .sh(.caption)))
                        .disabled(drafting || form.wrappedValue.selected.isEmpty)
                }
                SHCommitMessageEditor(title: form.title, message: form.details,
                                      source: drafting ? .drafting : drafted ? .drafted : .written)
            }
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Toggle("Amend the last commit", isOn: Binding(get: { amend }, set: setAmend))
                    .toggleStyle(.shCheckbox)
                    .font(.sh(.caption))
                    .foregroundStyle(sh.textSecondary)
                    .disabled(form.wrappedValue.amendBlocked != nil)
                if let reason = form.wrappedValue.amendBlocked ?? Self.amendedPushNote(form.wrappedValue, amend: amend) {
                    Text(reason).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                }
            }
        }
        .padding(.horizontal, SHDialogMetrics.inset)
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
        Task {
            let message = await ReviewCommitGit.draftMessage(root: current.info.repository, paths: paths, pi: vm.pi) {
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
            do {
                let commit = try await Task.detached { try BranchGit.commit(cwd: cwd, paths: paths, message: message, amend: amend) }.value
                vm.branchSheet = nil
                if push, let branch {
                    vm.branchGit(id, "Committed \(commit), but couldn’t push \(branch)") { try BranchGit.push(cwd: cwd, branch: branch) }
                } else {
                    vm.checkouts?.refresh(id, priority: true)
                }
            } catch {
                self.error = ActionError.describe(error)
                running = false
            }
        }
    }
}
