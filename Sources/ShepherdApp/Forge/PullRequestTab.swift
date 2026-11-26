import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSidebar

/// The side pane's Pull request tab (PRPane, PRPaneMerged): the thread branch's pull request,
/// drawn from the Issues & PRs page's pieces. A head row (state, number, link buttons), then the title and byline over
/// Overview, Files and Checks with the rail beside them, merged or not. A footer says
/// what stands in the way, or what is left, with its actions.
struct PullRequestTab: View {
    var vm: ShepherdViewModel
    @Bindable var store: ForgeStore
    let agentID: AgentID

    var body: some View {
        VStack(spacing: 0) {
            ForgeBanners(vm: vm, store: store)
            if let detail = store.pullRequest {
                PullRequestHead(store: store, detail: detail)
                switch store.tab {
                case .summary:
                    PullRequestOverview(vm: vm, store: store, detail: detail)
                case .changes, .checks:
                    PullRequestHeader(store: store, detail: detail)
                        .padding(.leading, AppLayout.prPaneColumnLeading)
                        .padding(.trailing, AppLayout.prPaneColumnTrailing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if store.tab == .changes {
                        ForgeChangesTab(vm: vm, store: store, detail: detail)
                    } else {
                        ForgeChecksTab(vm: vm, store: store, detail: detail)
                    }
                }
                PullRequestFooter(vm: vm, store: store, detail: detail, agentID: agentID)
            } else if let error = store.detailError {
                ForgeDetailError(error: error) { Task { await store.loadDetail() } }
            } else if let ref = store.selection {
                ForgeLoadingPage(number: ref.number)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The head row (GXPanePR `.prh`): the state in a quiet pill, "payments #31", then Copy link and Open on GitHub.
private struct PullRequestHead: View {
    @Bindable var store: ForgeStore
    let detail: PullRequestDetail

    var body: some View {
        HStack(spacing: SH.Space.m) {
            Text(ForgePresentation.badge(detail.state).label)
                .font(.sh(.caption, weight: .medium))
                .foregroundStyle(Color.sh.textPrimary)
                .padding(.horizontal, SH.Space.m)
                .padding(.vertical, SH.Space.xxs)
                .background(Color.sh.bgSelected, in: RoundedRectangle(cornerRadius: AppLayout.prPaneBoxRadius))
            Text("\(detail.summary.ref.repoName) #\(detail.summary.ref.number)")
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(Color.sh.textTertiary)
            Spacer(minLength: SH.Space.m)
            ForgeItemButtons(store: store, ref: detail.ref, pins: false)
        }
        .padding(.leading, AppLayout.prPaneColumnLeading)
        .padding(.trailing, SH.Space.m)
        .frame(height: AppLayout.prPaneHeadHeight)
        .accessibilityElement(children: .contain)
    }
}

/// The title, the byline and the tabs under them with a rule (GXPanePR `.prmain h2`, `.prm`, `.seg2`).
private struct PullRequestHeader: View {
    @Bindable var store: ForgeStore
    let detail: PullRequestDetail

    var body: some View {
        let summary = detail.summary
        VStack(alignment: .leading, spacing: SH.Space.s) {
            ForgeTitle(title: summary.title, editable: detail.state != .merged, font: .shSans(AppLayout.prPaneTitleSize, .semibold)) {
                await store.perform(.editTitle(ref: summary.ref, title: $0))
            }
            byline
            ForgeTabs(store: store, detail: detail, pane: true)
                .padding(.top, SH.Space.m)
                .padding(.bottom, SH.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { SHHairline() }
        }
    }

    /// "baily opened this 2h ago, agent/refund-events into main", or "baily merged agent/refund-events into main 2 days ago".
    private var byline: some View {
        let summary = detail.summary
        let age = ForgePresentation.ago(detail.createdAt, now: store.now())
        let head = Text(summary.headRef).font(.sh(.mono)), base = Text(summary.baseRef).font(.sh(.mono))
        let who = Text(summary.author).foregroundStyle(Color.sh.textPrimary)
        let line = detail.state == .merged
            ? Text("\(who) merged \(head) into \(base) \(age)")
            : Text("\(who) opened this \(age), \(head) into \(base)")
        return line
            .font(.sh(.caption))
            .foregroundStyle(Color.sh.textSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Overview: the description, Activity and Leave a comment, with the rail beside them in a
/// wide pane and under them in a narrow one.
private struct PullRequestOverview: View {
    var vm: ShepherdViewModel
    @Bindable var store: ForgeStore
    let detail: PullRequestDetail
    @State private var wide = true

    var body: some View {
        // Wide, the rail stands beside the column and keeps its place while the column scrolls
        // (the merged state opens at its end); narrow, it follows the column.
        HStack(alignment: .top, spacing: SH.Space.xxl) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SH.Space.xxl) {
                    column
                    if !wide { PullRequestRail(vm: vm, detail: detail) }
                }
                .padding(.bottom, SH.Space.xl)
                .padding(.leading, AppLayout.prPaneColumnLeading)
                .padding(.trailing, wide ? AppLayout.prPaneColumnTrailing : AppLayout.prPaneColumnLeading)
            }
            if wide {
                ScrollView(.vertical) {
                    PullRequestRail(vm: vm, detail: detail).padding(.bottom, SH.Space.xl)
                }
                .frame(width: AppLayout.prPaneRailWidth)
                .padding(.trailing, SH.Space.xl)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= AppLayout.prPaneTwoColumnMinWidth } action: { wide = $0 }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            PullRequestHeader(store: store, detail: detail)
            if !store.bodyProse.isEmpty { Prose(prose: store.bodyProse, maxWidth: AppLayout.forgeContentWidth) }
            ForgeActivity(store: store, events: detail.events, viewer: detail.viewer, kind: .pullRequest, lineComments: true, pane: true)
            PullRequestCommentCard(store: store, viewer: detail.viewer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Leave a comment, at the end of Activity: the viewer's initial, the field, and Comment.
private struct PullRequestCommentCard: View {
    let store: ForgeStore
    let viewer: String?
    @State private var text = ""

    var body: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                ForgeAvatar(login: viewer ?? "?", you: true)
                TextField("", text: $text, prompt: Text("Leave a comment").foregroundStyle(Color.sh.textTertiary), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.sh(.body))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(1...6)
                    .accessibilityLabel("Comment")
            }
            Button("Comment") {
                guard let ref = store.selection else { return }
                let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { if await store.perform(.comment(ref: ref, body: words)) { text = "" } }
            }
            .buttonStyle(.sh(.secondary, size: .s))
            .disabled(empty || store.working)
            .padding(.leading, AppLayout.forgeAvatar + SH.Space.m)
        }
        .padding(SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard()
    }
}

/// The rail: the thread, the reviewers with their verdicts, the checks.
private struct PullRequestRail: View {
    var vm: ShepherdViewModel
    let detail: PullRequestDetail

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            if let thread = detail.summary.thread {
                ForgeRailSection(title: "Thread") {
                    Button { vm.selectAgent(thread.agentID) } label: {
                        Label(thread.title, systemImage: ForgeSymbol.comment)
                            .font(.sh(.ui, weight: .regular))
                            .foregroundStyle(Color.sh.textPrimary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Open the thread")
                }
            }
            if !detail.reviewers.isEmpty {
                ForgeRailSection(title: "Reviewers") {
                    ForEach(detail.reviewers, id: \.login) { reviewer in
                        HStack(spacing: SH.Space.m) {
                            ForgeAvatar(login: reviewer.login, you: isViewer(reviewer.login))
                            Text(reviewer.login).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary)
                            Spacer(minLength: SH.Space.s)
                            verdict(reviewer.state)
                        }
                        .frame(height: SH.Height.controlM)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if !detail.checks.isEmpty {
                if let passed = ForgePresentation.allPassed(detail.checks) {
                    ForgeRailSection(title: "Checks", divider: false) {
                        HStack(spacing: SH.Space.m) {
                            SHStateGlyph(.done, size: SH.Space.l)
                            Text(passed.text).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary)
                            Spacer(minLength: SH.Space.s)
                            if let duration = passed.duration { Text(duration).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary) }
                        }
                        .frame(height: SH.Height.controlM)
                    }
                } else {
                    ForgeRailSection(title: ForgePresentation.checksTitle(detail.checks), divider: false) {
                        ForEach(detail.checks) { check in
                            ForgeCheckLine(check: check, fix: nil).frame(height: SH.Height.controlM)
                        }
                    }
                }
            }
        }
    }

    /// Approved a check, changes requested a bubble, pending a ring.
    @ViewBuilder private func verdict(_ state: ForgeReviewState) -> some View {
        let tone = ForgePresentation.tone(state)
        Group {
            switch state {
            case .approved: Image(systemName: "checkmark").foregroundStyle(tone.color)
            case .changesRequested: Image(systemName: ForgeSymbol.comment).foregroundStyle(tone.color)
            case .pending: Image(systemName: "circle").foregroundStyle(ForgeTone.attention.color)
            case .commented, .dismissed: Image(systemName: ForgeSymbol.comment).foregroundStyle(Color.sh.textTertiary)
            }
        }
        .font(.sh(.caption))
        .help(ForgePresentation.label(state))
        .accessibilityLabel(ForgePresentation.label(state))
    }

    private func isViewer(_ login: String) -> Bool { detail.viewer.map { $0.caseInsensitiveCompare(login) == .orderedSame } ?? false }
}

/// The footer (GXPanePR `.prf`): what stands in the way or what is left in words, then its actions as words: Send feedback to
/// agent and Squash and merge (open), Ready for review (draft), Reopen (closed), or Delete branch and Remove worktree (merged).
private struct PullRequestFooter: View {
    var vm: ShepherdViewModel
    @Bindable var store: ForgeStore
    let detail: PullRequestDetail
    let agentID: AgentID

    var body: some View {
        let status = ForgePresentation.paneStatus(detail)
        let line = Text(status.text).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        // A narrow pane puts the words under the line rather than truncate them.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SH.Space.s) {
                line.frame(maxWidth: .infinity, alignment: .leading)
                actions.fixedSize()
            }
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                line
                HStack(spacing: SH.Space.s) { actions }.fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, AppLayout.prPaneColumnLeading)
        .padding(.trailing, SH.Space.m)
        .frame(minHeight: AppLayout.prPaneFooterHeight)
        .overlay(alignment: .top) { SHHairline() }
        .disabled(store.working)
    }

    @ViewBuilder private var actions: some View {
        let ref = detail.ref
        switch detail.state {
        case .open:
            Button("Send feedback to agent") { vm.sendPullRequestFeedback(store, to: agentID) }
                .buttonStyle(PaneWordButtonStyle(emphasis: true))
                .disabled(ForgePresentation.reviewFeedback(detail).isEmpty)
                .help("Send what reviewers asked to this thread")
            Button(ForgePresentation.title(store.mergeOptions.method)) { vm.forgeMerge(store: store) }
                .buttonStyle(PaneWordButtonStyle(emphasis: false))
                .disabled(!detail.blockers.isEmpty)
                .help(ForgePresentation.blockerSentence(detail.blockers) ?? ForgePresentation.title(store.mergeOptions.method))
        case .draft:
            Button("Ready for review") { Task { await store.perform(.setDraft(ref: ref, draft: false)) } }
                .buttonStyle(PaneWordButtonStyle(emphasis: true))
        case .closed:
            Button("Reopen") { Task { await store.perform(.setOpen(ref: ref, open: true)) } }
                .buttonStyle(PaneWordButtonStyle(emphasis: true))
        case .merged:
            if !detail.headBranchDeleted, !detail.deletesBranchOnMerge {
                Button("Delete branch") { Task { await store.perform(.deleteBranch(ref: ref)) } }
                    .buttonStyle(PaneWordButtonStyle(emphasis: true))
            }
            if detail.summary.thread?.worktreePath != nil {
                Button("Remove worktree") { vm.forgeRemoveWorktree(store: store) }
                    .buttonStyle(PaneWordButtonStyle(emphasis: false))
            }
        }
    }
}
