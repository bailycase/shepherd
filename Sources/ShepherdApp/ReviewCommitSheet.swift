import AppKit
import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The review pane's Commit… sheet (the iPadCommit board as a Mac dialog): the message drafted
/// from the diff, the changed files with their checkboxes (all ticked), Push after commit or Open
/// a pull request instead, then the host's steps as it runs them. Ask agent to commit sends the
/// agent the old Commit turn instead. The host checks the checkout again before it commits.
struct ReviewCommitSheet: View {
    @Bindable var store: ReviewCommitStore
    /// Asks the agent to commit instead (the review's former Commit); nil where it can't.
    let askAgent: (() -> Void)?
    let close: () -> Void
    /// Set by previews: the sheet shows the store as it is and asks the host nothing.
    var staged = false

    var body: some View {
        NWDialog(title, message: subtitle, width: AppLayout.commitSheetWidth) {
            content
        } status: {
            status
        } actions: {
            actions
        }
        .nwAnimation(.disclosure, value: store.stage)
        .nwAnimation(.content, value: store.drafting)
        .task {
            guard !staged else { return }
            await store.begin()
        }
        .task(id: store.operationID) {
            guard !staged, store.operationID != nil else { return }
            await store.poll()
        }
    }

    // MARK: Header

    private var title: String {
        switch store.outcome {
        case .running?: return "Committing…"
        case .succeeded(let url)?: return url == nil ? "Committed" : "Pull request opened"
        case .failed?: return "Commit stopped"
        case nil:
            let count = store.selectedFiles.count
            return count == 0 ? "Commit" : "Commit \(count) file\(count == 1 ? "" : "s")"
        }
    }

    private var subtitle: String? {
        switch store.stage {
        case .loading: return "Reading the checkout…"
        case .unavailable: return nil
        case .form:
            guard let info = store.info else { return nil }
            let place = (info.repository as NSString).abbreviatingWithTildeInPath
            return info.branch.map { "On \($0) in \(place)." } ?? "In \(place)."
        case .operation:
            switch store.outcome {
            case .failed?: return "A step failed, so the rest didn't run."
            case .succeeded?: return nil
            default: return "Each step must succeed before the next runs. Nothing is ever force-pushed."
            }
        }
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        switch store.stage {
        case .loading:
            EmptyView()
        case .unavailable(let message):
            NWBanner(.failed, title: "Can't commit from here", message: message)
                .padding(.horizontal, NWDialogMetrics.inset)
        case .form:
            form
        case .operation:
            progress
        }
    }

    private var form: some View {
        let inset = NWDialogMetrics.inset
        return VStack(alignment: .leading, spacing: NW.Space.l) {
            if let blocked = store.info?.blocked {
                NWBanner(.failed, title: "Can't commit here", message: blocked)
            } else if store.info?.agentWorking == true {
                NWBanner(.attention, title: "The agent is working",
                         message: "Its files may still change. Shepherd commits them as they were when this sheet opened, and stops if one changed since.")
                Toggle("Commit while it works", isOn: $store.confirmedWhileWorking)
                    .toggleStyle(.nwCheckbox)
                    .font(.nw(.ui))
                    .foregroundStyle(Color.nw.textPrimary)
            }
            if let error = store.error {
                NWBanner(.failed, title: "Nothing was committed", message: error)
            }
            NWCommitMessageEditor(title: $store.title, message: $store.body,
                                  source: store.drafting ? .drafting : store.drafted ? .drafted : .written,
                                  mentionsUntickedFiles: store.mentionsUntickedFiles)
            VStack(alignment: .leading, spacing: NW.Space.s) {
                HStack {
                    Text("Files").font(.nw(.ui, weight: .semibold)).foregroundStyle(Color.nw.textSecondary)
                    Spacer(minLength: NW.Space.s)
                    Text(store.selectionText).font(.nw(.mono)).foregroundStyle(Color.nw.textTertiary)
                    Button(store.selectedFiles.count == store.rows.count ? "Select None" : "Select All") {
                        store.selectAll(store.selectedFiles.count != store.rows.count)
                    }
                    .buttonStyle(.nwLink(font: .nw(.caption)))
                }
                .accessibilityElement(children: .contain)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.rows) { row in
                            VStack(spacing: 0) {
                                if row.id != store.rows.first?.id { NWHairline() }
                                NWCommitFileRow(NWCommitFileRow.Item(row)) { store.toggle(row.id) }.equatable()
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: AppLayout.commitFileListMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .nwCard()
            }
            if let info = store.info {
                VStack(spacing: 0) {
                    NWCommitOptionRow("Push after commit", detail: reviewCommitPushDetail(info), monoDetail: true,
                                      isOn: Binding(get: { store.push || store.pullRequest }, set: { store.push = $0 }))
                        .disabled(store.pullRequest || !reviewCommitCanPush(info))
                    NWHairline()
                    NWCommitOptionRow("Open a pull request instead", detail: reviewCommitPullRequestDetail(info, title: store.title),
                                      isOn: $store.pullRequest)
                        .disabled(!reviewCommitCanOpenPullRequest(info))
                }
                .nwCard()
            }
        }
        .padding(.horizontal, inset)
        .disabled(store.info?.blocked != nil)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.steps) { step in
                NWChecklistRow(step.label.prefix(1).uppercased() + step.label.dropFirst(), state: agentState(step.state),
                               detail: detail(step.state))
            }
            if case .failed(let message)? = store.outcome {
                NWBanner(.failed, title: "Stopped", message: message)
                    .padding(.horizontal, NWDialogMetrics.inset)
                    .padding(.top, NW.Space.l)
            }
            if let error = store.error {
                NWBanner(.attention, title: "Outcome not yet known", message: error)
                    .padding(.horizontal, NWDialogMetrics.inset)
                    .padding(.top, NW.Space.l)
            }
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var status: some View {
        switch store.stage {
        case .loading:
            HStack(spacing: NW.Space.s) {
                ProgressView().progressViewStyle(.nwSpinner)
                NWDialogStatus("Reading the checkout…")
            }
        case .form:
            if store.error == nil, let problem = store.problem, let info = store.info, info.blocked == nil,
                      !(info.agentWorking && !store.confirmedWhileWorking) {
                // A refusal and the working agent's confirmation have their banners.
                NWDialogStatus(problem)
            }
        case .operation:
            if store.outcome == .running || store.outcome == nil {
                HStack(spacing: NW.Space.s) {
                    ProgressView().progressViewStyle(.nwSpinner)
                    NWDialogStatus("Working…")
                }
            }
        case .unavailable:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch store.stage {
        case .loading, .unavailable, .form:
            if let askAgent {
                Button("Ask Agent to Commit") { askAgent(); close() }
                    .buttonStyle(.nw(.ghost))
                    .help("Send the agent a turn asking it to commit these changes")
            }
            Button("Cancel", action: close)
                .buttonStyle(.nw(.ghost))
                .keyboardShortcut(.cancelAction)
            if store.stage == .form {
                Button(store.actionTitle) { Task { await store.commit() } }
                    .buttonStyle(.nw(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.canCommit)
            }
        case .operation:
            if let url = store.operation?.prURL, let link = URL(string: url) {
                Button("Open Pull Request") { NSWorkspace.shared.open(link) }
                    .buttonStyle(.nw(.secondary))
            }
            if store.operation?.finished == true {
                Button("Done", action: close)
                    .buttonStyle(.nw(.primary))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Close", action: close)
                    .buttonStyle(.nw(.secondary))
                    .keyboardShortcut(.cancelAction)
                    .help("The commit keeps running; open Commit… again to see it")
            }
        }
    }

    private func agentState(_ state: FinalizeStep.State) -> AgentState {
        switch state {
        case .pending: .queued
        case .running: .running
        case .done: .done
        case .failed: .failed
        }
    }

    private func detail(_ state: FinalizeStep.State) -> String? {
        switch state {
        case .done(let text), .failed(let text): text
        case .pending, .running: nil
        }
    }
}

extension NWCommitFileRow.Item {
    init(_ row: ReviewCommitFileRow) {
        self.init(id: row.id, name: row.name, directory: row.directory, status: NWFileStatus(row.status), added: row.added,
                  removed: row.removed, selected: row.selected)
    }
}

extension NWFileStatus {
    init(_ status: ReviewFileStatus) {
        switch status {
        case .modified: self = .modified
        case .added: self = .added
        case .deleted: self = .deleted
        case .renamed: self = .renamed
        }
    }
}
