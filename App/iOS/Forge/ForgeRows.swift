import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// What the Issues & PRs screens draw, derived once per read from the host's answer
// (`ForgeStore`), so the views only lay values out.

/// A pull request or issue on one host.
struct ForgeItemKey: Hashable, Codable, Sendable {
    var host: UUID
    var ref: ForgeItemRef
}

/// One list row: the dot, the title, "#31 · baily · 2h", and the state's word.
struct ForgeRow: Identifiable, Equatable {
    let key: ForgeItemKey
    let title: String
    let byline: String
    let word: String
    let tone: ForgeTone

    var id: String { key.ref.id }
}

/// One section of a list; an on-demand one that isn't open yet has no rows and `loaded` false.
struct ForgeSectionRows: Identifiable, Equatable {
    let id: ForgeSectionID
    let title: String
    let rows: [ForgeRow]
    let loaded: Bool
}

struct ForgeListModel: Equatable {
    let kind: ForgeKind
    let sections: [ForgeSectionRows]
    /// The tab's count: open items in the sections read.
    let count: Int
    /// Nothing open in any section read.
    var isEmpty: Bool { count == 0 }
}

/// A summary card line (MobilePRDetail): "mara requested changes 40m", "3 of 4 checks passed arm64".
struct ForgeStatusLine: Identifiable, Equatable {
    let id: String
    let glyph: String
    let tone: ForgeTone
    let text: String
    let trailing: String?
}

/// One Activity entry: a quiet line ("agent pushed 1 commit") or a comment card.
struct ForgeActivityItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case line(actor: String, text: String)
        case comment(author: String, location: String?, body: String)
    }

    let id: String
    let kind: Kind
    let age: String
}

struct ForgeCheckRow: Identifiable, Equatable {
    let check: ForgeCheck
    let name: String
    let tone: ForgeTone
    let duration: String?

    var id: String { check.id }
}

/// A label as a tag, in the status role nearest its GitHub color.
struct ForgeLabelTag: Identifiable, Equatable {
    let name: String
    let tone: ForgeTone

    var id: String { name }
}

struct ForgeNote: Equatable {
    let title: String
    let body: String
}

struct ForgePullRequestModel: Equatable {
    let detail: PullRequestDetail
    let badge: String
    let badgeTone: ForgeTone
    /// "baily · 2h ago".
    let byline: String
    /// "payments · Open".
    let subtitle: String
    let body: NativeProse
    let status: [ForgeStatusLine]
    let note: ForgeNote?
    let activity: [ForgeActivityItem]
    let checks: [ForgeCheckRow]
    /// The failing ones, each with its log card.
    let failing: [ForgeCheckRow]
    let checksTone: ForgeTone?
    let primary: ForgePrimaryAction?
    /// "mara requested changes and test · arm64 is failing." Nil when nothing blocks the merge.
    let blocked: String?
    let lineComments: [ForgeLineComment]
    /// Line comments per file, for the Changes list.
    let commentCounts: [String: Int]
    let thread: ForgeThreadLink?
    let hostName: String
}

struct ForgeIssueModel: Equatable {
    let detail: IssueDetail
    let badge: String
    let badgeTone: ForgeTone
    let labels: [ForgeLabelTag]
    /// "mara opened 1h ago · assigned to you".
    let byline: String
    /// "payments · Issue".
    let subtitle: String
    let body: NativeProse
    let comments: [ForgeActivityItem]
    let thread: ForgeThreadLink?
}

/// A pull request's diff with each file's row (MobilePRChanges): the viewed marks are this device's.
struct ForgeFilesModel: Equatable {
    let source: PullRequestFiles
    let comments: [String: Int]
    let summaries: [ReviewFileSummary]
    let totals: ReviewTotals
    /// "2 of 5 viewed · 3 comments".
    let note: String

    init(_ source: PullRequestFiles, comments: [String: Int], viewed: Set<String>) {
        self.source = source
        self.comments = comments
        summaries = source.files.map { ReviewFileSummary(file: $0.file, comments: comments[$0.file.displayPath] ?? 0, viewed: viewed.contains($0.file.displayPath)) }
        totals = ReviewTotals(files: summaries.count, added: summaries.reduce(0) { $0 + $1.added },
                              removed: summaries.reduce(0) { $0 + $1.removed }, viewed: summaries.filter(\.viewed).count)
        let count = comments.values.reduce(0, +)
        var note = totals.viewedText
        if count > 0 { note += " · \(count) comment\(count == 1 ? "" : "s")" }
        if source.omitted > 0 { note += " · \(source.omitted) more not shown" }
        self.note = note
    }

    func file(_ path: String) -> ChangesFileDiff? { source.files.first { $0.file.displayPath == path } }
}

/// A pin in the iPad sidebar (iPadIPReview): its title and its trailing word.
struct ForgePinRow: Identifiable, Equatable {
    let key: ForgeItemKey
    let title: String
    let tag: String
    /// The word's tone; nil draws it quiet ("#34").
    let tagTone: ForgeTone?
    /// The glyph's: the pull request's row state, the issue's progress.
    let tone: ForgeTone?
    let pinnedAt: Date

    var id: String { "\(key.host.uuidString)|\(key.ref.id)" }

    init(host: UUID, item: ForgePinnedItem, viewer: String? = nil) {
        key = ForgeItemKey(host: host, ref: item.pin.ref)
        title = item.title
        let tag = ForgePresentation.pinnedTag(item, viewer: viewer)
        self.tag = tag.label
        tagTone = tag.tone
        // iPadIPReview: a pull request's glyph in its row state's tone, a new issue's in lantern.
        tone = item.pullRequest.map { PullRequestRowState($0).tone } ?? item.issue.map { ForgeRows.tone($0.progress) }
        pinnedAt = item.pin.pinnedAt
    }
}

enum ForgeRows {
    // The summary card's glyphs: AgentState's, and the review bubble.
    static let passedGlyph = "checkmark"
    static let failedGlyph = "xmark"
    static let runningGlyph = "circle.dotted"
    static let changesGlyph = "text.bubble"

    // MARK: Lists

    /// `title` names a browse's one section ("Open pull requests"). Across every repository each
    /// row names its own ("payments #31 · baily · 2h").
    static func list(_ list: ForgeList, host: UUID, hostName: String, title: String? = nil, now: Date = Date()) -> ForgeListModel {
        let everywhere = list.repo == ForgeList.allRepos
        let read = Dictionary(list.sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids: [ForgeSectionID] = list.sections.contains { $0.id == .results } ? [.results] : ForgeSectionID.all(for: list.kind)
        var count = 0
        let sections = ids.map { id -> ForgeSectionRows in
            guard let section = read[id] else {
                return ForgeSectionRows(id: id, title: ForgePresentation.title(id, kind: list.kind), rows: [], loaded: false)
            }
            let rows = (section.pullRequests.map { pullRow($0, section: id, host: host, hostName: hostName, now: now) }
                + section.issues.map { issueRow($0, host: host, now: now) })
                .map { everywhere ? ForgeRow(key: $0.key, title: $0.title, byline: "\($0.key.ref.repoName) \($0.byline)", word: $0.word, tone: $0.tone) : $0 }
            if id != .closed { count += rows.count }
            return ForgeSectionRows(id: id, title: id == .results ? title ?? ForgePresentation.title(section, kind: list.kind)
                                        : ForgePresentation.title(section, kind: list.kind), rows: rows, loaded: true)
        }
        return ForgeListModel(kind: list.kind, sections: sections, count: count)
    }

    static func pullRow(_ pull: PullRequestSummary, section: ForgeSectionID, host: UUID, hostName: String, now: Date) -> ForgeRow {
        let state = PullRequestRowState(pull)
        // An agent's pull request names the host whose thread opened it (MobileIPList's "build-01").
        let author = section == .openedByAgents && pull.thread != nil ? hostName : pull.author
        return ForgeRow(key: ForgeItemKey(host: host, ref: pull.ref), title: pull.title,
                        byline: ForgePresentation.numberedByline(number: pull.ref.number, author: author, updatedAt: pull.updatedAt, now: now),
                        word: state.label, tone: state.tone)
    }

    static func issueRow(_ issue: IssueSummary, host: UUID, now: Date) -> ForgeRow {
        // MobileIssueList: "#34 · mara · 1h · bug", "#28 · baily · 3d · linked #31", "#35 · Triage Sentry · 30m".
        var parts = ["#\(issue.ref.number)", issue.automationName ?? issue.author, ForgePresentation.age(issue.updatedAt, now: now)]
        if let pull = issue.linkedPullRequests.first { parts.append("linked #\(pull)") } else if let label = issue.labels.first { parts.append(label.name) }
        return ForgeRow(key: ForgeItemKey(host: host, ref: issue.ref), title: issue.title, byline: parts.joined(separator: " · "),
                        word: label(issue.progress), tone: tone(issue.progress))
    }

    /// An issue row's dot as MobileIssueList draws it: New in lantern, a thread or a linked pull
    /// request in running blue.
    static func tone(_ progress: IssueProgress) -> ForgeTone {
        switch progress {
        case .new: .attention
        case .running, .inPullRequest: .running
        case .open, .closed: .idle
        }
    }

    static func label(_ progress: IssueProgress) -> String {
        progress == .running ? "Thread" : ForgePresentation.label(progress)
    }

    // MARK: Pages

    static func pullRequest(_ detail: PullRequestDetail, hostName: String, now: Date = Date()) -> ForgePullRequestModel {
        let summary = detail.summary
        let badge = ForgePresentation.badge(detail.state)
        var status: [ForgeStatusLine] = []
        let reviewedAt = Dictionary(detail.events.compactMap { event -> (String, Date)? in
            if case .reviewed = event.kind { return (event.actor.lowercased(), event.at) }
            return nil
        }, uniquingKeysWith: { _, last in last })
        for reviewer in detail.reviewers where reviewer.state == .changesRequested || reviewer.state == .approved {
            let changes = reviewer.state == .changesRequested
            status.append(ForgeStatusLine(id: "review-\(reviewer.login)", glyph: changes ? ForgeRows.changesGlyph : ForgeRows.passedGlyph,
                                          tone: changes ? .failed : .done,
                                          text: "\(reviewer.login) \(changes ? "requested changes" : "approved")",
                                          trailing: reviewedAt[reviewer.login.lowercased()].map { ForgePresentation.age($0, now: now) }))
        }
        let counted = detail.checks.filter { $0.state != .skipped }
        if !counted.isEmpty, let tone = ForgePresentation.tone(summary.checks) {
            let failing = counted.first { $0.state == .failing }
            // "arm64" for "test · arm64": the failing job's last part.
            let trailing = failing.map { $0.displayName.components(separatedBy: " · ").last ?? $0.displayName }
            let glyph = switch tone {
            case .failed: ForgeRows.failedGlyph
            case .running: ForgeRows.runningGlyph
            default: ForgeRows.passedGlyph
            }
            status.append(ForgeStatusLine(id: "checks", glyph: glyph, tone: tone,
                                          text: "\(counted.filter { $0.state == .passed }.count) of \(counted.count) checks passed", trailing: trailing))
        }
        let note = ForgePresentation.stateNote(detail).map { ForgeNote(title: $0.title, body: $0.body) }
        let checks = detail.checks.map { check in
            ForgeCheckRow(check: check, name: check.displayName, tone: ForgePresentation.tone(check.state),
                          duration: check.duration.map(ForgePresentation.duration))
        }
        let lineComments = detail.events.flatMap { event -> [ForgeLineComment] in
            if case .reviewed(_, _, let comments) = event.kind { return comments }
            return []
        }
        return ForgePullRequestModel(
            detail: detail, badge: badge.label, badgeTone: badge.tone,
            byline: "\(summary.author) · \(ForgePresentation.ago(summary.updatedAt, now: now))",
            subtitle: "\(summary.ref.repoName) · \(badge.label)",
            body: NativeProse(nativeMarkdownBlocks(detail.body)), status: status, note: note,
            activity: activity(detail.events, viewer: detail.viewer, now: now),
            checks: checks, failing: checks.filter { $0.check.state == .failing },
            checksTone: ForgePresentation.tone(summary.checks), primary: ForgePresentation.primaryAction(detail),
            blocked: ForgePresentation.blockerSentence(detail.blockers), lineComments: lineComments,
            commentCounts: lineComments.reduce(into: [:]) { $0[$1.path, default: 0] += 1 },
            thread: summary.thread, hostName: hostName)
    }

    static func issue(_ detail: IssueDetail, now: Date = Date()) -> ForgeIssueModel {
        let summary = detail.summary
        let badge = ForgePresentation.badge(summary.state)
        var byline = "\(summary.author) opened \(ForgePresentation.ago(detail.createdAt, now: now))"
        if summary.assignedToViewer { byline += " · assigned to you" }
        let comments = activity(detail.events, viewer: detail.viewer, now: now).filter {
            if case .comment = $0.kind { return true }
            return false
        }
        return ForgeIssueModel(detail: detail, badge: badge.label, badgeTone: badge.tone,
                               labels: summary.labels.map { ForgeLabelTag(name: $0.name, tone: tone(hex: $0.color)) },
                               byline: byline, subtitle: "\(summary.ref.repoName) · Issue", body: NativeProse(nativeMarkdownBlocks(detail.body)),
                               comments: comments, thread: summary.thread)
    }

    /// Activity, oldest first: comments and reviews as cards, everything else as a line. The
    /// opening is the page's own head, so it isn't repeated.
    static func activity(_ events: [ForgeEvent], viewer: String?, now: Date) -> [ForgeActivityItem] {
        events.flatMap { event -> [ForgeActivityItem] in
            let age = ForgePresentation.age(event.at, now: now)
            switch event.kind {
            case .opened:
                return []
            case .commented(let body):
                return [ForgeActivityItem(id: event.id, kind: .comment(author: event.actor, location: nil, body: body), age: age)]
            case .reviewed(_, let body, let comments) where !comments.isEmpty || !body.isEmpty:
                let cards = comments.map { comment in
                    ForgeActivityItem(id: "\(event.id)-\(comment.id)", kind: .comment(author: comment.author, location: ForgePresentation.location(comment),
                                                                                     body: comment.body), age: ForgePresentation.age(comment.createdAt, now: now))
                }
                let summary = body.isEmpty ? [] : [ForgeActivityItem(id: event.id, kind: .comment(author: event.actor, location: nil, body: body), age: age)]
                return summary + cards
            default:
                let line = ForgePresentation.line(event, viewer: viewer)
                return [ForgeActivityItem(id: event.id, kind: .line(actor: line.actor, text: line.text), age: age)]
            }
        }
    }

    /// The status role nearest a GitHub label's color: grays stay neutral.
    static func tone(hex: String) -> ForgeTone {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return .idle }
        let r = Double((value >> 16) & 0xff) / 255, g = Double((value >> 8) & 0xff) / 255, b = Double(value & 0xff) / 255
        let high = max(r, g, b), low = min(r, g, b), chroma = high - low
        guard chroma > 0.25 else { return .idle }
        var hue: Double
        if high == r { hue = (g - b) / chroma } else if high == g { hue = (b - r) / chroma + 2 } else { hue = (r - g) / chroma + 4 }
        hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
        switch hue {
        case 20..<65: return .attention
        case 65..<170: return .done
        case 170..<260: return .running
        case 260..<330: return .merged
        default: return .failed
        }
    }
}
