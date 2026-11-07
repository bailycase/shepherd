import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The side pane's Pull request tab (PRPane, PRPaneMerged): the thread branch's pull request,
/// drawn from the Issues & PRs page's pieces. Open: its tag, title and byline over Overview,
/// Files and Checks, the rail beside them. Merged: a title bar over the description and its
/// Activity, opened at the end. A footer says what stands in the way, or what is left, with its actions.
struct PullRequestTab: View {
    var vm: ShepherdViewModel
    @Bindable var store: ForgeStore
    let agentID: AgentID

    var body: some View {
        VStack(spacing: 0) {
            ForgeBanners(vm: vm, store: store)
            if let detail = store.pullRequest {
                if detail.state == .merged {
                    PullRequestTitleBar(detail: detail)
                    PullRequestOverview(vm: vm, store: store, detail: detail, header: false)
                } else {
                    switch store.tab {
                    case .summary:
                        PullRequestOverview(vm: vm, store: store, detail: detail, header: true)
                    case .changes, .checks:
                        PullRequestHeader(store: store, detail: detail)
                            .padding(.horizontal, SH.Space.xxl)
                            .padding(.top, SH.Space.xl)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if store.tab == .changes {
                            ForgeChangesTab(vm: vm, store: store, detail: detail)
                        } else {
                            ForgeChecksTab(vm: vm, store: store, detail: detail)
                        }
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

/// The open state's head: tag and "payments #31", the title, the byline, then the tabs.
private struct PullRequestHeader: View {
    @Bindable var store: ForgeStore
    let detail: PullRequestDetail

    var body: some View {
        let summary = detail.summary
        let badge = ForgePresentation.badge(detail.state)
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(spacing: SH.Space.s) {
                ForgeStateTag(label: badge.label, tone: badge.tone, symbol: ForgeSymbol.pullRequest)
                Text("\(summary.ref.repoName) #\(summary.ref.number)").font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
            }
            ForgeTitle(title: summary.title, editable: true) { await store.perform(.editTitle(ref: summary.ref, title: $0)) }
            ForgeByline(author: summary.author, you: isViewer(summary.author), verb: "opened",
                        age: ForgePresentation.ago(detail.createdAt, now: store.now()), branches: (summary.headRef, summary.baseRef))
            ForgeTabs(store: store, detail: detail, pane: true).padding(.top, SH.Space.s)
        }
    }

    private func isViewer(_ login: String) -> Bool { detail.viewer.map { $0.caseInsensitiveCompare(login) == .orderedSame } ?? false }
}

/// The merged state's bar (PRPaneMerged): its tag, the title and the number, over the page.
private struct PullRequestTitleBar: View {
    let detail: PullRequestDetail

    var body: some View {
        let badge = ForgePresentation.badge(detail.state)
        HStack(spacing: SH.Space.m) {
            ForgeStateTag(label: badge.label, tone: badge.tone, symbol: ForgeSymbol.merge)
            Text(detail.summary.title).font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
            Text("#\(detail.ref.number)").font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SH.Space.xxl)
        .frame(height: AppLayout.prPaneTitleBarHeight)
        .overlay(alignment: .bottom) { SHHairline() }
        .accessibilityElement(children: .combine)
    }
}

/// Overview: the description, Activity and Leave a comment, with the rail beside them in a
/// wide pane and under them in a narrow one.
private struct PullRequestOverview: View {
    var vm: ShepherdViewModel
    @Bindable var store: ForgeStore
    let detail: PullRequestDetail
    /// The open state's head and tabs lead the column; the merged state has its title bar instead.
    let header: Bool
    @State private var wide = true
    @State private var position = ScrollPosition()

    var body: some View {
        // Wide, the rail stands beside the column and keeps its place while the column scrolls
        // (the merged state opens at its end); narrow, it follows the column.
        HStack(alignment: .top, spacing: SH.Space.xxl) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SH.Space.xxl) {
                    column
                    if !wide { PullRequestRail(vm: vm, detail: detail) }
                }
                .padding(.vertical, SH.Space.xl)
                .padding(.leading, SH.Space.xxl)
                .padding(.trailing, wide ? 0 : SH.Space.xxl)
            }
            .scrollPosition($position)
            // Merged, the page opens on its Activity (PRPaneMerged), once the rows have their heights.
            .task(id: detail.ref) { if !header { position.scrollTo(edge: .bottom) } }
            if wide {
                ScrollView(.vertical) {
                    PullRequestRail(vm: vm, detail: detail).padding(.vertical, SH.Space.xl)
                }
                .frame(width: AppLayout.prPaneRailWidth)
                .padding(.trailing, SH.Space.xxl)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= AppLayout.prPaneTwoColumnMinWidth } action: { wide = $0 }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            if header { PullRequestHeader(store: store, detail: detail) }
            if !store.bodyBlocks.isEmpty { Prose(blocks: store.bodyBlocks, maxWidth: AppLayout.forgeContentWidth) }
            SHHairline()
            ForgeActivity(store: store, events: detail.events, viewer: detail.viewer, kind: .pullRequest, lineComments: true)
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

/// The footer: what stands in the way or what is left, then Send feedback to agent and Merge
/// (open), Ready for review (draft), Reopen (closed), or Delete branch and Remove worktree (merged).
private struct PullRequestFooter: View {
    var vm: ShepherdViewModel
    @Bindable var store: ForgeStore
    let detail: PullRequestDetail
    let agentID: AgentID

    var body: some View {
        let status = ForgePresentation.paneStatus(detail)
        let line = HStack(spacing: SH.Space.s) {
            Image(systemName: glyph(status.tone)).font(.sh(.ui)).foregroundStyle(status.tone.color)
            Text(status.text).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // A narrow pane puts the buttons under the line rather than truncate them.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SH.Space.s) {
                line.frame(maxWidth: .infinity, alignment: .leading)
                actions.fixedSize()
            }
            VStack(alignment: .leading, spacing: SH.Space.m) {
                line
                HStack(spacing: SH.Space.s) { actions }.fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, SH.Space.xxl)
        .padding(.vertical, SH.Space.m)
        .overlay(alignment: .top) { SHHairline() }
        .disabled(store.working)
    }

    @ViewBuilder private var actions: some View {
        let ref = detail.ref
        switch detail.state {
        case .open:
            Button("Send feedback to agent") { vm.sendPullRequestFeedback(store, to: agentID) }
                .buttonStyle(.sh(.secondary))
                .disabled(ForgePresentation.reviewFeedback(detail).isEmpty)
                .help("Send what reviewers asked to this thread")
            Button { vm.forgeMerge(store: store) } label: {
                Label(ForgePresentation.title(store.mergeOptions.method), systemImage: ForgeSymbol.merge)
            }
            .buttonStyle(.sh(.secondary))
            .disabled(!detail.blockers.isEmpty)
            .help(ForgePresentation.blockerSentence(detail.blockers) ?? ForgePresentation.title(store.mergeOptions.method))
        case .draft:
            Button("Ready for review") { Task { await store.perform(.setDraft(ref: ref, draft: false)) } }.buttonStyle(.sh(.secondary))
        case .closed:
            Button("Reopen") { Task { await store.perform(.setOpen(ref: ref, open: true)) } }.buttonStyle(.sh(.secondary))
        case .merged:
            if !detail.headBranchDeleted, !detail.deletesBranchOnMerge {
                Button("Delete branch") { Task { await store.perform(.deleteBranch(ref: ref)) } }.buttonStyle(.sh(.secondary))
            }
            if detail.summary.thread?.worktreePath != nil {
                Button("Remove worktree") { vm.forgeRemoveWorktree(store: store) }.buttonStyle(.sh(.secondary))
            }
        }
    }

    private func glyph(_ tone: ForgeTone) -> String {
        switch tone {
        case .merged: ForgeSymbol.merge
        case .done: SHGlyph.resolved.symbolName
        default: "exclamationmark.circle"
        }
    }
}
