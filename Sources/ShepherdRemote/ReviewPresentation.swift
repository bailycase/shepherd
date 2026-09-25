import Foundation
import ShepherdProtocol

// What a review screen draws, derived once per change: the changed files as list rows, the
// review's totals, a file's rows side by side, and the requests a remote review makes. Shared
// by every client that reviews a host's changes (the iOS client today).

// MARK: Files

/// A changed file's status letter: M, A, D or R.
public enum ReviewFileStatus: String, Sendable, Hashable, CaseIterable {
    case modified, added, deleted, renamed

    public init(_ file: DiffFile) {
        if file.isNew { self = .added } else if file.isDeleted { self = .deleted } else if file.isRenamed { self = .renamed } else { self = .modified }
    }
}

/// One changed file as a list row (MobileChanges, the iPad file list): its name over its
/// directory, status, diff stat, viewed mark, and how many comments it carries.
public struct ReviewFileSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: String
    /// "App/iOS/" (with its slash), or "" at the repository's root.
    public let directory: String
    public let name: String
    public let status: ReviewFileStatus
    public let added: Int
    public let removed: Int
    public let hunks: Int
    public let isBinary: Bool
    public let comments: Int
    public let viewed: Bool

    public init(file: DiffFile, comments: Int, viewed: Bool) {
        id = file.id
        path = file.displayPath
        (directory, name) = reviewPathParts(file.displayPath)
        status = ReviewFileStatus(file)
        added = file.addedCount
        removed = file.removedCount
        hunks = file.hunks.count
        isBinary = file.isBinary
        self.comments = comments
        self.viewed = viewed
    }
}

/// "App/iOS/FleetView.swift" → ("App/iOS/", "FleetView.swift").
public func reviewPathParts(_ path: String) -> (directory: String, name: String) {
    guard let slash = path.lastIndex(of: "/") else { return ("", path) }
    return (String(path[...slash]), String(path[path.index(after: slash)...]))
}

/// The review's files, lines added and removed, and how many are viewed.
public struct ReviewTotals: Equatable, Sendable {
    public let files: Int
    public let added: Int
    public let removed: Int
    public let viewed: Int

    public init(files: Int, added: Int, removed: Int, viewed: Int) {
        self.files = files
        self.added = added
        self.removed = removed
        self.viewed = viewed
    }

    /// Viewed files as a share of all of them, 0 with none.
    public var progress: Double { files == 0 ? 0 : Double(viewed) / Double(files) }

    /// "3 files".
    public var filesText: String { "\(files) file\(files == 1 ? "" : "s")" }
    /// "1 of 3 viewed".
    public var viewedText: String { "\(viewed) of \(files) viewed" }
}

/// Each file's row and the totals, in the diff's order. Viewed marks and comments for files no
/// longer in the diff are ignored.
public func reviewSummaries(files: [DiffFile], comments: [ReviewComment], viewed: Set<String>) -> (rows: [ReviewFileSummary], totals: ReviewTotals) {
    let counts = comments.reduce(into: [String: Int]()) { $0[$1.fileID, default: 0] += 1 }
    let rows = files.map { ReviewFileSummary(file: $0, comments: counts[$0.id] ?? 0, viewed: viewed.contains($0.id)) }
    let totals = ReviewTotals(files: rows.count, added: rows.reduce(0) { $0 + $1.added }, removed: rows.reduce(0) { $0 + $1.removed },
                              viewed: rows.filter(\.viewed).count)
    return (rows, totals)
}

/// "working tree vs HEAD", or the reference a PR review diffed against.
public func reviewScopeText(pullRequest: Bool, reference: String?) -> String {
    guard let reference, !reference.isEmpty else { return pullRequest ? "the pull request" : "working tree vs HEAD" }
    return reference
}

/// Whether Request changes has anything to send: a line comment or an overall comment.
public func reviewHasNotes(comments: [ReviewComment], summary: String) -> Bool {
    !comments.isEmpty || !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

// MARK: Side by side

/// One row of a file's diff side by side (iPadReviewSplit): the old file's line beside the new
/// one's. A removal and the addition that replaced it share a row; context shows on both sides.
public struct ReviewSplitRow: Identifiable, Equatable, Sendable {
    public enum Side: Sendable, Hashable { case old, new, both }

    public enum Kind: Equatable, Sendable {
        case hunk(String)
        case pair(old: DiffLine?, new: DiffLine?)
        /// A folded run, drawn on the side its lines belong to.
        case collapsed(key: String, count: Int, kind: DiffLine.Kind, range: String, side: Side)
    }

    public let id: String
    public let kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// `reviewRows` side by side: each run of removals pairs, line for line, with the additions that
/// follow it; a fold keeps its own row on its side.
public func reviewSplitRows(_ file: DiffFile, expandedRuns: Set<String>?, threshold: Int = reviewCollapseThreshold) -> [ReviewSplitRow] {
    var result: [ReviewSplitRow] = []
    var removed: [ReviewRow] = []
    var added: [ReviewRow] = []

    func flush() {
        var i = 0, j = 0
        while i < removed.count || j < added.count {
            if i < removed.count, case .collapsed(let key, let count, let kind, let range) = removed[i].kind {
                result.append(ReviewSplitRow(id: removed[i].id, kind: .collapsed(key: key, count: count, kind: kind, range: range, side: .old)))
                i += 1
                continue
            }
            if j < added.count, case .collapsed(let key, let count, let kind, let range) = added[j].kind {
                result.append(ReviewSplitRow(id: added[j].id, kind: .collapsed(key: key, count: count, kind: kind, range: range, side: .new)))
                j += 1
                continue
            }
            let old = i < removed.count ? removed[i] : nil
            let new = j < added.count ? added[j] : nil
            result.append(ReviewSplitRow(id: [old?.id, new?.id].compactMap { $0 }.joined(separator: "|"),
                                         kind: .pair(old: old.flatMap(line), new: new.flatMap(line))))
            i += 1
            j += 1
        }
        removed = []
        added = []
    }

    func line(_ row: ReviewRow) -> DiffLine? {
        if case .line(let line) = row.kind { return line }
        return nil
    }

    func kind(of row: ReviewRow) -> DiffLine.Kind? {
        switch row.kind {
        case .hunk: return nil
        case .line(let line): return line.kind
        case .collapsed(_, _, let kind, _): return kind
        }
    }

    for row in reviewRows(file, expandedRuns: expandedRuns, threshold: threshold) {
        switch kind(of: row) {
        case .removed?:
            if !added.isEmpty { flush() }
            removed.append(row)
        case .added?:
            added.append(row)
        case .context?:
            flush()
            if case .collapsed(let key, let count, let kind, let range) = row.kind {
                result.append(ReviewSplitRow(id: row.id, kind: .collapsed(key: key, count: count, kind: kind, range: range, side: .both)))
            } else if let line = line(row) {
                result.append(ReviewSplitRow(id: row.id, kind: .pair(old: line, new: line)))
            }
        case nil:
            flush()
            if case .hunk(let header) = row.kind { result.append(ReviewSplitRow(id: row.id, kind: .hunk(header))) }
        }
    }
    flush()
    return result
}

// MARK: Requests

public enum RemoteReviewError: Error, Equatable, CustomStringConvertible {
    case unexpectedReply
    case notReady
    case rejected(String)

    public var description: String {
        switch self {
        case .unexpectedReply: return "The host answered with something other than a review."
        case .notReady: return "The agent is not ready yet. Try again in a moment."
        case .rejected(let message): return message
        }
    }
}

/// The files and reference of a host's `review` reply.
public func remoteReviewFiles(_ result: RemoteAgentResult) throws -> (files: [DiffFile], reference: String?) {
    guard case .review(let data, let reference) = result else { throw RemoteReviewError.unexpectedReply }
    return (try JSONDecoder().decode([DiffFile].self, from: data), reference)
}

/// Sends `text` as the agent's next turn, the way the Mac sends a remote review: delivered now
/// when the agent is idle, as a follow-up when it is mid-turn.
public func remoteReviewSend(_ text: String, operationID: UUID = UUID(),
                             thread: (NativeThreadRequest) async throws -> NativeThreadResult) async throws {
    guard case .snapshot(let snapshot) = try await thread(.snapshot()), !snapshot.piSessionID.isEmpty else {
        throw RemoteReviewError.notReady
    }
    let result = try await thread(.send(expectedSessionID: snapshot.piSessionID, generation: snapshot.generation,
                                        operationID: operationID, text: text, delivery: .followUp))
    if case .failure(_, let message) = result { throw RemoteReviewError.rejected(message) }
}
