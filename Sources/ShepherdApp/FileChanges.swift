import Foundation
import ShepherdProtocol
import ShepherdRemote

/// What the Files tab knows of the thread's changes (GXPaneFiles): the files the Changes pane
/// lists, as git status letters in the tree, a sentence under the open file's path, the lines
/// the diff added, and the footer's count. Read from the review the pane already holds; nothing
/// is loaded for it.
struct FileChanges {
    /// Where the files live: "This Mac", or the remote host's name.
    let host: String
    /// The changed files by path from the repository's root; nil while the review loads.
    let files: [String: DiffFile]?
    /// The review compares the agent's last turn, so the added lines are what it just changed.
    let isLastTurn: Bool

    init(host: String = "This Mac", files: [String: DiffFile]?, isLastTurn: Bool) {
        self.host = host
        self.files = files
        self.isLastTurn = isLastTurn
    }

    /// Changed files, once known.
    var count: Int? { files?.count }

    /// `path`'s diff, for a path under `root`.
    func file(at path: String, root: String) -> DiffFile? {
        guard let files, !files.isEmpty else { return nil }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return files[String(path.dropFirst(prefix.count))]
    }

    /// The letter the tree shows by a file: A or M (R for a rename), nothing for a deleted file.
    func letter(at path: String, root: String) -> ReviewFileStatus? {
        guard let file = file(at: path, root: root) else { return nil }
        let status = ReviewFileStatus(file)
        return status == .deleted ? nil : status
    }

    /// The lines (from 1) the diff added to the file as it is now.
    static func addedLines(of file: DiffFile) -> Set<Int> {
        var lines = Set<Int>()
        for hunk in file.hunks {
            for line in hunk.lines where line.kind == .added {
                if let number = line.newLine { lines.insert(number) }
            }
        }
        return lines
    }

    /// The tree footer: where the files are, then how many changed, or the file the agent is editing.
    func note(agentFile: String?) -> String {
        if let agentFile { return "The agent is editing \((agentFile as NSString).lastPathComponent). Your edits stay yours until you save." }
        guard let count else { return "The thread\u{2019}s worktree on \(host), live." }
        return "The thread\u{2019}s worktree on \(host), live. \(count) changed."
    }

    /// The line under the open file's path: "Added by this thread, 25 lines, Go. Green lines changed in the last turn."
    func subtitle(for file: DiffFile, lines: Int?, language: String?, marksLines: Bool) -> String {
        let who = switch ReviewFileStatus(file) {
        case .added: "Added by this thread"
        case .renamed: "Renamed by this thread"
        default: "Changed by this thread"
        }
        let facts = [lines.map { "\($0) line\($0 == 1 ? "" : "s")" }, language].compactMap { $0 }
        let first = ([who] + facts).joined(separator: ", ") + "."
        guard marksLines else { return first }
        return first + (isLastTurn ? " Green lines changed in the last turn." : " Green lines are the additions Changes shows.")
    }
}

extension ReviewSession {
    /// The changed files by path, kept until the files change.
    var changedFilesByPath: [String: DiffFile] {
        if let cache = changesCache, cache.version == filesVersion { return cache.files }
        let byPath = files.reduce(into: [String: DiffFile]()) { $0[$1.displayPath] = $1 }
        changesCache = (filesVersion, byPath)
        return byPath
    }

    /// The Files tab's view of this review.
    func fileChanges(host: String = "This Mac") -> FileChanges {
        FileChanges(host: host, files: isLoading ? nil : changedFilesByPath, isLastTurn: scope.kind == .lastTurn)
    }
}

extension ReviewFileStatus {
    /// The git status letter.
    var letter: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        }
    }

    var word: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        }
    }
}
