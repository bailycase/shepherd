import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSidebar

/// An issue's page (IssueReview, IssueStarted): its labels, title, body and Activity; the rail's
/// Hand it to an agent card until a thread works on it, then the linked thread; Leave a comment.
struct ForgeIssuePage: View {
    var vm: ShepherdViewModel
    @Bindable var store: ForgeStore
    let chrome: PageHeaderChrome

    var body: some View {
        let issue = store.issue
        VStack(spacing: 0) {
            ForgeHeaderBar(chrome: chrome, back: vm.leaveForge) {
                if let ref = store.selection {
                    HStack(spacing: SH.Space.m) {
                        Text("Issue #\(ref.number)").font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary)
                        Text(ref.repoName).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textTertiary)
                    }
                    .lineLimit(1)
                }
            } trailing: {
                if let issue { actions(issue) }
            }
            ForgeBanners(vm: vm, store: store)
            if let issue {
                ForgeIssueContent(vm: vm, store: store, issue: issue)
                    .overlay(alignment: .bottom) {
                        ForgeFloatingField(placeholder: "Leave a comment", sendTitle: "Comment", sending: store.working) { text in
                            await store.perform(.comment(ref: issue.ref, body: text))
                        }
                    }
            } else if let error = store.detailError {
                ForgeDetailError(error: error) { Task { await store.loadDetail() } }
            } else if let ref = store.selection {
                ForgeLoadingPage(number: ref.number)
            }
        }
    }

    private func actions(_ issue: IssueDetail) -> some View {
        SHToolbarCapsule {
            ForgeItemButtons(store: store, ref: issue.ref)
            SHBarDivider()
            let open = issue.summary.state == .open
            Button(open ? "Close issue" : "Reopen issue") { Task { await store.perform(.setOpen(ref: issue.ref, open: !open)) } }
                .buttonStyle(.shBar)
                .help(open ? "Close this issue" : "Reopen this issue")
            if let thread = issue.summary.thread {
                Button { vm.selectAgent(thread.agentID) } label: { Text("Open thread").fontWeight(.semibold) }.buttonStyle(.shBar)
            } else if open {
                Button { vm.forgeStartIssueThread() } label: { Label { Text("Start a thread").fontWeight(.semibold) } icon: { Image(systemName: "plus") } }
                    .buttonStyle(.shBar)
                    .disabled(store.path(of: issue.ref.repo) == nil)
                    .help(store.path(of: issue.ref.repo) == nil ? "Add a space for \(issue.ref.repo) to start a thread here" : "Start a thread on a new worktree")
            }
        }
        .disabled(store.working)
    }
}

private struct ForgeIssueContent: View {
    var vm: ShepherdViewModel
    let store: ForgeStore
    let issue: IssueDetail

    var body: some View {
        let summary = issue.summary
        let badge = ForgePresentation.badge(summary.state)
        let now = store.now()
        ForgeColumns {
            ForgeStateTag(label: badge.label, tone: badge.tone, plain: true)
            ForgeTitle(title: summary.title, editable: true) { await store.perform(.editTitle(ref: summary.ref, title: $0)) }
                .padding(.top, SH.Space.l - SH.Space.xxs)
            ForgeByline(author: summary.author, you: isViewer(summary.author), verb: "opened this", age: ForgePresentation.ago(issue.createdAt, now: now))
                .padding(.top, SH.Space.m)
            if !store.bodyProse.isEmpty {
                Prose(prose: store.bodyProse, maxWidth: AppLayout.forgeContentWidth).padding(.top, SH.Space.xl)
            }
            ForgeActivity(store: store, events: issue.events, viewer: issue.viewer, kind: .issue)
        } rail: {
            if let thread = summary.thread {
                ForgeRailSection(title: "Linked") {
                    ForgeThreadLinkRow(link: thread, showsState: true) { vm.selectAgent(thread.agentID) }
                    if issue.linkedPullRequests.isEmpty { noPullRequest }
                }
            } else {
                if summary.state == .open { ForgeHandOffCard(vm: vm, store: store, issue: issue) }
                if issue.linkedPullRequests.isEmpty {
                    ForgeRailSection(title: "Linked") { noPullRequest }
                }
            }
            ForgeRailSection(title: "Assignees") {
                if summary.assignees.isEmpty { Text("No one yet").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textTertiary).frame(minHeight: AppLayout.forgeRailHead) }
                ForEach(summary.assignees, id: \.self) { login in
                    HStack(spacing: SH.Space.m) {
                        ForgeAvatar(login: login, you: isViewer(login))
                        Text(login).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary)
                    }
                    .frame(height: AppLayout.forgeRailRow)
                }
            } accessory: {
                ForgeEditMenu(store: store, field: .assignees, repo: summary.ref.repo, current: summary.assignees)
            }
            ForgeRailSection(title: "Labels") {
                ForgeLabelsLine(labels: summary.labels)
            } accessory: {
                ForgeEditMenu(store: store, field: .labels, repo: summary.ref.repo, current: summary.labels.map(\.name))
            }
            if !issue.linkedPullRequests.isEmpty {
                ForgeRailSection(title: "Related", divider: false) {
                    ForEach(issue.linkedPullRequests, id: \.number) { pull in
                        Button {
                            Task { await store.open(ForgeItemRef(kind: .pullRequest, repo: issue.ref.repo, number: pull.number)) }
                        } label: {
                            HStack(spacing: SH.Space.m) {
                                Image(systemName: ForgeSymbol.pullRequest).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                                    .frame(width: AppLayout.forgeAvatarSize)
                                Text(pull.title ?? "Pull request").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                                Spacer(minLength: SH.Space.s)
                                Text("#\(pull.number)").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                            }
                            .frame(minHeight: AppLayout.forgeRailRow)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func isViewer(_ login: String) -> Bool { issue.viewer.map { $0.caseInsensitiveCompare(login) == .orderedSame } ?? false }

    private var noPullRequest: some View {
        HStack(spacing: SH.Space.m) {
            Image(systemName: ForgeSymbol.pullRequest).font(.sh(.caption)).frame(width: AppLayout.forgeAvatarSize).accessibilityHidden(true)
            Text("No pull request yet").font(.sh(.ui, weight: .regular))
        }
        .foregroundStyle(Color.sh.textTertiary)
        .frame(minHeight: AppLayout.forgeRailRow)
    }
}

/// Hand it to an agent (the boards' `.gch-hand`): what Start a thread does, where it runs, and the link.
private struct ForgeHandOffCard: View {
    var vm: ShepherdViewModel
    let store: ForgeStore
    let issue: IssueDetail

    var body: some View {
        let path = store.path(of: issue.ref.repo)
        let shape = RoundedRectangle(cornerRadius: SH.Radius.l)
        VStack(alignment: .leading, spacing: 0) {
            Text("Hand it to an agent").font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
            Text(path == nil
                 ? "Add a space for \(issue.ref.repo) on this Mac to start a thread on it."
                 : "Starts a thread on a new worktree with this issue as the brief. The PR it opens links back here and closes the issue on merge.")
                .shText(.caption)
                .foregroundStyle(Color.sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, SH.Space.xs)
            if path != nil {
                HStack {
                    Text([issue.ref.repoName, "on this Mac", vm.settings.defaultModel(piHome: vm.pi.home)].compactMap { $0 }.joined(separator: ", "))
                        .font(.sh(.caption))
                        .foregroundStyle(Color.sh.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: SH.Space.m)
                    Button("Start a thread") { vm.forgeStartIssueThread() }
                        .buttonStyle(.shLink(color: Color.sh.textPrimary, font: .sh(.ui, weight: .medium)))
                        .disabled(store.working)
                }
                .padding(.top, SH.Space.l - SH.Space.xxs)
            }
        }
        .padding(.horizontal, AppLayout.forgeBannerSide)
        .padding(.top, SH.Space.l)
        .padding(.bottom, SH.Space.l - SH.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shLift(shape)
        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.l)
        .padding(.bottom, AppLayout.forgeRailGap + SH.Space.xxs)
    }
}
