import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

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
                    Text("\(ref.repoName) #\(ref.number)").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textTertiary)
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
        SHFlowLayout(spacing: SH.Space.m) {
            ForgeItemButtons(store: store, ref: issue.ref)
            let open = issue.summary.state == .open
            Button(open ? "Close issue" : "Reopen issue") { Task { await store.perform(.setOpen(ref: issue.ref, open: !open)) } }
                .buttonStyle(.sh(.secondary))
            if let thread = issue.summary.thread {
                Button("Open thread") { vm.selectAgent(thread.agentID) }.buttonStyle(.sh(.secondary))
            } else if open {
                Button { vm.forgeStartIssueThread() } label: { Label("Start a thread", systemImage: "plus") }
                    .buttonStyle(.sh(.strong))
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
            SHFlowLayout(spacing: SH.Space.s) {
                ForgeStateTag(label: badge.label, tone: badge.tone)
                // A label's GitHub color is the repository's data; tags stay in the theme's.
                ForEach(summary.labels, id: \.name) { label in SHTag(label.name) }
            }
            ForgeTitle(title: summary.title, editable: true) { await store.perform(.editTitle(ref: summary.ref, title: $0)) }
                .padding(.top, SH.Space.l)
            ForgeByline(author: summary.author, you: isViewer(summary.author), verb: "opened", age: ForgePresentation.ago(issue.createdAt, now: now))
                .padding(.top, SH.Space.m)
            if !store.bodyBlocks.isEmpty {
                Prose(blocks: store.bodyBlocks, maxWidth: AppLayout.forgeContentWidth).padding(.top, SH.Space.xl)
            }
            SHHairline().padding(.vertical, SH.Space.xl)
            ForgeActivity(store: store, events: issue.events, viewer: issue.viewer, kind: .issue)
        } rail: {
            if let thread = summary.thread {
                ForgeRailSection(title: "Linked") {
                    ForgeThreadLinkRow(link: thread) { vm.selectAgent(thread.agentID) }
                    if issue.linkedPullRequests.isEmpty {
                        Label("No pull request yet", systemImage: ForgeSymbol.pullRequest)
                            .font(.sh(.ui, weight: .regular))
                            .foregroundStyle(Color.sh.textTertiary)
                    }
                }
            } else if summary.state == .open {
                ForgeHandOffCard(vm: vm, store: store, issue: issue)
            }
            if !summary.assignees.isEmpty {
                ForgeRailSection(title: summary.assignees.count == 1 ? "Assignee" : "Assignees") {
                    ForEach(summary.assignees, id: \.self) { login in
                        HStack(spacing: SH.Space.m) {
                            ForgeAvatar(login: login, you: isViewer(login))
                            Text(isViewer(login) ? "you" : login).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary)
                        }
                        .frame(height: AppLayout.forgeRailRow)
                    }
                }
            }
            if !issue.linkedPullRequests.isEmpty {
                ForgeRailSection(title: "Related", divider: false) {
                    ForEach(issue.linkedPullRequests, id: \.number) { pull in
                        Button {
                            Task { await store.open(ForgeItemRef(kind: .pullRequest, repo: issue.ref.repo, number: pull.number)) }
                        } label: {
                            HStack(spacing: SH.Space.m) {
                                Image(systemName: ForgeSymbol.pullRequest).font(.sh(.caption)).foregroundStyle(ForgeTone.done.color)
                                Text("#\(pull.number)").font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
                                Text(pull.title ?? "Pull request").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                            }
                            .frame(height: AppLayout.forgeRailRow)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func isViewer(_ login: String) -> Bool { issue.viewer.map { $0.caseInsensitiveCompare(login) == .orderedSame } ?? false }
}

/// Hand it to an agent (IssueReview): what Start a thread does, where it runs, and the button.
private struct ForgeHandOffCard: View {
    var vm: ShepherdViewModel
    let store: ForgeStore
    let issue: IssueDetail

    var body: some View {
        let path = store.path(of: issue.ref.repo)
        VStack(alignment: .leading, spacing: SH.Space.m) {
            Text("Hand it to an agent").font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary)
            Text(path == nil
                 ? "Add a space for \(issue.ref.repo) on this Mac to start a thread on it."
                 : "Starts a thread on a new worktree with this issue as the brief. The PR it opens links back here and closes the issue on merge.")
                .font(.sh(.caption))
                .foregroundStyle(Color.sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if path != nil {
                SHFlowLayout(spacing: SH.Space.s) {
                    SHTag("this Mac", mono: true)
                    if let model = vm.settings.defaultModel(piHome: vm.server.pi.home) { SHTag(model, mono: true) }
                    SHTag("new worktree", mono: true)
                }
                Button("Start a thread") { vm.forgeStartIssueThread() }
                    .buttonStyle(.sh(.primary))
                    .disabled(store.working)
            }
        }
        .padding(SH.Space.l)
        .shCard()
    }
}
