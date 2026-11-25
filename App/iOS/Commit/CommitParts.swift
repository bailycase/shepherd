import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// The parts the phone's commit sheet and the iPad's popover share: the message, the files with
// their checkboxes, the options, why the host won't commit, and the host's steps.

extension MobileLayout {
    /// The iPad's commit popover (the iPadCommit board's 400pt).
    static let commitPopoverWidth: CGFloat = 400
}

/// The message card, with where it came from. On the phone a raised card on the lift; in the
/// iPad's popover a sunken well (`fill`).
struct CommitMessageCard: View {
    @Bindable var store: ReviewCommitStore
    var fill: Color? = nil

    var body: some View {
        let sh = Color.sh
        let drafting = store.drafting && !store.mentionsUntickedFiles
        let radius = fill == nil ? MobileLayout.touchCardRadius : SH.Radius.l
        // Both fields take their ideal height: a sheet sized to its content proposes a field the
        // height it had, so text set from outside (the host's message, a draft) stayed clipped to it.
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            TextField("Summary", text: $store.title, prompt: Text("Summary").foregroundStyle(sh.textTertiary), axis: .vertical)
                .lineLimit(1...3)
                .fixedSize(horizontal: false, vertical: true)
                .font(.shSans(MobileLayout.touchBodyFont, .semibold))
                .foregroundStyle(sh.textPrimary)
                .accessibilityLabel("Commit summary")
            TextField("Description", text: $store.body, prompt: Text("Description (optional)").foregroundStyle(sh.textTertiary), axis: .vertical)
                .lineLimit(1...8)
                .fixedSize(horizontal: false, vertical: true)
                .font(.shSans(MobileLayout.touchBodyFont - 1))
                .lineSpacing(SH.Space.xxs)
                .foregroundStyle(sh.textSecondary)
                .accessibilityLabel("Commit description")
            Text(note)
                .font(.sh(.caption))
                .foregroundStyle(sh.textTertiary)
                .shShimmer(active: drafting)
                .padding(.top, SH.Space.s)
                .shContentTransition(.crossFade)
                .shComponentAnimation(.content, value: store.mentionsUntickedFiles)
        }
        .textFieldStyle(.plain)
        .tint(sh.textPrimary)
        .padding(.horizontal, MobileLayout.gutter)
        .padding(.vertical, SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: radius, fill: fill, line: fill == nil ? nil : .clear, lift: fill == nil)
    }

    private var note: String {
        // An edited message keeps what was typed, whatever a draft brings.
        if store.mentionsUntickedFiles { return "May mention files you unticked" }
        return store.drafting ? "Drafting from the diff\u{2026}"
            : store.drafted ? "Drafted from the diff \u{00B7} edit anything" : "Written from the file list \u{00B7} edit anything"
    }
}

/// A file the commit can take (MobileCommit): its ink checkbox, the filename in mono and the diff
/// stat. The whole row toggles. Equal on its values.
struct CommitFileRowView: View, Equatable {
    let item: SHCommitFileRow.Item
    let toggle: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.item == rhs.item }

    var body: some View {
        let sh = Color.sh
        let stacked = typeSize.isAccessibilitySize
        Button(action: toggle) {
            HStack(spacing: SH.Space.l) {
                ZStack {
                    RoundedRectangle(cornerRadius: SH.Radius.s - SH.Space.xxs)
                        .fill(item.selected ? sh.primary : .clear)
                    RoundedRectangle(cornerRadius: SH.Radius.s - SH.Space.xxs)
                        .strokeBorder(sh.textTertiary, lineWidth: 1.5)
                        .opacity(item.selected ? 0 : 1)
                    Image(systemName: "checkmark")
                        .font(.shSans(MobileLayout.touchDetailFont + 1, .semibold))
                        .foregroundStyle(sh.textOnPrimary)
                        .opacity(item.selected ? 1 : 0)
                }
                .frame(width: CommitFileRowView.boxSize, height: CommitFileRowView.boxSize)
                .accessibilityHidden(true)
                let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: SH.Space.xxs))
                    : AnyLayout(HStackLayout(spacing: SH.Space.m))
                layout {
                    Text(item.name)
                        .font(.shMono(MobileLayout.touchBodyFont - 1, .medium))
                        .foregroundStyle(sh.textPrimary)
                        .lineLimit(stacked ? 3 : 1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if stacked { SHDiffStat(added: item.added, removed: item.removed, font: .shSans(MobileLayout.touchDetailFont)) }
                }
                Spacer(minLength: SH.Space.s)
                if !stacked { SHDiffStat(added: item.added, removed: item.removed, font: .shSans(MobileLayout.touchDetailFont)) }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.vertical, SH.Space.s)
            .frame(maxWidth: .infinity, minHeight: SH.Height.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(item.selected ? "Selected" : "Not selected")
        .accessibilityHint(item.selected ? "Leaves the file out of the commit" : "Puts the file in the commit")
        .accessibilityAddTraits(.isToggle)
    }

    private var accessibilityText: String {
        var parts = [item.name]
        if !item.directory.isEmpty { parts.append("in \(item.directory)") }
        parts += [item.status.label, "\(item.added) added, \(item.removed) removed"]
        return parts.joined(separator: ", ")
    }

    /// The checkbox (the boards' 22pt).
    static let boxSize: CGFloat = 22
}

/// The changed files, each with its checkbox; all go in until unticked.
struct CommitFileList: View {
    let store: ReviewCommitStore

    var body: some View {
        ReviewLazyCard(store.rows) { row in
            CommitFileRowView(item: SHCommitFileRow.Item(row)) { store.toggle(row.id) }.equatable()
        }
    }
}

/// An option of the commit (MobileCommit's "Push after commit" over "origin/…") with its switch. The
/// whole row toggles.
struct CommitOptionRow: View {
    let title: String
    let detail: String?
    var monoDetail = false
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.l) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title).font(.shSans(MobileLayout.touchBodyFont, .medium)).foregroundStyle(sh.textPrimary)
                if let detail {
                    Text(detail)
                        .font(monoDetail ? .shMono(MobileLayout.touchDetailFont - 1) : .shSans(MobileLayout.touchDetailFont))
                        .foregroundStyle(sh.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(sh.primary)
        }
        .padding(.horizontal, MobileLayout.gutter)
        .padding(.vertical, SH.Space.m + SH.Space.xxs)
        .frame(maxWidth: .infinity, minHeight: MobileLayout.touchRowHeight)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : MobileLayout.touchDisabledOpacity)
        .accessibilityRepresentation {
            Toggle(isOn: $isOn) {
                Text(title)
                if let detail { Text(detail) }
            }
        }
    }
}

/// Push after commit, and Open a pull request instead.
struct CommitOptions: View {
    @Bindable var store: ReviewCommitStore

    var body: some View {
        if let info = store.info {
            ReviewCard {
                CommitOptionRow(title: "Push after commit", detail: reviewCommitPushDetail(info), monoDetail: true,
                                isOn: Binding(get: { store.push || store.pullRequest }, set: { store.push = $0 }))
                    .disabled(store.pullRequest || !reviewCommitCanPush(info))
                CommitOptionRow(title: "Open a pull request instead", detail: reviewCommitPullRequestDetail(info, title: store.title),
                                isOn: $store.pullRequest)
                    .disabled(!reviewCommitCanOpenPullRequest(info))
            }
        }
    }
}

/// Why the host won't commit here, or that the agent is still working (with the confirmation).
struct CommitNotices: View {
    @Bindable var store: ReviewCommitStore

    var body: some View {
        if let blocked = store.info?.blocked {
            SHBanner(.failed, title: "Can't commit here", message: blocked)
        } else if store.info?.agentWorking == true {
            VStack(alignment: .leading, spacing: SH.Space.s) {
                SHBanner(.attention, title: "The agent is working",
                         message: "Its files may still change. The host commits them as they were when this opened, and stops if one changed since.")
                Toggle("Commit while it works", isOn: $store.confirmedWhileWorking)
                    .toggleStyle(.shCheckbox)
                    .font(.sh(.ui))
                    .foregroundStyle(Color.sh.textPrimary)
                    .frame(minHeight: SH.Height.touch)
                    .padding(.horizontal, SH.Space.xs)
            }
        }
        if let error = store.error, store.stage == .form {
            SHBanner(.failed, title: "Nothing was committed", message: error) {
                Button("Dismiss") { store.error = nil }.buttonStyle(.sh(.ghost, size: .s))
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
                HStack(spacing: SH.Space.m) {
                    Text("Starting on the host…").font(.sh(.ui)).shShimmer(active: true)
                }
                .frame(minHeight: SH.Height.touch)
            } else {
                SHGroupCard {
                    ForEach(store.steps) { step in
                        CommitStepRow(step: step)
                    }
                }
            }
            if case .failed(let message)? = store.outcome {
                SHBanner(.failed, title: "Stopped", message: message)
            }
            if let error = store.error {
                SHBanner(.attention, title: "Outcome not yet known", message: error)
            }
            if let url = store.operation?.prURL, let link = URL(string: url) {
                Link(destination: link) {
                    Label(url, systemImage: "arrow.up.forward.square")
                        .font(.sh(.mono))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minHeight: SH.Height.touch)
                }
                .foregroundStyle(Color.sh.running)
            }
        }
    }
}

/// One step: its state glyph, its label, and what the host said.
private struct CommitStepRow: View {
    let step: OperationStep

    var body: some View {
        HStack(alignment: .top, spacing: SH.Space.m) {
            SHStateGlyph(state).padding(.top, SH.Space.xxs)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(step.label.prefix(1).uppercased() + step.label.dropFirst())
                    .font(.sh(.ui))
                    .foregroundStyle(step.state == .pending ? Color.sh.textTertiary : Color.sh.textPrimary)
                if let detail {
                    Text(detail).font(.sh(.caption))
                        .foregroundStyle(failed ? Color.sh.failed : Color.sh.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SH.Space.xl)
        .padding(.vertical, SH.Space.m)
        .frame(minHeight: SH.Height.touch)
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

extension SHCommitFileRow.Item {
    init(_ row: ReviewCommitFileRow) {
        self.init(id: row.id, name: row.name, directory: row.directory, status: SHFileStatus(row.status), added: row.added,
                  removed: row.removed, selected: row.selected)
    }
}
