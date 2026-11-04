import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Review #31 (MobilePRReview): the review's text, Comment, Approve or Request changes, and Also
/// send to the agent, which hands the reviewers' comments and this one to the pull request's
/// thread (`ForgeBriefs.feedbackPrompt`).
struct ForgeReviewSheet: View {
    let key: ForgeItemKey
    let model: ForgePullRequestModel
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(ThreadStores.self) private var threads
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var verdict: ForgeReviewVerdict = .comment
    @State private var sendToAgent: Bool
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    init(key: ForgeItemKey, model: ForgePullRequestModel) {
        self.key = key
        self.model = model
        _sendToAgent = State(initialValue: model.thread != nil)
    }

    var body: some View {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // GitHub takes an approval without words, never a comment or a change request.
        let ready = !sending && (verdict == .approve || !body.isEmpty)
        ForgeSheetFrame(title: "Review #\(key.ref.number)", action: "Submit review", ready: ready, problem: problem, submit: submit) {
            ForgeTextBox(text: $text, prompt: "Leave a comment", focused: $focused)
            SHListCard {
                ForEach(ForgeReviewVerdict.allCases, id: \.self) { option in
                    ForgeChoiceRow(title: ForgePresentation.title(option), subtitle: option == .comment ? "Feedback without a verdict" : nil,
                                   tone: option == .approve ? .done : option == .requestChanges ? .failed : nil,
                                   selected: verdict == option) { verdict = option }
                }
            }
            SHListCard {
                ForgeSwitchRow(title: "Also send to the agent",
                               subtitle: model.thread.map { "The thread fixes it on \($0.branch ?? model.detail.summary.headRef)" }
                                   ?? "Starts a thread on \(model.detail.summary.headRef)",
                               isOn: $sendToAgent)
            }
        }
    }

    private func submit() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true
        problem = nil
        Task {
            defer { sending = false }
            let store = ForgeStore.of(hosts)
            guard await store.change(.review(ref: key.ref, verdict: verdict, body: body), for: key) else {
                problem = store.failure
                store.failure = nil
                return
            }
            if sendToAgent {
                var comments = model.lineComments
                if !body.isEmpty {
                    comments.append(ForgeLineComment(id: 0, author: model.detail.viewer ?? "me", path: "the pull request", line: nil,
                                                     diffHunk: "", body: body, createdAt: Date()))
                }
                let brief = ForgeBriefs.feedbackPrompt(model.detail, comments: comments, repoPath: store.repoPath(key))
                dismiss()
                if let problem = await ForgeAgent.run(brief, host: key.host, hosts: hosts, threads: threads, navigator: navigator) {
                    store.failure = problem
                }
            } else {
                dismiss()
            }
        }
    }
}

/// Merge #31 (MobilePRMerge, DuoBookPRMerge): why it's blocked, the method, Merge when ready,
/// Delete the branch and Remove the worktree (the confirmed Delete Worktree, once merged).
struct ForgeMergeSheet: View {
    let key: ForgeItemKey
    let model: ForgePullRequestModel
    /// The thread whose worktree to remove once the sheet has gone.
    let removeWorktree: (AgentRef) -> Void
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.dismiss) private var dismiss
    @State private var method: ForgeMergeMethod
    @State private var whenReady: Bool
    @State private var deleteBranch = true
    @State private var removesWorktree: Bool
    @State private var sending = false
    @State private var problem: String?

    init(key: ForgeItemKey, model: ForgePullRequestModel, removeWorktree: @escaping (AgentRef) -> Void) {
        self.key = key
        self.model = model
        self.removeWorktree = removeWorktree
        let detail = model.detail
        _method = State(initialValue: detail.defaultMergeMethod.flatMap { detail.mergeMethods.contains($0) ? $0 : nil }
                        ?? detail.mergeMethods.first ?? .squash)
        _whenReady = State(initialValue: model.blocked != nil || detail.autoMerge)
        _removesWorktree = State(initialValue: model.thread?.worktreePath != nil)
    }

    var body: some View {
        let detail = model.detail
        ForgeSheetFrame(title: "Merge #\(key.ref.number)", action: whenReady ? "Merge when ready" : ForgePresentation.title(method),
                        ready: !sending && (model.blocked == nil || whenReady), problem: problem, submit: submit) {
            if let blocked = model.blocked {
                SHBanner(.failed, title: ForgePresentation.blockedTitle, message: blocked)
            }
            SHListCard {
                ForEach(detail.mergeMethods, id: \.self) { option in
                    ForgeChoiceRow(title: ForgePresentation.title(option),
                                   subtitle: option == .squash ? "One commit on \(detail.summary.baseRef)" : nil,
                                   tone: nil, selected: method == option) { method = option }
                }
            }
            SHListCard {
                ForgeSwitchRow(title: "Merge when ready", subtitle: "After review and checks pass", isOn: $whenReady)
                if !detail.deletesBranchOnMerge {
                    ForgeSwitchRow(title: "Delete the branch", subtitle: nil, isOn: $deleteBranch)
                }
                if model.thread?.worktreePath != nil {
                    ForgeSwitchRow(title: "Remove the worktree", subtitle: model.hostName, isOn: $removesWorktree)
                }
            }
        }
    }

    private func submit() {
        sending = true
        problem = nil
        Task {
            defer { sending = false }
            let store = ForgeStore.of(hosts)
            let request = RemoteForgeRequest.merge(ref: key.ref, method: method, whenReady: whenReady,
                                                   deleteBranch: deleteBranch && !model.detail.deletesBranchOnMerge)
            guard await store.change(request, for: key) else {
                problem = store.failure
                store.failure = nil
                return
            }
            // A merge that waits leaves the worktree; it goes once the merge happened (Clean up).
            if removesWorktree, !whenReady, let agent = model.thread?.agentID { removeWorktree(AgentRef(host: key.host, agent: agent)) }
            dismiss()
        }
    }
}

/// Comment on an issue or pull request.
struct ForgeCommentSheet: View {
    let key: ForgeItemKey
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        ForgeSheetFrame(title: "Comment on #\(key.ref.number)", action: "Comment", ready: !sending && !body.isEmpty, problem: problem) {
            sending = true
            Task {
                defer { sending = false }
                let store = ForgeStore.of(hosts)
                if await store.change(.comment(ref: key.ref, body: body), for: key) {
                    dismiss()
                } else {
                    problem = store.failure
                    store.failure = nil
                }
            }
        } content: {
            ForgeTextBox(text: $text, prompt: "Leave a comment", focused: $focused)
        }
        .onAppear { focused = true }
    }
}

// MARK: Parts

/// A sheet's frame: Cancel and the title in the bar, the content, then the one primary button.
struct ForgeSheetFrame<Content: View>: View {
    let title: String
    let action: String
    let ready: Bool
    let problem: String?
    let submit: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                    if let problem {
                        SHBanner(.failed, title: problem)
                    }
                    content()
                }
                .padding(.horizontal, MobileLayout.gutter)
                .padding(.vertical, SH.Space.m)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.sh.bgWindow)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button(action, action: submit)
                    .buttonStyle(.shReviewBar(.primary))
                    .disabled(!ready)
                    .padding(.horizontal, MobileLayout.gutter)
                    .padding(.vertical, SH.Space.m)
                    .background(Color.sh.bgWindow)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        // Over the page, which shows above it (MobilePRReview, MobilePRMerge).
        .presentationDetents([.fraction(MobileLayout.forgeSheetFraction), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.sh.bgWindow)
    }
}

/// The text a review or comment sends, in a raised box that grows with it.
struct ForgeTextBox: View {
    @Binding var text: String
    let prompt: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .font(.sh(.body))
            .foregroundStyle(Color.sh.textPrimary)
            .tint(Color.sh.lantern)
            .focused(focused)
            .lineLimit(4...)
            .padding(SH.Space.l)
            .frame(maxWidth: .infinity, minHeight: MobileLayout.forgeEditorMinHeight, alignment: .topLeading)
            .shCard(radius: MobileLayout.cardRadius, line: Color.sh.lineStrong)
            .onChange(of: text) { _, new in
                if new.count > ForgeLimits.bodyCharacters { text = String(new.prefix(ForgeLimits.bodyCharacters)) }
            }
    }
}

/// One of a sheet's choices (Comment, Approve, Squash and merge): its title in its tone, a
/// subtitle, the lantern check on the chosen one.
struct ForgeChoiceRow: View {
    let title: String
    let subtitle: String?
    let tone: ForgeTone?
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: SH.Space.m) {
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(title).font(.sh(.body)).foregroundStyle(tone?.textColor ?? Color.sh.textPrimary)
                    if let subtitle {
                        Text(subtitle).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    }
                }
                Spacer(minLength: SH.Space.m)
                if selected {
                    Image(systemName: "checkmark").font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.lantern)
                }
            }
            .padding(.horizontal, SH.Space.l)
            .padding(.vertical, SH.Space.m)
            .frame(maxWidth: .infinity, minHeight: SH.Height.touch + SH.Space.s, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.shRow(radius: 0))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A switch row with an optional subtitle.
struct ForgeSwitchRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title).font(.sh(.body)).foregroundStyle(Color.sh.textPrimary)
                if let subtitle {
                    Text(subtitle).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
            }
        }
        .tint(Color.sh.done)
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.m)
        .frame(maxWidth: .infinity, minHeight: SH.Height.touch + SH.Space.s, alignment: .leading)
    }
}
