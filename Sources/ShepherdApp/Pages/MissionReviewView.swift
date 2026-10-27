import SwiftUI
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdUI

/// Publication is tied to the exact receipt being shown, not a mutable controller selection.
struct MissionReviewApprovalState: Equatable {
    let stale: Bool
    let approval: MissionPublishApproval?
    let publicationAuthorized: Bool

    var publishLabel: String { publicationAuthorized ? "Retry publication" : "Publish pull requests" }

    init(mission: Mission, repositories: [MissionRepositoryReview]) {
        publicationAuthorized = mission.run?.publicationApproval != nil
        let checkouts = mission.run?.checkouts ?? []
        stale = checkouts.isEmpty || checkouts.count != repositories.count || checkouts.contains { checkout in
            !repositories.contains { repo in
                repo.spaceID == checkout.spaceID && repo.fingerprint == checkout.fingerprint
                    && (repo.head == checkout.head || (mission.run?.publicationApproval != nil
                        && (checkout.publishedHead.map { repo.head.hasPrefix($0) } ?? true)))
            }
        }
        let phase = mission.run?.phase ?? .map
        if !stale, [.review, .paused].contains(phase) || (phase == .stopped && publicationAuthorized), let fingerprint = mission.run?.reviewFingerprint, !fingerprint.isEmpty {
            approval = MissionPublishApproval(id: mission.id, revision: mission.revision, fingerprint: fingerprint)
        } else { approval = nil }
    }
}

/// A change you drafted on a line, sent with Request changes.
struct MissionReviewComment: Identifiable, Equatable {
    let id = UUID()
    let repository: String
    let path: String
    let line: Int?
    /// The line is a removed one, numbered in the old file (an old and a new line can share a number).
    var old = false
    var text: String
    var queued = false
    var request: String { "\(repository)/\(path)\(line.map { ":\($0)" } ?? "")\(old ? " (removed line)" : ""): \(text)" }
}

struct MissionReviewView: View {
    let mission: Mission
    let repositories: [MissionRepositoryReview]
    @Binding var viewed: Set<String>
    let busy: Bool
    let openThread: (AgentID) -> Void
    let action: (MissionUIAction) -> Void
    private let approvalState: MissionReviewApprovalState
    @State private var selection: FileSelection?
    @State private var collapsed: Set<SpaceID> = []
    @State private var split = false
    @State private var comments: [MissionReviewComment] = []
    @State private var showsContract = false
    @Environment(\.missionInitialPanes) private var seed

    struct FileSelection: Equatable { let space: SpaceID; let path: String }

    init(mission: Mission, repositories: [MissionRepositoryReview], viewed: Binding<Set<String>> = .constant([]), busy: Bool,
         openThread: @escaping (AgentID) -> Void, action: @escaping (MissionUIAction) -> Void) {
        self.mission = mission; self.repositories = repositories; _viewed = viewed; self.busy = busy
        self.openThread = openThread; self.action = action
        approvalState = MissionReviewApprovalState(mission: mission, repositories: repositories)
    }

    private var selectedRepository: MissionRepositoryReview? {
        repositories.first { $0.spaceID == selection?.space } ?? repositories.first { !$0.files.isEmpty } ?? repositories.first
    }
    private var selectedFile: DiffFile? {
        selectedRepository?.files.first { $0.displayPath == selection?.path } ?? selectedRepository?.files.first
    }
    private var files: [(MissionRepositoryReview, DiffFile)] { repositories.flatMap { repo in repo.files.map { (repo, $0) } } }
    private func key(_ repo: MissionRepositoryReview, _ file: DiffFile) -> String { "\(repo.spaceID.rawValue)|\(file.displayPath)|\(repo.fingerprint)" }
    private var queued: [MissionReviewComment] { comments.filter(\.queued) }
    private var canRequest: Bool { !approvalState.publicationAuthorized && mission.phase == .review }

    var body: some View {
        VStack(spacing: 0) {
            if approvalState.stale {
                HStack(spacing: NW.Space.l) {
                    NWStatusDot(.attention)
                    Text(repositories.isEmpty ? "Collecting the repository diffs…" : approvalState.publicationAuthorized
                         ? "Repository contents no longer match the approved receipts. Publication can't continue until they match again."
                         : "These changes moved after validation. Refresh, then re-run validation before publishing.")
                        .nwText(.ui).fontWeight(.regular)
                    Spacer()
                    Button(busy ? "Refreshing…" : "Refresh diffs") { action(.refresh) }
                        .buttonStyle(.nw(.secondary, size: .s)).disabled(busy)
                }
                .padding(.horizontal, NW.Space.xl).padding(.vertical, NW.Space.m).background(Color.nw.lanternTint)
            }
            GeometryReader { geometry in
                let narrow = geometry.size.width < AppLayout.missionNarrowWidth
                HStack(spacing: 0) {
                    fileList.frame(width: AppLayout.missionSide(AppLayout.missionFilesWidth, in: geometry.size.width, share: AppLayout.missionFilesShare))
                    Rectangle().fill(Color.nw.lineSubtle).frame(width: 1)
                    if narrow {
                        // A narrow window shows the diff or the contract in the main column.
                        VStack(spacing: 0) {
                            NWSegmentedPicker("Show", selection: $showsContract, options: [(false, "Changes"), (true, "Contract")])
                                .fixedSize().padding(NW.Space.m)
                            NWHairline()
                            if showsContract { contract } else { center }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        center.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Rectangle().fill(Color.nw.lineSubtle).frame(width: 1)
                        contract.frame(width: AppLayout.missionSide(AppLayout.missionContractWidth, in: geometry.size.width, share: AppLayout.missionContractShare))
                    }
                }
            }
            NWHairline()
            HStack(spacing: NW.Space.l) {
                Text(approvalState.publicationAuthorized
                     ? "Publication uses the approved receipts. Shepherd opens pull requests only; it never merges or deploys."
                     : queued.isEmpty ? "Comment on a line to request a change. It goes back to the planner, and validation runs again before you're asked back."
                     : "Changes you send go back to the planner with the file and line. Workers revise, and validation runs again before you're asked back.")
                    .nwText(.caption).foregroundStyle(Color.nw.textTertiary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: NW.Space.l)
                if canRequest && !queued.isEmpty {
                    Button("Request changes · \(queued.count)") {
                        action(.changes(queued.map(\.request).joined(separator: "\n")))
                        comments.removeAll()
                    }
                    .buttonStyle(.nw(.secondary)).disabled(busy || queued.isEmpty)
                    .nwHelp(queued.isEmpty ? "Comment on a line to request a change" : "Send \(queued.count) change\(queued.count == 1 ? "" : "s") to the planner")
                }
                Button {
                    if let approval = approvalState.approval { action(.publish(approval)) }
                } label: {
                    Text(mission.phase == .publishing ? "Publishing PRs…" : approvalState.publicationAuthorized ? approvalState.publishLabel
                         : "Approve \(repositories.count) PR\(repositories.count == 1 ? "" : "s") · publish")
                }
                .buttonStyle(.nw(.primary)).keyboardShortcut(.return, modifiers: .command)
                .disabled(busy || approvalState.approval == nil || !queued.isEmpty)
                .nwHelp(!queued.isEmpty ? "Send or discard your requested changes first" : approvalState.stale ? "Refresh the diffs first" : "Open one pull request per repository", shortcut: "⌘↩")
            }
            .padding(.horizontal, NW.Space.xl).padding(.vertical, NW.Space.m)
            .frame(minHeight: NWPageMetrics.headerHeight + NW.Space.m)
        }
        .onAppear {
            if seed.side { showsContract = true }
            if comments.isEmpty { comments = seed.comments }
        }
    }

    private var contract: some View {
        MissionContract(mission: mission, busy: busy, canRerun: canRequest, openThread: openThread, action: action, open: seed.openContractItem)
    }

    // MARK: PR set

    private var fileList: some View {
        let added = files.reduce(0) { $0 + $1.1.addedCount }, removed = files.reduce(0) { $0 + $1.1.removedCount }
        let seen = files.filter { viewed.contains(key($0.0, $0.1)) }.count
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: NW.Space.m) {
                HStack {
                    NWPageSectionLabel("PR set")
                    Spacer()
                    Text("publishes in this order").nwText(.caption).foregroundStyle(Color.nw.textTertiary)
                }
                HStack(spacing: NW.Space.m) {
                    Text("\(repositories.count) PRs · \(files.count) files").nwText(.headline)
                    NWDiffStat(added: added, removed: removed)
                }
                HStack(spacing: NW.Space.l) {
                    ProgressView(value: Double(seen), total: Double(max(1, files.count))).progressViewStyle(.nwBar(tint: Color.nw.done))
                    Text("viewed \(seen) of \(files.count)").nwText(.caption).foregroundStyle(Color.nw.textTertiary).fixedSize()
                }
            }.padding(NW.Space.xl)
            NWHairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(repositories.enumerated()), id: \.element.id) { index, repo in
                      VStack(alignment: .leading, spacing: 0) {
                        let open = !collapsed.contains(repo.spaceID)
                        let checkout = mission.run?.checkouts.first { $0.spaceID == repo.spaceID }
                        Button {
                            if open { collapsed.insert(repo.spaceID) } else { collapsed.remove(repo.spaceID) }
                        } label: {
                            HStack(spacing: NW.Space.m) {
                                Image(systemName: open ? "chevron.down" : "chevron.right").font(.nw(.micro)).foregroundStyle(Color.nw.textTertiary)
                                Text("\(index + 1)").nwText(.micro).foregroundStyle(Color.nw.textTertiary)
                                Text(mission.lane(repo.spaceID)?.name ?? repo.name).nwText(.mono).fontWeight(.semibold).lineLimit(1)
                                // The branch the PR opens from: a Spec Kit feature branch once its git extension made one.
                                Text(repo.branch).nwText(.mono).foregroundStyle(Color.nw.textTertiary).lineLimit(1).truncationMode(.middle)
                                    .nwHelp("Opens its PR from \(repo.branch)")
                                if let number = MissionFormat.pullNumber(checkout?.prURL) { Text(number).nwText(.mono).foregroundStyle(Color.nw.running) }
                                Spacer(minLength: NW.Space.s)
                                let done = repo.files.filter { viewed.contains(key(repo, $0)) }.count
                                Text("\(done) / \(repo.files.count)").nwText(.micro).foregroundStyle(Color.nw.textTertiary)
                                Image(systemName: "checkmark").font(.nw(.micro, weight: .bold))
                                    .foregroundStyle(done == repo.files.count ? Color.nw.done : Color.clear)
                            }
                            .padding(.horizontal, NW.Space.l).frame(height: NW.Height.controlL).contentShape(Rectangle())
                        }
                        .buttonStyle(.nwRow())
                        .accessibilityLabel("\(repo.name), branch \(repo.branch), \(repo.files.count) files")
                        .accessibilityValue(open ? "expanded" : "collapsed")
                        if open {
                            ForEach(repo.files) { file in fileRow(repo, file) }
                            if repo.files.isEmpty {
                                Text("No changed files").nwText(.caption).foregroundStyle(Color.nw.textTertiary).padding(.leading, NW.Space.xxxl).padding(.vertical, NW.Space.s)
                            }
                        }
                      }
                    }
                }.padding(NW.Space.s)
            }
            if let summary = mission.workSummary {
                NWHairline()
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    NWPageSectionLabel(summary.title)
                    MissionProse(summary.text).lineLimit(8)
                }.padding(NW.Space.xl)
            }
        }
    }

    private func fileRow(_ repo: MissionRepositoryReview, _ file: DiffFile) -> some View {
        let isViewed = viewed.contains(key(repo, file))
        let selected = selectedRepository?.spaceID == repo.spaceID && selectedFile?.id == file.id
        let parts = file.displayPath.split(separator: "/", omittingEmptySubsequences: false)
        let directory = parts.dropLast().joined(separator: "/")
        return HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
            Button { toggle(repo, file) } label: {
                Image(systemName: isViewed ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isViewed ? Color.nw.lanternText : Color.nw.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Viewed \(file.displayPath)")
            .accessibilityValue(isViewed ? "on" : "off")
            Button { selection = FileSelection(space: repo.spaceID, path: file.displayPath) } label: {
                // The whole path, wrapping in a narrow column rather than hiding its folders.
                let name = Text(parts.last.map(String.init) ?? file.displayPath).foregroundStyle(isViewed ? Color.nw.textTertiary : Color.nw.textPrimary)
                HStack(alignment: .firstTextBaseline, spacing: NW.Space.s) {
                    Text(directory.isEmpty ? "\(name)" : "\(Text(directory + "/").foregroundStyle(Color.nw.textTertiary))\(name)")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    NWDiffStat(added: file.addedCount, removed: file.removedCount).fixedSize()
                }
                .nwText(.mono)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(file.displayPath)
            .accessibilityLabel(file.displayPath)
            .accessibilityValue("\(mission.lane(repo.spaceID)?.name ?? repo.name), +\(file.addedCount) −\(file.removedCount)")
        }
        .padding(.leading, NW.Space.xxl).padding(.trailing, NW.Space.l).padding(.vertical, NW.Space.s)
        .frame(minHeight: NW.Height.controlL)
        .background(selected ? Color.nw.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: NW.Radius.s))
        .accessibilityElement(children: .contain)
    }

    private func toggle(_ repo: MissionRepositoryReview, _ file: DiffFile) {
        let id = key(repo, file)
        if viewed.contains(id) { viewed.remove(id) } else { viewed.insert(id) }
    }

    // MARK: File

    @ViewBuilder private var center: some View {
        if let repo = selectedRepository, let file = selectedFile {
            VStack(spacing: 0) {
                HStack(spacing: NW.Space.m) {
                    NWGlyph.document.image.foregroundStyle(Color.nw.textTertiary)
                    // The whole path first: the repository steps aside (the PR set names it), then
                    // the leading directories truncate.
                    let path = Text(file.displayPath).font(.nw(.mono, weight: .semibold))
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: NW.Space.m) {
                            Text("\(mission.lane(repo.spaceID)?.name ?? repo.name) /").nwText(.mono).foregroundStyle(Color.nw.textTertiary)
                            path
                        }.fixedSize()
                        // Narrow: the whole path wraps; no folder is hidden.
                        path.fixedSize(horizontal: false, vertical: true)
                    }.layoutPriority(1)
                    NWDiffStat(added: file.addedCount, removed: file.removedCount).fixedSize()
                    Spacer(minLength: NW.Space.m)
                    NWViewedCheckbox(isViewed: viewed.contains(key(repo, file)), name: file.displayPath) { toggle(repo, file) }.fixedSize()
                    NWSegmentedPicker("Diff layout", selection: $split, options: [(false, "Unified"), (true, "Split")]).fixedSize()
                }
                .padding(.horizontal, NW.Space.xl).padding(.vertical, NW.Space.s)
                .frame(minHeight: NWPageMetrics.headerHeight)
                .overlay(alignment: .bottom) { NWHairline() }
                MissionFileDiff(repository: mission.lane(repo.spaceID)?.name ?? repo.name, file: file, split: split,
                                comments: $comments, commentable: canRequest)
                    .id("\(repo.spaceID.rawValue)|\(file.id)")
                if let next = nextFile(after: repo, file) {
                    Button { selection = FileSelection(space: next.0.spaceID, path: next.1.displayPath) } label: {
                        HStack(spacing: NW.Space.m) {
                            Image(systemName: "chevron.right").font(.nw(.micro))
                            Text("\(mission.lane(next.0.spaceID)?.name ?? next.0.name) / \(next.1.displayPath)").nwText(.mono).lineLimit(1)
                            NWDiffStat(added: next.1.addedCount, removed: next.1.removedCount)
                            Spacer()
                        }
                        .foregroundStyle(Color.nw.textTertiary)
                        .padding(.horizontal, NW.Space.xl).frame(height: NW.Height.controlL).contentShape(Rectangle())
                    }
                    .buttonStyle(.nwRow(radius: 0))
                    .overlay(alignment: .top) { NWHairline() }
                    .accessibilityLabel("Next file, \(next.1.displayPath)")
                }
            }
        } else {
            VStack(spacing: NW.Space.m) {
                Text(repositories.isEmpty ? "Collecting changes" : "No changed files").nwText(.headline)
                Text(repositories.isEmpty ? "The diffs for each repository appear here." : "The workers left these repositories unchanged.")
                    .nwText(.body).foregroundStyle(Color.nw.textTertiary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func nextFile(after repo: MissionRepositoryReview, _ file: DiffFile) -> (MissionRepositoryReview, DiffFile)? {
        guard let index = files.firstIndex(where: { $0.0.spaceID == repo.spaceID && $0.1.id == file.id }), index + 1 < files.count else { return nil }
        return files[index + 1]
    }
}

/// The contract (MXReview's right column): every requirement and check, numbered, with its
/// result; open one for its evidence.
private struct MissionContract: View {
    let mission: Mission
    let busy: Bool
    let canRerun: Bool
    let openThread: (AgentID) -> Void
    let action: (MissionUIAction) -> Void
    @State private var open: Int?

    init(mission: Mission, busy: Bool, canRerun: Bool, openThread: @escaping (AgentID) -> Void,
         action: @escaping (MissionUIAction) -> Void, open: Int? = nil) {
        self.mission = mission; self.busy = busy; self.canRerun = canRerun
        self.openThread = openThread; self.action = action; _open = State(initialValue: open)
    }

    private struct Item { let text: String; let tag: String; let station: MissionStation?; let state: AgentState? }

    private var validator: MissionStation? { mission.draft.plan?.stations.last { $0.kind == .validator } }
    private var items: [Item] {
        let run = mission.run
        let verdict = validator.flatMap { run?.latest($0.id) }
        var values = mission.draft.requirements.map { Item(text: $0, tag: "validator", station: validator, state: verdict.map { $0.status.missionState }) }
        values += (mission.draft.plan?.stations.filter { $0.kind == .check } ?? []).map { check in
            Item(text: check.command ?? check.title, tag: "cmd", station: check, state: run?.latest(check.id)?.status.missionState)
        }
        values.append(Item(text: "You approve the PR set", tag: "you", station: nil, state: run?.publicationApproval != nil ? .done : .attention))
        return values
    }

    var body: some View {
        let passed = items.filter { $0.state == .done && $0.station != nil }.count
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: NW.Space.l) {
                Image(systemName: "checkmark.shield").font(.nw(.headline)).foregroundStyle(Color.nw.done)
                    .frame(width: NW.Height.controlL, height: NW.Height.controlL)
                    .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.s))
                    .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.s)
                VStack(alignment: .leading, spacing: NW.Space.xs) {
                    HStack(spacing: NW.Space.m) {
                        Text("Contract").nwText(.title).accessibilityAddTraits(.isHeader)
                        NWStatusPill(passed == items.count - 1 ? .done : .attention,
                                     label: "\(passed) passed · \(mission.run?.publicationApproval == nil ? "1 is you" : "approved")")
                    }
                    Text("visible to workers and to you · checked independently").nwText(.caption).foregroundStyle(Color.nw.textTertiary)
                }
                Spacer()
            }
            .padding(NW.Space.xl)
            .overlay(alignment: .bottom) { NWHairline() }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NW.Space.xxs) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        Button { open = open == index ? nil : index } label: {
                            HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
                                Text("\(index + 1)").nwText(.micro).foregroundStyle(Color.nw.textTertiary).frame(minWidth: NW.Space.l, alignment: .trailing)
                                mark(item.state)
                                Text(item.text).font(item.tag == "cmd" ? .nw(.mono) : .nw(.ui, weight: .regular)).multilineTextAlignment(.leading)
                                Spacer(minLength: NW.Space.m)
                                Text(item.tag).nwText(.micro).foregroundStyle(item.tag == "you" ? Color.nw.lanternText : Color.nw.textTertiary)
                            }
                            .padding(.horizontal, NW.Space.m).padding(.vertical, NW.Space.m).contentShape(Rectangle())
                        }
                        .buttonStyle(.nwRow(selected: open == index))
                        .disabled(item.station == nil)
                        .accessibilityLabel("\(index + 1). \(item.text)")
                        .accessibilityValue("\(item.state?.label ?? "not run")\(open == index ? ", expanded" : "")")
                        if open == index, let station = item.station { evidence(station) }
                    }
                }.padding(NW.Space.m)
            }
            let ran = validator.flatMap { mission.latest($0.id)?.endedAt }
            if ran != nil || canRerun {
                NWHairline()
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    if let ran {
                        Text("Validator ran at \(Date(timeIntervalSince1970: ran).formatted(date: .omitted, time: .shortened)) on This Mac, reading every mission worktree without changing them.")
                            .nwText(.caption).foregroundStyle(Color.nw.textTertiary)
                    }
                    // One action for the whole contract: the controller re-runs every check and the
                    // validator together; there is no single-check re-run.
                    if canRerun {
                        Button { action(.revalidate) } label: { Label("Re-run all checks", systemImage: "arrow.clockwise") }
                            .buttonStyle(.nw(.secondary, size: .s)).disabled(busy)
                            .nwHelp("Runs every check and the validator again on the current worktrees")
                    }
                }
                .padding(NW.Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.nw.bgWindow)
    }

    @ViewBuilder private func mark(_ state: AgentState?) -> some View {
        switch state {
        case .done?: Image(systemName: "checkmark").font(.nw(.caption, weight: .semibold)).foregroundStyle(Color.nw.done)
        case .failed?: Image(systemName: "xmark").font(.nw(.caption, weight: .semibold)).foregroundStyle(Color.nw.failed)
        case .attention?: NWStatusDot(.attention)
        case .running?: ProgressView().progressViewStyle(.nwSpinner(size: 10))
        default: Image(systemName: "circle").font(.nw(.micro)).foregroundStyle(Color.nw.textTertiary)
        }
    }

    private func evidence(_ station: MissionStation) -> some View {
        let attempt = mission.latest(station.id)
        return VStack(alignment: .leading, spacing: NW.Space.m) {
            if let output = attempt?.output, !output.isEmpty {
                Text(output).font(station.kind == .check ? .nw(.code) : .nw(.caption)).foregroundStyle(Color.nw.textSecondary)
                    .lineLimit(14).textSelection(.enabled)
                    .padding(NW.Space.l).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                    .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.m)
            } else {
                Text("No evidence recorded yet.").nwText(.caption).foregroundStyle(Color.nw.textTertiary)
            }
            HStack(spacing: NW.Space.m) {
                if let agent = attempt?.agentID {
                    Button("Open evidence") { openThread(agent) }.buttonStyle(.nw(.secondary, size: .s))
                }
            }
        }
        .padding(.leading, NW.Space.xxxl).padding(.trailing, NW.Space.m).padding(.bottom, NW.Space.m)
    }
}

/// The selected file's hunks, unified or split, with syntax colors, line comments and your drafts.
private struct MissionFileDiff: View {
    let repository: String
    let file: DiffFile
    let split: Bool
    @Binding var comments: [MissionReviewComment]
    let commentable: Bool
    @State private var colors: [Int: AttributedString] = [:]

    private struct Row: Identifiable { let id: String; let old: DiffLine?; let new: DiffLine? }

    /// Diff rows fill their frame, so the scroll content takes the longest line's width.
    private var contentWidth: CGFloat {
        let font = NSFont(name: "GeistMono-Regular", size: NWTextStyle.code.size * ThemeStore.shared.textScale)
            ?? .monospacedSystemFont(ofSize: NWTextStyle.code.size * ThemeStore.shared.textScale, weight: .regular)
        let widest = file.hunks.flatMap(\.lines).reduce(CGFloat.zero) {
            max($0, NSAttributedString(string: $1.text, attributes: [.font: font]).size().width)
        }
        return (widest + NWDiffMetrics.codeLeading) * (split ? 2 : 1) + NW.Space.xl
    }

    var body: some View {
        GeometryReader { geometry in
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if file.isBinary {
                    Text("Binary file · open the repository to inspect it.").nwText(.body).padding(NW.Space.xl)
                } else if file.hunks.isEmpty {
                    Text(file.isRenamed ? "Renamed, no textual changes." : "No textual changes.").nwText(.body).padding(NW.Space.xl)
                }
                ForEach(file.hunks) { hunk in
                    Text(hunk.header).nwText(.mono).foregroundStyle(Color.nw.textTertiary).lineLimit(1)
                        .padding(.horizontal, NW.Space.l).frame(height: NW.Height.controlM).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.nw.runningTint)
                    if split {
                        ForEach(pairs(hunk.lines)) { row in
                            NWSplitDiffLine(old: row.old.map(content), new: row.new.map(content), onComment: commentable ? { comment($0.newNumber ?? $0.oldNumber, old: $0.newNumber == nil) } : nil)
                            drafts(after: row.new?.newLine ?? row.old?.oldLine, old: row.new?.newLine == nil, width: geometry.size.width)
                        }
                    } else {
                        ForEach(hunk.lines) { line in
                            NWDiffLine(content(line), onComment: commentable ? { comment(line.newLine ?? line.oldLine, old: line.newLine == nil) } : nil)
                            drafts(after: line.newLine ?? line.oldLine, old: line.newLine == nil, width: geometry.size.width)
                        }
                    }
                }
            }
            .frame(width: max(geometry.size.width, contentWidth), alignment: .leading)
        }
        }
        .task(id: file.id) { colors = reviewHighlight(file, style: .theme) }
    }

    private func content(_ line: DiffLine) -> NWDiffLineContent {
        NWDiffLineContent(id: "\(file.id)\u{0}\(line.id)", key: line.id, kind: line.kind.diffKind,
                          oldNumber: line.oldLine, newNumber: line.newLine, text: colors[line.id] ?? AttributedString(line.text), source: line.text)
    }

    /// Context lines on both sides; a removed run beside the added run that replaced it.
    private func pairs(_ lines: [DiffLine]) -> [Row] {
        var rows: [Row] = [], removed: [DiffLine] = [], added: [DiffLine] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                let old = index < removed.count ? removed[index] : nil, new = index < added.count ? added[index] : nil
                rows.append(Row(id: "\(old?.id ?? -1)-\(new?.id ?? -1)", old: old, new: new))
            }
            removed = []; added = []
        }
        for line in lines {
            switch line.kind.diffKind {
            case .removed: if !added.isEmpty { flush() }; removed.append(line)
            case .added: added.append(line)
            default: flush(); rows.append(Row(id: "\(line.id)", old: line, new: line))
            }
        }
        flush()
        return rows
    }

    private func comment(_ line: Int?, old: Bool) {
        guard !comments.contains(where: { $0.path == file.displayPath && $0.line == line && $0.old == old && !$0.queued }) else { return }
        comments.append(MissionReviewComment(repository: repository, path: file.displayPath, line: line, old: old, text: ""))
    }

    /// Cards keep to the visible `width`, not the scrolled code's, so their actions stay in view.
    @ViewBuilder private func drafts(after line: Int?, old: Bool, width: CGFloat) -> some View {
        ForEach($comments) { $comment in
            if comment.path == file.displayPath && comment.line == line && comment.old == old {
                MissionCommentCard(comment: $comment, lane: repository) {
                    comments.removeAll { $0.id == comment.id }
                }
                .frame(width: max(0, width - NW.Space.xxxl * 2))
                .padding(.horizontal, NW.Space.xxxl).padding(.vertical, NW.Space.m)
            }
        }
    }
}

private struct MissionCommentCard: View {
    @Binding var comment: MissionReviewComment
    let lane: String
    let discard: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            HStack(spacing: NW.Space.s) {
                Image(systemName: "person.crop.circle").foregroundStyle(Color.nw.textTertiary)
                Text(comment.queued ? "You · queued" : "You · draft").nwText(.headline)
                Spacer()
                if let line = comment.line { Text("line \(line)").nwText(.micro).foregroundStyle(Color.nw.textTertiary) }
            }
            if comment.queued {
                Text(comment.text).nwText(.body).textSelection(.enabled)
            } else {
                TextEditor(text: $comment.text).focused($focused).nwText(.body).scrollContentBackground(.hidden)
                    .frame(minHeight: NW.Height.controlL * 2).accessibilityLabel("Requested change")
            }
            // The buttons keep their whole labels; the note moves under them when the card is narrow.
            let actions = HStack(spacing: NW.Space.m) {
                if !comment.queued {
                    Button("Send to the \(lane) lane") { comment.queued = true }
                        .buttonStyle(.nw(.secondary, size: .s))
                        .disabled(comment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button(comment.queued ? "Remove" : "Discard", action: discard).buttonStyle(.nw(.ghost, size: .s))
            }.fixedSize()
            let note = Text("Request changes sends it; validation runs again.").nwText(.caption).foregroundStyle(Color.nw.textTertiary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NW.Space.m) { actions; Spacer(minLength: NW.Space.m); note.fixedSize() }
                VStack(alignment: .leading, spacing: NW.Space.s) { actions; note.fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(NW.Space.l)
        .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(Color.nw.lineStrong, radius: NW.Radius.m)
        .onAppear { if !comment.queued { focused = true } }
    }
}
