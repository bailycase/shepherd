import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSidebar

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
                if let detail {
                    ForgePullRequestActions(vm: vm, store: store, detail: detail, mergeMenu: $store.mergeMenuOpen)
                } else if let ref = store.selection {
                    // While it loads the capsule holds its place, the actions off.
                    SHToolbarCapsule {
                        ForgeItemButtons(store: store, ref: ref)
                        SHBarDivider()
                        Button("Review with agent") {}.buttonStyle(.shBar).disabled(true)
                        Button("Submit review") {}.buttonStyle(.shBar).disabled(true)
                        Button { } label: { Text("Merge").fontWeight(.semibold) }.buttonStyle(.shBar).disabled(true)
                    }
                }
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
                case .checks:
                    ForgePullRequestSummary(vm: vm, store: store, detail: detail, checksOnly: true)
                        .overlay(alignment: .bottom) {
                            ForgeFloatingField(placeholder: "Ask the agent about this pull request", sendTitle: nil,
                                               sending: false) { await vm.forgeAsk($0) }
                        }
                }
            } else if let error = store.detailError {
                ForgeDetailError(error: error) { Task { await store.loadDetail() } }
            } else if let ref = store.selection {
                ForgeLoadingPage(number: ref.number)
            }
        }
        .overlay(alignment: .topTrailing) {
            if store.mergeMenuOpen, let detail, detail.state == .open {
                ZStack(alignment: .topTrailing) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { store.mergeMenuOpen = false }
                    ForgeMergeMenu(store: store, detail: detail) { store.mergeMenuOpen = false }
                        .padding(.top, SHToolbarMetrics.height)
                        .padding(.trailing, SH.Space.m)
                        .onExitCommand { store.mergeMenuOpen = false }
                }
                .shTransition(.overlay, anchor: .topTrailing)
            }
        }
        .shAnimation(.content, value: store.mergeMenuOpen)
    }
}

/// Summary | Changes +200 −8 | Checks 1 failing, in a track (the boards' `.segc.gch-tabs`); in the side pane (PRPane)
/// Overview | Files 5 +200 −8 | Checks •, clear of the pane's own Changes tab.
struct ForgeTabs: View {
    @Bindable var store: ForgeStore
    let detail: PullRequestDetail?
    var pane = false

    var body: some View {
        HStack(spacing: pane ? SH.Space.xs : SH.Space.xxs) {
            tab(.summary) { Text(pane ? "Overview" : "Summary") }
            tab(.changes) {
                HStack(spacing: pane ? SH.Space.s : AppLayout.forgeTabGap) {
                    Text(pane ? "Files \(detail?.changedFiles ?? 0)" : "Changes")
                    if let summary = detail?.summary { SHDiffStat(added: summary.additions, removed: summary.deletions, font: pane ? .sh(.caption) : .sh(.caption, weight: .regular)) }
                }
            }
            tab(.checks) {
                HStack(spacing: pane ? SH.Space.s : AppLayout.forgeTabGap) {
                    Text("Checks")
                    checks
                }
            }
        }
        // The pane's tabs are bare (GXPanePR `.seg2`); the page's sit in a track.
        .padding(pane ? 0 : SH.Space.xxs)
        .background(pane ? Color.clear : Color.sh.bgHover, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .fixedSize()
        .disabled(detail == nil)
    }

    /// The Checks tab's word: "1 failing" in red, else the state's dot.
    @ViewBuilder private var checks: some View {
        if let detail, let tone = ForgePresentation.tone(detail.summary.checks) {
            let failing = detail.checks.filter { $0.state == .failing }.count
            if !pane, tone == .failed, failing > 0 {
                Text("\(failing) failing").font(.sh(.caption, weight: .regular)).foregroundStyle(Color.sh.failed)
            } else if !pane, tone == .done {
                Text("\(detail.checks.filter { $0.state == .passed }.count) passed").font(.sh(.caption, weight: .regular)).foregroundStyle(Color.sh.textTertiary)
            } else {
                ForgeDot(tone: tone)
            }
        }
    }

    private func tab<Label: View>(_ value: ForgeStore.Tab, @ViewBuilder label: () -> Label) -> some View {
        let selected = store.tab == value
        let shape = RoundedRectangle(cornerRadius: pane ? SH.Radius.s : SH.Radius.s)
        return Button { store.tab = value } label: {
            label()
                .font(.sh(.ui, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.sh.textPrimary : Color.sh.textSecondary)
                .padding(.horizontal, pane ? SH.Space.m + SH.Space.xxs : AppLayout.forgeTabPadding)
                .frame(height: pane ? AppLayout.prPaneTabHeight : AppLayout.forgeTabHeight)
                .background {
                    if selected { pane ? AnyView(shape.fill(Color.sh.bgSelected)) : AnyView(Color.clear.shLift(shape)) }
                }
                .contentShape(Rectangle())
                .shFocusRing(radius: SH.Radius.s)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Header actions

/// Pin, link, GitHub; Review with agent; Submit review; then the state's own action: Merge and
/// its menu, Ready for review, Reopen, or Remove worktree and Delete branch. All in the header's
/// capsule (the boards' `.cap`).
private struct ForgePullRequestActions: View {
    var vm: ShepherdViewModel
    @Bindable var store: ForgeStore
    let detail: PullRequestDetail
    @Binding var mergeMenu: Bool
    @State private var review = false

    var body: some View {
        SHToolbarCapsule {
            ForgeItemButtons(store: store, ref: detail.ref)
            SHBarDivider()
            Button("Review with agent") { vm.forgeReviewWithAgent() }
                .buttonStyle(.shBar)
                .help("Start a thread that reviews this pull request and reports back")
            if detail.state == .open || detail.state == .draft {
                Button("Submit review") { review = true }
                    .buttonStyle(.shBar)
                    .help("Submit a review")
                    .popover(isPresented: $review, arrowEdge: .bottom) { ForgeReviewPopover(store: store, detail: detail) { review = false } }
            }
            primary
        }
        .disabled(store.working)
    }

    private func strong(_ title: String) -> some View { Text(title).fontWeight(.semibold) }

    @ViewBuilder private var primary: some View {
        switch detail.state {
        case .open:
            HStack(spacing: 0) {
                Button { vm.forgeMerge() } label: { strong("Merge") }
                    .buttonStyle(.shBar)
                    .help(store.mergeOptions.whenReady ? "\(ForgePresentation.title(store.mergeOptions.method)) when reviews and checks allow"
                          : ForgePresentation.title(store.mergeOptions.method))
                Button { mergeMenu.toggle() } label: { Image(systemName: "chevron.down").font(.shSans(AppLayout.forgeChevron, .semibold)).foregroundStyle(Color.sh.textTertiary) }
                    .buttonStyle(.shBar)
                    .padding(.leading, -SH.Space.s)
                    .accessibilityLabel("Merge options")
            }
            .background(mergeMenu ? Color.sh.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
        case .draft:
            Button { Task { await store.perform(.setDraft(ref: detail.ref, draft: false)) } } label: { strong("Ready for review") }.buttonStyle(.shBar)
        case .closed:
            Button { Task { await store.perform(.setOpen(ref: detail.ref, open: true)) } } label: { strong("Reopen") }.buttonStyle(.shBar)
        case .merged:
            if detail.summary.thread?.worktreePath != nil {
                Button("Remove worktree") { vm.forgeRemoveWorktree() }.buttonStyle(.shBar)
            }
            if !detail.headBranchDeleted, !detail.deletesBranchOnMerge {
                Button { Task { await store.perform(.deleteBranch(ref: detail.ref)) } } label: { strong("Delete branch") }.buttonStyle(.shBar)
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
        SHPopMenu(width: AppLayout.forgeMergeMenuWidth) {
            if let sentence = ForgePresentation.blockerSentence(detail.blockers) {
                HStack(alignment: .top, spacing: SH.Space.m) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Color.sh.failed)
                    Text("\(Text(ForgePresentation.blockedTitle).fontWeight(.semibold)) \(sentence)")
                        .foregroundStyle(Color.sh.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.sh(.ui, weight: .regular))
                .padding(.horizontal, SH.Space.l - SH.Space.xxs)
                .padding(.vertical, SH.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.sh.bgHover, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                .padding(.bottom, SH.Space.s)
            }
            SHPopMenuHeader("Method")
            ForEach(detail.mergeMethods, id: \.self) { method in
                SHPopMenuRow(ForgePresentation.title(method), lead: .check(store.mergeOptions.method == method),
                             trailing: method == detail.defaultMergeMethod ? "repo default" : nil) { store.mergeOptions.method = method }
            }
            SHPopMenuSeparator()
            SHPopMenuRow("Merge when ready", lead: .check(store.mergeOptions.whenReady), trailing: "after review and checks") { store.mergeOptions.whenReady.toggle() }
            if !detail.deletesBranchOnMerge {
                SHPopMenuRow("Delete the branch", lead: .check(store.mergeOptions.deleteBranch)) { store.mergeOptions.deleteBranch.toggle() }
            }
            if detail.summary.thread?.worktreePath != nil {
                SHPopMenuRow("Remove the worktree", lead: .check(store.mergeOptions.removeWorktree), trailing: "this Mac") { store.mergeOptions.removeWorktree.toggle() }
            }
            SHPopMenuSeparator()
            SHPopMenuRow("Convert to draft", lead: .check(false)) {
                close()
                Task { _ = await store.perform(.setDraft(ref: detail.ref, draft: true)) }
            }
            ForgeDestructiveMenuRow(title: "Close pull request") {
                close()
                Task { _ = await store.perform(.setOpen(ref: detail.ref, open: false)) }
            }
        }
    }
}

/// A menu row in `failed` (the boards' `.mi.red`), set like `SHPopMenuRow`'s.
private struct ForgeDestructiveMenuRow: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(title)
            .font(.sh(.ui))
            .foregroundStyle(Color.sh.failed)
            .padding(.leading, SHPopMenuMetrics.rowInset + SHPopMenuMetrics.checkWidth + SHPopMenuMetrics.rowSpacing)
            .frame(maxWidth: .infinity, minHeight: SHPopMenuMetrics.rowHeight, alignment: .leading)
            .background(hovering ? Color.sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
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
    /// The Checks tab: the same head, then the checks and their logs; the rail keeps only Reviewers and Thread.
    var checksOnly = false

    var body: some View {
        let summary = detail.summary
        let badge = ForgePresentation.badge(detail.state)
        let now = store.now()
        ForgeColumns {
            HStack(spacing: SH.Space.m) {
                stateMenu(label: badge.label, tone: badge.tone)
                Text("\(summary.ref.repoName) #\(summary.ref.number)").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textTertiary)
            }
            ForgeTitle(title: summary.title, editable: detail.state != .merged, lineSpacing: AppLayout.forgeTitleLineSpacing) { await store.perform(.editTitle(ref: summary.ref, title: $0)) }
                .padding(.top, SH.Space.l - SH.Space.xxs)
            ForgeByline(author: summary.author, you: isViewer(summary.author), verb: "opened this", age: ForgePresentation.ago(detail.createdAt, now: now),
                        branches: (summary.headRef, summary.baseRef))
                .padding(.top, SH.Space.m)
            if let note = ForgePresentation.stateNote(detail) {
                ForgeStateNote(title: note.title, text: detail.state == .merged ? mergedNote : note.body, tone: badge.tone, closed: detail.state == .closed,
                               trailing: stateEvent(now: now))
                    .padding(.top, SH.Space.xl)
            }
            if checksOnly {
                ForgeChecksBlock(vm: vm, store: store, detail: detail)
            } else {
                if !store.bodyProse.isEmpty {
                    Prose(prose: store.bodyProse, maxWidth: AppLayout.forgeContentWidth).padding(.top, SH.Space.xl)
                }
                ForgeActivity(store: store, events: detail.events, viewer: detail.viewer, kind: .pullRequest)
            }
        } rail: {
            if !detail.reviewers.isEmpty || detail.state == .open || detail.state == .draft {
                ForgeRailSection(title: "Reviewers") {
                    if detail.reviewers.isEmpty { Text("No one asked yet").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary) }
                    ForEach(detail.reviewers, id: \.login) { reviewer in
                        HStack(spacing: SH.Space.m) {
                            ForgeAvatar(login: reviewer.login, you: isViewer(reviewer.login))
                            Text(reviewer.login).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary)
                            Spacer()
                            Text(ForgePresentation.label(reviewer.state).forgeCapitalized).font(.sh(.caption))
                                .foregroundStyle(Color.sh.textTertiary)
                        }
                        .frame(height: AppLayout.forgeRailRow)
                        .accessibilityElement(children: .combine)
                    }
                } accessory: {
                    if detail.state != .merged, detail.state != .closed {
                        ForgeEditMenu(store: store, field: .reviewers, repo: detail.ref.repo,
                                      current: detail.reviewers.filter { !$0.isTeam && $0.state == .pending }.map(\.login))
                    }
                }
            }
            if !checksOnly, let assignees = detail.assignees, let labels = detail.labels {
            ForgeRailSection(title: "Assignees") {
                if assignees.isEmpty { Text("No one yet").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary) }
                ForEach(assignees, id: \.self) { login in
                    HStack(spacing: SH.Space.m) {
                        ForgeAvatar(login: login, you: isViewer(login))
                        Text(login).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary)
                    }
                    .frame(height: AppLayout.forgeRailRow)
                }
            } accessory: {
                ForgeEditMenu(store: store, field: .assignees, repo: detail.ref.repo, current: assignees)
            }
            ForgeRailSection(title: "Labels") {
                ForgeLabelsLine(labels: labels)
            } accessory: {
                ForgeEditMenu(store: store, field: .labels, repo: detail.ref.repo, current: labels.map(\.name))
            }
            }
            if !checksOnly, !detail.checks.isEmpty {
                ForgeRailSection(title: ForgePresentation.checksTitle(detail.checks).replacingOccurrences(of: " · ", with: ", ")) {
                    ForEach(detail.checks) { check in
                        ForgeCheckLine(check: check, fix: check.state == .failing && detail.state != .merged ? { vm.forgeFixCheck(check) } : nil)
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
        return event.map { "\(ForgePresentation.ago($0.at, now: now)) · \($0.actor)" }
    }

    /// The state tag; open and draft pull requests change state from its menu.
    @ViewBuilder private func stateMenu(label: String, tone: ForgeTone) -> some View {
        let ref = detail.ref
        switch detail.state {
        case .merged:
            ForgeStateTag(label: label, tone: tone, plain: true)
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
                ForgeStateTag(label: label, tone: tone, chevron: true, plain: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(label), change state")
        }
    }
}

/// The card under a draft, merged or closed pull request's title (the boards' `.gch-ban`): what happened in semibold and who
/// and when at the trailing edge, then what it means.
private struct ForgeStateNote: View {
    let title: String
    let text: String
    let tone: ForgeTone
    let closed: Bool
    let trailing: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SH.Radius.l)
        VStack(alignment: .leading, spacing: SH.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                Text(title).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
                Spacer(minLength: SH.Space.m)
                if let trailing { Text(trailing).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary) }
            }
            Text(text).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppLayout.forgeBannerSide)
        .padding(.top, AppLayout.forgeBannerTop)
        .padding(.bottom, AppLayout.forgeBannerBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(closed ? Color.sh.failedTint : Color.clear, in: shape)
        .shLift(shape)
        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.l)
        .accessibilityElement(children: .combine)
    }
}

/// A check's line (the boards' `.gch-ckr`): its glyph, name and duration, the failing one in `failed`; a failing one
/// offers Fix with agent under it.
struct ForgeCheckLine: View {
    let check: ForgeCheck
    let fix: (() -> Void)?

    var body: some View {
        let tone = ForgePresentation.tone(check.state)
        let failing = check.state == .failing
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SH.Space.m) {
                Group {
                    if let state = tone.agentState { SHStateGlyph(state, size: SH.Space.l) }
                }
                .frame(width: AppLayout.forgeAvatarSize - SH.Space.xxs)
                Text(check.displayName).font(.sh(.ui, weight: .regular))
                    .foregroundStyle(failing ? tone.textColor : Color.sh.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: SH.Space.s)
                if let duration = check.duration {
                    Text(ForgePresentation.duration(duration)).font(.sh(.caption))
                        .foregroundStyle(failing ? tone.textColor : Color.sh.textTertiary)
                }
            }
            .frame(minHeight: AppLayout.forgeRailRow)
            if let fix {
                Button("Fix with agent", action: fix)
                    .buttonStyle(.shLink(color: Color.sh.textPrimary, font: .sh(.ui, weight: .medium)))
                    .padding(.leading, AppLayout.forgeAvatarSize + SH.Space.xxs)
                    .padding(.bottom, SH.Space.xxs)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Checks

/// The Checks tab's body (the boards' `.gch-ckh` and `.gch-cks`): the count and its workflow, then every check in a card, a
/// failing one open on the end of its log with Fix with agent and Re-run failed.
private struct ForgeChecksBlock: View {
    var vm: ShepherdViewModel
    let store: ForgeStore
    let detail: PullRequestDetail

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SH.Radius.l)
        let workflows = detail.checks.compactMap(\.workflow).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(ForgePresentation.checksTitle(detail.checks).replacingOccurrences(of: " · ", with: ", "))
                    .font(.sh(.body, weight: .semibold))
                    .foregroundStyle(Color.sh.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: SH.Space.m)
                if !workflows.isEmpty {
                    Text(workflows.joined(separator: ", ")).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textTertiary)
                }
            }
            .padding(.top, AppLayout.forgeChecksTop)
            .padding(.bottom, SH.Space.m)
            if detail.checks.isEmpty {
                Text("This pull request has no checks.").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(detail.checks.enumerated()), id: \.element.id) { index, check in
                        if index > 0 { SHHairline() }
                        row(check)
                        if check.state == .failing { log(check) }
                    }
                }
                .padding(.vertical, SH.Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .shLift(shape)
                .shBorder(Color.sh.lineSubtle, radius: SH.Radius.l)
            }
        }
    }

    private func row(_ check: ForgeCheck) -> some View {
        let tone = ForgePresentation.tone(check.state)
        return HStack(spacing: AppLayout.forgeCheckGap) {
            Group {
                if let state = tone.agentState { SHStateGlyph(state, size: SH.Space.l) }
            }
            .frame(width: SH.Space.l)
            Text(check.displayName).font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
            Spacer(minLength: SH.Space.m)
            if let duration = check.duration {
                Text(ForgePresentation.duration(duration)).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textTertiary)
            }
        }
        .padding(.horizontal, AppLayout.forgeCheckInset)
        .frame(height: AppLayout.forgeCheckRow)
        .accessibilityElement(children: .combine)
    }

    private func log(_ check: ForgeCheck) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForgeCheckLog(store: store, check: check)
            HStack(spacing: SH.Space.xl) {
                Button("Fix with agent") { vm.forgeFixCheck(check, store: store) }
                    .buttonStyle(.shLink(color: Color.sh.textPrimary, font: .sh(.ui, weight: .medium)))
                if let runID = check.runID {
                    Button("Re-run failed") { Task { await store.perform(.rerunFailed(repo: detail.ref.repo, runID: runID)) } }
                        .buttonStyle(.shLink(color: Color.sh.textSecondary, font: .sh(.ui, weight: .regular)))
                        .disabled(store.working)
                }
                Spacer(minLength: SH.Space.m)
                if check.jobID.flatMap({ store.logs[$0] }) != nil {
                    Text("The end of the log").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
            }
            .padding(.top, SH.Space.l - SH.Space.xxs)
        }
        .padding(.leading, AppLayout.forgeCheckLogLeading)
        .padding(.trailing, AppLayout.forgeCheckInset)
        .padding(.bottom, SH.Space.l)
    }
}

/// The Checks tab: every check, and under a failing one the end of its log, Fix with agent and Re-run failed.
struct ForgeChecksTab: View {
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
                                Button("Fix with agent") { vm.forgeFixCheck(check, store: store) }.buttonStyle(.sh(.secondary, size: .s))
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
                        .font(.shMono(SHTextStyle.caption.size))
                        .lineSpacing(AppLayout.forgeLogLineSpacing)
                        .foregroundStyle(Color.sh.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, SH.Space.m)
                        .padding(.horizontal, SH.Space.l)
                }
                .frame(maxHeight: AppLayout.forgeLogMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color.sh.bgHover, in: RoundedRectangle(cornerRadius: SH.Radius.m))
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
struct ForgeChangesTab: View {
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
            requestChanges: { vm.forgeSendLineComments(session, store: store) },
            postToGitHub: { vm.forgePostLineComments(session, store: store) },
            commit: {},
            close: {},
            refresh: { store.loadFiles() },
            discard: { session.comments = [] })
    }
}
