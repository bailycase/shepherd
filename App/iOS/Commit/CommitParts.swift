import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// The parts the phone's commit sheet and the iPad's popover share: the message, the files with
// their checkboxes, the options, why the host won't commit, and the host's steps.

extension MobileLayout {
    /// The iPad's commit popover (the iPadCommit board's 400pt).
    static let commitPopoverWidth: CGFloat = 400
    /// The most the popover's file list grows before it scrolls.
    static let commitPopoverFilesHeight: CGFloat = 220
}

/// The message card, with where it came from.
struct CommitMessageCard: View {
    @Bindable var store: ReviewCommitStore
    var fill: Color? = nil

    var body: some View {
        NWCommitMessageEditor(title: $store.title, message: $store.body,
                              source: store.drafting ? .drafting : store.drafted ? .drafted : .written,
                              mentionsUntickedFiles: store.mentionsUntickedFiles, radius: MobileLayout.cardRadius, fill: fill)
    }
}

/// The changed files, each with its checkbox; all go in until unticked.
struct CommitFileList: View {
    let store: ReviewCommitStore

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(store.rows) { row in
                VStack(spacing: 0) {
                    if row.id != store.rows.first?.id { NWHairline() }
                    NWCommitFileRow(NWCommitFileRow.Item(row), showsDirectory: false) { store.toggle(row.id) }.equatable()
                }
            }
        }
    }
}

/// Push after commit, and Open a pull request instead.
struct CommitOptions: View {
    @Bindable var store: ReviewCommitStore

    var body: some View {
        if let info = store.info {
            NWCommitOptionRow("Push after commit", detail: reviewCommitPushDetail(info), monoDetail: true,
                              isOn: Binding(get: { store.push || store.pullRequest }, set: { store.push = $0 }))
                .disabled(store.pullRequest || !reviewCommitCanPush(info))
            NWHairline()
            NWCommitOptionRow("Open a pull request instead", detail: reviewCommitPullRequestDetail(info, title: store.title),
                              isOn: $store.pullRequest)
                .disabled(!reviewCommitCanOpenPullRequest(info))
        }
    }
}

/// Why the host won't commit here, or that the agent is still working (with the confirmation).
struct CommitNotices: View {
    @Bindable var store: ReviewCommitStore

    var body: some View {
        if let blocked = store.info?.blocked {
            NWBanner(.failed, title: "Can't commit here", message: blocked)
        } else if store.info?.agentWorking == true {
            VStack(alignment: .leading, spacing: NW.Space.s) {
                NWBanner(.attention, title: "The agent is working",
                         message: "Its files may still change. The host commits them as they were when this opened, and stops if one changed since.")
                Toggle("Commit while it works", isOn: $store.confirmedWhileWorking)
                    .toggleStyle(.nwCheckbox)
                    .font(.nw(.ui))
                    .foregroundStyle(Color.nw.textPrimary)
                    .frame(minHeight: NW.Height.touch)
                    .padding(.horizontal, NW.Space.xs)
            }
        }
        if let error = store.error, store.stage == .form {
            NWBanner(.failed, title: "Nothing was committed", message: error) {
                Button("Dismiss") { store.error = nil }.buttonStyle(.nw(.ghost, size: .s))
            }
        }
    }
}

/// The host's steps as it runs them, how it ended, and the pull request it opened.
struct CommitProgress: View {
    let store: ReviewCommitStore

    var body: some View {
        VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
            if store.steps.isEmpty {
                HStack(spacing: NW.Space.m) {
                    ProgressView().progressViewStyle(NWSpinnerStyle())
                    Text("Starting on the host…").font(.nw(.ui)).foregroundStyle(Color.nw.textSecondary)
                }
                .frame(minHeight: NW.Height.touch)
            } else {
                NWGroupCard {
                    ForEach(store.steps) { step in
                        CommitStepRow(step: step)
                    }
                }
            }
            if case .failed(let message)? = store.outcome {
                NWBanner(.failed, title: "Stopped", message: message)
            }
            if let error = store.error {
                NWBanner(.attention, title: "Outcome not yet known", message: error)
            }
            if let url = store.operation?.prURL, let link = URL(string: url) {
                Link(destination: link) {
                    Label(url, systemImage: "arrow.up.forward.square")
                        .font(.nw(.mono))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minHeight: NW.Height.touch)
                }
                .foregroundStyle(Color.nw.running)
            }
        }
    }
}

/// One step: its state glyph, its label, and what the host said.
private struct CommitStepRow: View {
    let step: FinalizeStep

    var body: some View {
        HStack(alignment: .top, spacing: NW.Space.m) {
            NWStateGlyph(state).padding(.top, NW.Space.xxs)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(step.label.prefix(1).uppercased() + step.label.dropFirst())
                    .font(.nw(.ui))
                    .foregroundStyle(step.state == .pending ? Color.nw.textTertiary : Color.nw.textPrimary)
                if let detail {
                    Text(detail).font(.nw(.caption))
                        .foregroundStyle(failed ? Color.nw.failed : Color.nw.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NW.Space.xl)
        .padding(.vertical, NW.Space.m)
        .frame(minHeight: NW.Height.touch)
        .accessibilityElement(children: .combine)
    }

    private var state: AgentState {
        switch step.state {
        case .pending: .queued
        case .running: .running
        case .done: .done
        case .failed: .failed
        }
    }

    private var detail: String? {
        switch step.state {
        case .done(let text), .failed(let text): text.isEmpty ? nil : text
        case .pending, .running: nil
        }
    }

    private var failed: Bool {
        if case .failed = step.state { return true }
        return false
    }
}

/// "Commit 3 files", "Committing…", "Committed", "Pull request opened", "Commit stopped".
@MainActor func commitTitle(_ store: ReviewCommitStore) -> String {
    switch store.outcome {
    case .running?: return "Committing…"
    case .succeeded(let url)?: return url == nil ? "Committed" : "Pull request opened"
    case .failed?: return "Commit stopped"
    case nil:
        let count = store.selectedFiles.count
        return count == 0 ? "Commit" : "Commit \(nativeCount(count, "file"))"
    }
}

extension NWCommitFileRow.Item {
    init(_ row: ReviewCommitFileRow) {
        self.init(id: row.id, name: row.name, directory: row.directory, status: NWFileStatus(row.status), added: row.added,
                  removed: row.removed, selected: row.selected)
    }
}
