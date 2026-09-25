import Foundation
import ShepherdProtocol

// A commit from review, as every client draws it and the host writes it: the file rows with
// their checkboxes, the plain message written from the file list, a drafted message read from
// a model's reply, the branch a pull request from the default branch creates, what each option
// says, and why Commit can't run yet. The host runs the commit (`ReviewCommitter` on the Mac).

// MARK: Files

/// A file row of the commit sheet: its name over its directory, status, diff stat, and whether
/// the commit takes it.
public struct ReviewCommitFileRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// "App/iOS/" (with its slash), or "" at the repository's root.
    public let directory: String
    public let status: ReviewFileStatus
    public let added: Int
    public let removed: Int
    public let selected: Bool

    public init(file: RemoteCommitFile, selected: Bool) {
        id = file.id
        (directory, name) = reviewPathParts(file.path)
        status = ReviewFileStatus(letter: file.status)
        added = file.added
        removed = file.removed
        self.selected = selected
    }
}

extension ReviewFileStatus {
    /// The status letter a commit file carries: M, A, D or R (anything else reads as modified).
    public init(letter: String) {
        switch letter.uppercased() {
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        default: self = .modified
        }
    }

    public var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        }
    }
}

public func reviewCommitRows(_ files: [RemoteCommitFile], selected: Set<String>) -> [ReviewCommitFileRow] {
    files.map { ReviewCommitFileRow(file: $0, selected: selected.contains($0.id)) }
}

/// The review's files as the commit takes them, each with the host's fingerprint of it.
public func reviewCommitFiles(_ files: [DiffFile], fingerprint: (DiffFile) -> String) -> [RemoteCommitFile] {
    files.map { file in
        let status = ReviewFileStatus(file)
        let path = file.isDeleted ? (file.oldPath ?? file.displayPath) : (file.newPath ?? file.displayPath)
        return RemoteCommitFile(path: path, oldPath: file.isRenamed ? file.oldPath : nil, status: status.letter,
                                added: file.addedCount, removed: file.removedCount, fingerprint: fingerprint(file))
    }
}

/// "3 of 3".
public func reviewCommitSelectionText(selected: Int, of total: Int) -> String { "\(selected) of \(total)" }

// MARK: The message

/// A message written from the file list, for a host that drafts none or while it drafts:
/// "Update FleetView.swift", "Add 2 files in App/iOS", and with several files, one line each.
public func reviewCommitFallbackMessage(_ files: [RemoteCommitFile]) -> (title: String, body: String) {
    guard let first = files.first else { return ("", "") }
    let statuses = Set(files.map { ReviewFileStatus(letter: $0.status) })
    let verb: String = if statuses.count == 1 {
        switch statuses.first! {
        case .added: "Add"
        case .deleted: "Remove"
        case .renamed: "Rename"
        case .modified: "Update"
        }
    } else { "Update" }
    if files.count == 1 {
        let name = reviewPathParts(first.path).name
        if statuses == [.renamed], let old = first.oldPath {
            return ("Rename \(reviewPathParts(old).name) to \(name)", "")
        }
        return ("\(verb) \(name)", "")
    }
    let directories = files.map { reviewPathParts($0.path).directory }
    let common = reviewCommonDirectory(directories)
    let scope = common.isEmpty ? "" : " in \(common.hasSuffix("/") ? String(common.dropLast()) : common)"
    let body = files.map { "- \($0.path)" }.joined(separator: "\n")
    return ("\(verb) \(files.count) files\(scope)", body)
}

/// The deepest directory every one of `directories` sits in ("App/iOS/"), or "".
func reviewCommonDirectory(_ directories: [String]) -> String {
    guard var common = directories.first?.split(separator: "/", omittingEmptySubsequences: true).map(String.init) else { return "" }
    for directory in directories.dropFirst() {
        let parts = directory.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
    }
    return common.isEmpty ? "" : common.joined(separator: "/") + "/"
}

/// The subject a commit keeps to: longer ones are cut at a word.
public let reviewCommitTitleLimit = 72

/// A model's reply read as a commit message: code fences, a "Subject:" label, a heading's "#"
/// and quotes come off; the first line is the title, the rest the body. nil when nothing is left.
public func reviewCommitMessage(fromModel output: String) -> (title: String, body: String)? {
    var lines = output.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
    while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
    guard var title = lines.first?.trimmingCharacters(in: .whitespaces) else { return nil }
    lines.removeFirst()
    for label in ["subject:", "title:", "commit message:"] where title.lowercased().hasPrefix(label) {
        title = String(title.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
    }
    while title.hasPrefix("#") { title = String(title.dropFirst()).trimmingCharacters(in: .whitespaces) }
    for quote in ["\"", "'", "`"] where title.count > 1 && title.hasPrefix(quote) && title.hasSuffix(quote) {
        title = String(title.dropFirst().dropLast())
    }
    title = reviewCommitShortened(title.trimmingCharacters(in: .whitespaces))
    guard !title.isEmpty else { return nil }
    var bodyLines = lines
    if let label = bodyLines.first?.trimmingCharacters(in: .whitespaces).lowercased(), label == "body:" { bodyLines.removeFirst() }
    let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return (title, body)
}

/// `title` cut at the last word that fits `reviewCommitTitleLimit`.
public func reviewCommitShortened(_ title: String) -> String {
    guard title.count > reviewCommitTitleLimit else { return title }
    let cut = title.prefix(reviewCommitTitleLimit)
    if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > reviewCommitTitleLimit / 2 {
        return String(cut[..<space])
    }
    return String(cut)
}

/// The message git records: the title, a blank line, then the body when there is one.
public func reviewCommitMessageText(title: String, body: String) -> String {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return body.isEmpty ? title : title + "\n\n" + body
}

/// The branch a pull request from the default branch creates: "shepherd/" and the title as a
/// slug ("shepherd/show-commands-and-paths-in-tool-rows").
public func reviewCommitBranchName(title: String) -> String {
    var slug = ""
    var dash = false
    for scalar in title.lowercased().unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
            slug.unicodeScalars.append(scalar)
            dash = false
        } else if !dash && !slug.isEmpty {
            slug.append("-")
            dash = true
        }
    }
    while slug.hasSuffix("-") { slug.removeLast() }
    if slug.count > 48 {
        slug = String(slug.prefix(48))
        if let dash = slug.lastIndex(of: "-"), slug.distance(from: slug.startIndex, to: dash) > 24 { slug = String(slug[..<dash]) }
    }
    return "shepherd/" + (slug.isEmpty ? "commit" : slug)
}

// MARK: The options

/// Where the sheet's options send the commit.
public func reviewCommitPush(push: Bool, pullRequest: Bool) -> RemoteCommitPush {
    pullRequest ? .pullRequest : push ? .upstream : .none
}

/// The primary action: "Commit", "Commit & push", or "Commit & open PR".
public func reviewCommitActionTitle(_ push: RemoteCommitPush) -> String {
    switch push {
    case .none: "Commit"
    case .upstream: "Commit & push"
    case .pullRequest: "Commit & open PR"
    }
}

/// Under "Push after commit": the upstream ("origin/main"), the upstream a push sets
/// ("origin/feat-x · sets upstream"), or why there is nowhere to push.
public func reviewCommitPushDetail(_ info: RemoteCommitInfo) -> String {
    if let upstream = info.upstream { return upstream }
    guard let branch = info.branch else { return "no branch checked out" }
    guard let remote = info.pushRemote else { return "no remote to push to" }
    return "\(remote)/\(branch) · sets upstream"
}

/// Under "Open a pull request instead": what it pushes and where the PR goes.
public func reviewCommitPullRequestDetail(_ info: RemoteCommitInfo, title: String) -> String {
    guard info.pushRemote != nil || info.upstream != nil else { return "no remote to push to" }
    guard let base = info.defaultBranch else { return "pushes a branch and opens the PR" }
    if info.onDefaultBranch { return "creates \(reviewCommitBranchName(title: title)), opens a PR into \(base)" }
    return "pushes \(info.branch ?? "the branch"), opens a PR into \(base)"
}

/// Whether the branch has somewhere to push.
public func reviewCommitCanPush(_ info: RemoteCommitInfo) -> Bool {
    info.branch != nil && (info.upstream != nil || info.pushRemote != nil)
}

/// Whether a pull request can be opened from here.
public func reviewCommitCanOpenPullRequest(_ info: RemoteCommitInfo) -> Bool {
    reviewCommitCanPush(info) && info.defaultBranch != nil
}

/// Why Commit can't run yet, or nil when it can.
public func reviewCommitProblem(_ info: RemoteCommitInfo, selected: Int, title: String, push: RemoteCommitPush,
                                confirmedWhileWorking: Bool) -> String? {
    if let blocked = info.blocked { return blocked }
    if info.files.isEmpty { return "Nothing to commit." }
    if selected == 0 { return "Choose at least one file." }
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write a commit message." }
    if push == .upstream && !reviewCommitCanPush(info) { return "This branch has nowhere to push." }
    if push == .pullRequest && !reviewCommitCanOpenPullRequest(info) { return "A pull request needs a remote and its default branch." }
    if info.agentWorking && !confirmedWhileWorking { return "Confirm committing while the agent works." }
    return nil
}

// MARK: The operation

/// Where a commit operation stands.
public enum ReviewCommitOutcome: Equatable, Sendable {
    case running
    case succeeded(prURL: String?)
    case failed(String)

    public init(_ operation: RemoteWorktreeOperation) {
        if !operation.finished {
            self = .running
        } else if let error = operation.error {
            self = .failed(error)
        } else {
            self = .succeeded(prURL: operation.prURL)
        }
    }
}

/// The commit's steps, labeled as the host reports them ("commit 3 files: committed 1a2b3c4").
public enum ReviewCommitStepLabel {
    public static let check = "check the checkout"
    public static func branch(_ name: String) -> String { "create branch \(name)" }
    public static func commit(_ count: Int) -> String { "commit \(count) file\(count == 1 ? "" : "s")" }
    public static func push(_ target: String) -> String { "push to \(target)" }
    public static func pullRequest(_ base: String?) -> String { base.map { "open a pull request into \($0)" } ?? "open a pull request" }
}
