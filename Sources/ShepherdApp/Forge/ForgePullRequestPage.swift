import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// A pull request's page (PRReview, PRReviewChanges, PRReviewMerge, PRReviewDraft, PRReviewMerged,
/// PRReviewClosed, PRReviewLoading): Summary, Changes and Checks under one header whose actions
/// follow its state.
struct ForgePullRequestPage: View {
    var vm: ShepherdViewModel
    @Bindable var store: ForgeStore
    let chrome: PageHeaderChrome

    var body: some View {
        let detail = store.pullRequest
        VStack(spacing: 0) {
            ForgeHeaderBar(chrome: chrome, back: vm.leaveForge) {
                ForgeTabs(store: store, detail: detail)
            } trailing: {
                if let detail { ForgePullRequestActions(vm: vm, store: store, detail: detail) }
            }
            ForgeBanners(vm: vm, store: store)
            if let detail {
                switch store.tab {
                case .summary:
                    ForgePullRequestSummary(vm: vm, store: store, detail: detail)
                        .overlay(alignment: .bottom) {
                            ForgeFloatingField(placeholder: "Ask the agent about this pull request", sendTitle: nil,
                                               sending: false) { await vm.forgeAsk($0) }
                        }
                case .changes: ForgeChangesTab(vm: vm, store: store, detail: detail)
                case .checks: ForgeChecksTab(vm: vm, store: store, detail: detail)
                }
            } else if let error = store.detailError {
                ForgeDetailError(error: error) { Task { await store.loadDetail() } }
            } else if let ref = store.selection {
                ForgeLoadingPage(number: ref.number)
            }
        }
    }
}

/// Summary | Changes +200 −8 | Checks •.
private struct ForgeTabs: View {
    @Bindable var store: ForgeStore
    let detail: PullRequestDetail?

    var body: some View {
        HStack(spacing: SH.Space.xxs) {
            tab(.summary) { Text("Summary") }
            tab(.changes) {
                HStack(spacing: SH.Space.s) {
                    Text("Changes")
                    if let summary = detail?.summary { SHDiffStat(added: summary.additions, removed: summary.deletions, font: .sh(.mono)) }
                }
            }
            tab(.checks) {
                HStack(spacing: SH.Space.s) {
                    Text("Checks")
                    if let tone = detail.flatMap({ ForgePresentation.tone($0.summary.checks) }) { ForgeDot(tone: tone) }
                }
            }
        }
        .padding(SH.Space.xxs)
        .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.s))
        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.s)
        .fixedSize()
        .disabled(detail == nil)
    }

    private func tab<Label: View>(_ value: ForgeStore.Tab, @ViewBuilder label: () -> Label) -> some View {
        let selected = store.tab == value
        return Button { store.tab = value } label: {
            label()
                .font(.sh(.ui, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.sh.textPrimary : Color.sh.textSecondary)
                .padding(.horizontal, SH.Space.m)
                .frame(height: SH.Height.controlS)
                .background(selected ? Color.sh.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
                .contentShape(Rectangle())
                .shFocusRing(radius: SH.Radius.xs)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Header actions

/// Pin, link, GitHub; Review with agent; Submit review; then the state's own action: Merge and
/// its menu, Ready for review, Reopen, or Remove worktree and Delete branch.
private struct ForgePullRequestActions: View {
    var vm: ShepherdViewModel
    @Bindable var store: ForgeStore
    let detail: PullRequestDetail
    @State private var mergeMenu = false
    @State private var review = false

    var body: some View {
        SHFlowLayout(spacing: SH.Space.m) {
            ForgeItemButtons(store: store, ref: detail.ref)
            Button("Review with agent") { vm.forgeReviewWithAgent() }
                .buttonStyle(.sh(.secondary))
                .help("Start a thread that reviews this pull request and reports back")
            if detail.state == .open || detail.state == .draft {
                Button { review = true } label: { Image(systemName: ForgeSymbol.review) }
                    .buttonStyle(.shIcon(isOn: review))
                    .help("Submit a review")
                    .accessibilityLabel("Submit a review")
                    .popover(isPresented: $review, arrowEdge: .bottom) { ForgeReviewPopover(store: store, detail: detail) { review = false } }
            }
            primary
        }
        .disabled(store.working)
    }

    @ViewBuilder private var primary: some View {
        switch detail.state {
        case .open:
            HStack(spacing: SH.Space.xxs) {
                Button { vm.forgeMerge() } label: {
                    Label("Merge", systemImage: ForgeSymbol.merge)
                }
                .buttonStyle(.sh(.strong))
                .help(store.mergeOptions.whenReady ? "\(ForgePresentation.title(store.mergeOptions.method)) when reviews and checks allow"
                      : ForgePresentation.title(store.mergeOptions.method))
                Button { mergeMenu = true } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.sh(.strong))
                    .accessibilityLabel("Merge options")
                    .popover(isPresented: $mergeMenu, arrowEdge: .bottom) {
                        ForgeMergeMenu(store: store, detail: detail) { mergeMenu = false }
                    }
            }
        case .draft:
            Button("Ready for review") { Task { await store.perform(.setDraft(ref: detail.ref, draft: false)) } }.buttonStyle(.sh(.strong))
        case .closed:
            Button("Reopen") { Task { await store.perform(.setOpen(ref: detail.ref, open: true)) } }.buttonStyle(.sh(.strong))
        case .merged:
            if detail.summary.thread?.worktreePath != nil {
                Button("Remove worktree") { vm.forgeRemoveWorktree() }.buttonStyle(.sh(.secondary))
            }
            if !detail.headBranchDeleted, !detail.deletesBranchOnMerge {
                Button("Delete branch") { Task { await store.perform(.deleteBranch(ref: detail.ref)) } }.buttonStyle(.sh(.strong))
            }
        }
    }
}

/// The merge menu (PRReviewMerge): why merging is blocked, the method, Merge when ready, Delete the
/// branch, Remove the worktree, then Convert to draft and Close pull request.
struct ForgeMergeMenu: View {
    @Bindable var store: ForgeStore
    let detail: PullRequestDetail
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xxs) {
            if let sentence = ForgePresentation.blockerSentence(detail.blockers) {
                HStack(alignment: .top, spacing: SH.Space.m) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Color.sh.failed)
                    Text("\(Text(ForgePresentation.blockedTitle).fontWeight(.semibold)) \(sentence)")
                        .foregroundStyle(Color.sh.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.sh(.ui, weight: .regular))
                .padding(SH.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.sh.failedTint, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                .padding(.bottom, SH.Space.s)
            }
            ForgeCaption("Method").padding(.horizontal, SH.Space.m).padding(.vertical, SH.Space.xs)
            ForEach(detail.mergeMethods, id: \.self) { method in
                row(ForgePresentation.title(method), checked: store.mergeOptions.method == method,
                    note: method == detail.defaultMergeMethod ? "repo default" : nil) { store.mergeOptions.method = method }
            }
            SHHairline().padding(.vertical, SH.Space.xs)
            row("Merge when ready", checked: store.mergeOptions.whenReady, note: "after review and checks") { store.mergeOptions.whenReady.toggle() }
            if !detail.deletesBranchOnMerge {
                row("Delete the branch", checked: store.mergeOptions.deleteBranch) { store.mergeOptions.deleteBranch.toggle() }
            }
            if detail.summary.thread?.worktreePath != nil {
                row("Remove the worktree", checked: store.mergeOptions.removeWorktree, note: "this Mac") { store.mergeOptions.removeWorktree.toggle() }
            }
            SHHairline().padding(.vertical, SH.Space.xs)
            action("Convert to draft", color: Color.sh.textPrimary) { await store.perform(.setDraft(ref: detail.ref, draft: true)) }
            action("Close pull request", color: Color.sh.failed) { await store.perform(.setOpen(ref: detail.ref, open: false)) }
        }
        .padding(SH.Space.s)
        .frame(width: AppLayout.forgeMergeMenuWidth)
        .background(Color.sh.bgRaised)
    }

    private func row(_ title: String, checked: Bool, note: String? = nil, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: "checkmark").font(.sh(.caption)).opacity(checked ? 1 : 0).frame(width: SH.Space.l)
                Text(title).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary)
                Spacer(minLength: SH.Space.m)
                if let note { Text(note).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary) }
            }
            .padding(.horizontal, SH.Space.m)
            .frame(height: SH.Height.controlM)
            .contentShape(Rectangle())
        }
        .buttonStyle(.shRow())
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    private func action(_ title: String, color: Color, perform: @escaping () async -> Bool) -> some View {
        Button {
            close()
            Task { _ = await perform() }
        } label: {
            Text(title).font(.sh(.ui, weight: .regular)).foregroundStyle(color)
                .padding(.horizontal, SH.Space.m)
                .frame(maxWidth: .infinity, minHeight: SH.Height.controlM, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.shRow())
    }
}

/// Submit a review: Comment, Approve or Request changes, with words. Your own pull request takes
/// comments only, as GitHub has it.
private struct ForgeReviewPopover: View {
    let store: ForgeStore
    let detail: PullRequestDetail
    let close: () -> Void
    @State private var verdict: ForgeReviewVerdict = .comment
    @State private var text = ""

    var body: some View {
        let own = detail.viewer.map { $0.caseInsensitiveCompare(detail.summary.author) == .orderedSame } ?? false
        let verdicts: [ForgeReviewVerdict] = own ? [.comment] : ForgeReviewVerdict.allCases
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: SH.Space.l) {
            Text("Submit a review").font(.sh(.title)).foregroundStyle(Color.sh.textPrimary)
            if verdicts.count > 1 {
                SHSegmentedPicker("Review", selection: $verdict, options: verdicts.map { ($0, ForgePresentation.title($0)) })
            }
            TextEditor(text: $text)
                .font(.sh(.body))
                .scrollContentBackground(.hidden)
                .padding(SH.Space.s)
                .frame(height: AppLayout.forgeReviewTextHeight)
                .background(Color.sh.bgWindow, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                .shBorder(Color.sh.lineStrong, radius: SH.Radius.s)
                .accessibilityLabel("Review")
            if own { Text("You can only comment on your own pull request.").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary) }
            HStack {
                Spacer()
                Button("Cancel", action: close).buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
                Button(ForgePresentation.title(verdict)) {
                    let body = text
                    Task { if await store.perform(.review(ref: detail.ref, verdict: verdict, body: body)) { close() } }
                }
                .buttonStyle(.sh(.primary))
                .keyboardShortcut(.defaultAction)
                // A comment or a change request needs words; an approval doesn't.
                .disabled(store.working || (verdict != .approve && empty))
            }
        }
        .padding(SH.Space.xl)
        .frame(width: AppLayout.forgeReviewWidth)
        .background(Color.sh.bgRaised)
    }
}

// MARK: Summary

private struct ForgePullRequestSummary: View {
    var vm: ShepherdViewModel
    @Bindable var store: ForgeStore
    let detail: PullRequestDetail

    var body: some View {
        let summary = detail.summary
        let badge = ForgePresentation.badge(detail.state)
        let now = store.now()
        ForgeColumns {
            HStack(spacing: SH.Space.m) {
                stateMenu(label: badge.label, tone: badge.tone)
                Text("\(summary.ref.repoName) #\(summary.ref.number)").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textTertiary)
            }
            ForgeTitle(title: summary.title, editable: detail.state != .merged) { await store.perform(.editTitle(ref: summary.ref, title: $0)) }
                .padding(.top, SH.Space.l)
            ForgeByline(author: summary.author, you: isViewer(summary.author), verb: nil, age: ForgePresentation.ago(detail.createdAt, now: now),
                        branches: (summary.headRef, summary.baseRef))
                .padding(.top, SH.Space.m)
            if let note = ForgePresentation.stateNote(detail) {
                ForgeStateNote(title: note.title, text: detail.state == .merged ? mergedNote : note.body, tone: badge.tone, closed: detail.state == .closed,
                               trailing: stateEvent(now: now))
                    .padding(.top, SH.Space.l)
            }
            if !store.bodyBlocks.isEmpty {
                Prose(blocks: store.bodyBlocks, maxWidth: AppLayout.forgeContentWidth).padding(.top, SH.Space.xl)
            }
            SHHairline().padding(.vertical, SH.Space.xl)
            ForgeActivity(store: store, events: detail.events, viewer: detail.viewer, kind: .pullRequest)
        } rail: {
            if !detail.reviewers.isEmpty {
                ForgeRailSection(title: "Reviewers") {
                    ForEach(detail.reviewers, id: \.login) { reviewer in
                        HStack(spacing: SH.Space.m) {
                            ForgeAvatar(login: reviewer.login, you: isViewer(reviewer.login))
                            Text(reviewer.login).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary)
                            Spacer()
                            Text(ForgePresentation.label(reviewer.state)).font(.sh(.caption))
                                .foregroundStyle(ForgePresentation.tone(reviewer.state).textColor)
                        }
                        .frame(height: AppLayout.forgeRailRow)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if !detail.checks.isEmpty {
                ForgeRailSection(title: ForgePresentation.checksTitle(detail.checks)) {
                    ForEach(detail.checks) { check in
                        ForgeCheckLine(check: check, fix: check.state == .failing && detail.state != .merged ? { vm.forgeFixCheck(check) } : nil)
                            .frame(height: AppLayout.forgeRailRow)
                    }
                }
            }
            if let thread = summary.thread {
                ForgeRailSection(title: "Thread", divider: false) {
                    ForgeThreadLinkRow(link: thread) { vm.selectAgent(thread.agentID) }
                }
            }
        }
    }

    /// "Merged as 7d41c0a. Closes #28." (the boards' line; the buttons beside it say the rest).
    private var mergedNote: String {
        var text = detail.mergeCommit.map { "Merged as \($0.prefix(7))." } ?? "Merged."
        if !detail.closesIssues.isEmpty { text += " Closes " + detail.closesIssues.map { "#\($0)" }.joined(separator: ", ") + "." }
        return text
    }

    private func isViewer(_ login: String) -> Bool { detail.viewer.map { $0.caseInsensitiveCompare(login) == .orderedSame } ?? false }

    /// "just now · baily": who merged or closed it, and when.
    private func stateEvent(now: Date) -> String? {
        let event = detail.events.last { event in
            switch event.kind {
            case .merged: detail.state == .merged
            case .closed: detail.state == .closed
            case .convertedToDraft: detail.state == .draft
            default: false
            }
        }
        if detail.state == .draft { return "checks still run" }
        return event.map { "\(ForgePresentation.ago($0.at, now: now)) · \($0.actor)" }
    }

    /// The state tag; open and draft pull requests change state from its menu.
    @ViewBuilder private func stateMenu(label: String, tone: ForgeTone) -> some View {
        let ref = detail.ref
        switch detail.state {
        case .merged:
            ForgeStateTag(label: label, tone: tone, symbol: ForgeSymbol.merge)
        default:
            Menu {
                switch detail.state {
                case .open:
                    Button("Convert to Draft") { Task { await store.perform(.setDraft(ref: ref, draft: true)) } }
                    Button("Close Pull Request") { Task { await store.perform(.setOpen(ref: ref, open: false)) } }
                case .draft:
                    Button("Ready for Review") { Task { await store.perform(.setDraft(ref: ref, draft: false)) } }
                    Button("Close Pull Request") { Task { await store.perform(.setOpen(ref: ref, open: false)) } }
                default:
                    Button("Reopen Pull Request") { Task { await store.perform(.setOpen(ref: ref, open: true)) } }
                }
            } label: {
                ForgeStateTag(label: label, tone: tone, symbol: ForgeSymbol.pullRequest, chevron: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(label), change state")
        }
    }
}

/// The card under a draft, merged or closed pull request's title: its dot, what happened, who and when.
private struct ForgeStateNote: View {
    let title: String
    let text: String
    let tone: ForgeTone
    let closed: Bool
    let trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            ForgeDot(tone: tone)
            Text("\(Text(title + ".").fontWeight(.semibold)) \(text)").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: SH.Space.m)
            if let trailing { Text(trailing).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary) }
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.m)
        .background(closed ? Color.sh.failedTint : Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .accessibilityElement(children: .combine)
    }
}

/// A check's line: its glyph, name and duration; a failing one offers Fix with agent.
private struct ForgeCheckLine: View {
    let check: ForgeCheck
    let fix: (() -> Void)?

    var body: some View {
        let tone = ForgePresentation.tone(check.state)
        HStack(spacing: SH.Space.m) {
            if let state = tone.agentState { SHStateGlyph(state, size: SH.Space.l) }
            Text(check.displayName).font(.sh(.ui, weight: .regular))
                .foregroundStyle(check.state == .failing ? tone.textColor : Color.sh.textPrimary)
                .lineLimit(1)
            Spacer(minLength: SH.Space.s)
            if let fix {
                Button("Fix with agent", action: fix).buttonStyle(.sh(.ghost, size: .s))
            } else if let duration = check.duration {
                Text(ForgePresentation.duration(duration)).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Checks

/// The Checks tab: every check, and under a failing one the end of its log, Fix with agent and Re-run failed.
private struct ForgeChecksTab: View {
    var vm: ShepherdViewModel
    let store: ForgeStore
    let detail: PullRequestDetail

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: SH.Space.m) {
                Text(ForgePresentation.checksTitle(detail.checks)).font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary)
                if detail.checks.isEmpty {
                    Text("This pull request has no checks.").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textSecondary)
                }
                ForEach(detail.checks) { check in
                    VStack(alignment: .leading, spacing: SH.Space.m) {
                        HStack(spacing: SH.Space.m) {
                            ForgeCheckLine(check: check, fix: nil)
                            if let workflow = check.workflow { Text(workflow).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary) }
                        }
                        if check.state == .failing {
                            ForgeCheckLog(store: store, check: check)
                            HStack(spacing: SH.Space.m) {
                                Button("Fix with agent") { vm.forgeFixCheck(check) }.buttonStyle(.sh(.secondary, size: .s))
                                if let runID = check.runID {
                                    Button("Re-run failed") { Task { await store.perform(.rerunFailed(repo: detail.ref.repo, runID: runID)) } }
                                        .buttonStyle(.sh(.ghost, size: .s))
                                        .disabled(store.working)
                                }
                            }
                        }
                    }
                    .padding(SH.Space.l)
                    .shCard()
                }
            }
            .frame(maxWidth: AppLayout.forgeContentWidth + AppLayout.forgeRailWidth + AppLayout.forgeColumnGap, alignment: .leading)
            .padding(.top, AppLayout.forgeTopPadding)
            .padding(.bottom, SH.Space.xxxl)
            .padding(.horizontal, SH.Space.xxl)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ForgeCheckLog: View {
    let store: ForgeStore
    let check: ForgeCheck

    var body: some View {
        let log = check.jobID.flatMap { store.logs[$0] }
        Group {
            if let log {
                ScrollView(.vertical) {
                    Text(log.isEmpty ? "The log is empty." : log)
                        .font(.sh(.code))
                        .foregroundStyle(Color.sh.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SH.Space.m)
                }
                .frame(maxHeight: AppLayout.forgeLogMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            } else if check.jobID == nil {
                Text("GitHub keeps no log for this check here.").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            } else {
                SHLoadingRows()
            }
        }
        .task(id: check.jobID) { _ = await store.loadLog(check) }
    }
}

// MARK: Changes

/// The Changes tab (PRReviewChanges): the Changes pane over the pull request's diff, maximized
/// with its file list. Line comments go to the agent as review feedback.
private struct ForgeChangesTab: View {
    var vm: ShepherdViewModel
    let store: ForgeStore
    let detail: PullRequestDetail
    @State private var session: ReviewSession?

    var body: some View {
        Group {
            if let session {
                ReviewPane(session: session, actions: actions(session), maximized: true)
            } else if let error = store.filesError {
                ForgeDetailError(error: error) { store.loadFiles() }
            } else {
                ForgeLoadingPage(number: detail.ref.number)
            }
        }
        .onChange(of: store.files, initial: true) { adopt(store.files) }
    }

    private func adopt(_ files: PullRequestFiles?) {
        guard let files, files.ref == detail.ref else { session = nil; return }
        let next = session ?? ReviewSession(agentID: detail.summary.thread?.agentID ?? AgentID(), paneID: PaneID(), cwd: "",
                                            reference: detail.summary.baseRef)
        next.pullRequestOnly = true
        next.isPRMode = true
        next.adopt(files: files.files.map(\.file), truncated: Set(files.files.filter(\.truncated).map(\.file.id)))
        next.isLoading = false
        session = next
    }

    private func actions(_ session: ReviewSession) -> ReviewActions {
        ReviewActions(
            setPullRequest: { _ in },
            requestChanges: { vm.forgeSendLineComments(session) },
            commit: {},
            close: {},
            refresh: { store.loadFiles() },
            discard: { session.comments = [] })
    }
}
