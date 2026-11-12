import Foundation
import ShepherdCore
import ShepherdProtocol

/// Which of a turn's changed files are its own. A turn's record is the working-tree diff over
/// its window; when another writer was in the same working tree during that window, the diff is
/// cut to the files the turn's own successful `edit` and `write` calls named and no other
/// writer's call named. Pure, so the unit tests read it; the engine supplies the evidence
/// (`WriterLog`) and the git work (`ChangesService+Turns`).
enum TurnAttribution {
    /// Receipt lag of pi's events, in ms: a tool call or a turn pi started itself is stamped
    /// when the host read its event, a moment after the write may have begun.
    static let lead: Double = 2_000

    /// A stretch of host-clock ms; an open end is still running.
    struct Interval: Equatable, Sendable {
        var start: Double
        var end: Double?

        func overlaps(_ other: Interval, now: Double) -> Bool {
            start < (other.end ?? now) && other.start < (end ?? now)
        }
    }

    /// Where a turn's window begins: when the host prompted it, which comes before any write
    /// (before even a `UserPromptSubmit` hook); a turn pi started itself, and a tool call, are
    /// read a moment late.
    static func windowStart(promptedAt: Double?, receivedAt: Double) -> Double {
        promptedAt ?? receivedAt - lead
    }

    /// A file the turn changed: its path, and where it came from when git sees a rename.
    struct Change: Equatable, Sendable {
        var path: String
        var oldPath: String?

        init(path: String, oldPath: String? = nil) {
            self.path = path
            self.oldPath = oldPath
        }

        init(_ file: ChangesFile) {
            self.init(path: file.path, oldPath: file.oldPath)
        }

        var paths: Set<String> { Set([path] + (oldPath.map { [$0] } ?? [])) }
    }

    /// Another writer was in the working tree during `window`: any of `writers` overlaps it.
    static func isShared(window: Interval, writers: [Interval], now: Double) -> Bool {
        writers.contains { $0.overlaps(window, now: now) }
    }

    /// The rule. A file Shepherd wrote for the person is other; a solo turn owns the rest; a
    /// shared turn owns a file only when every path of it (a rename's two) was named by its own
    /// calls and by none of the other writers'.
    static func classify(changed: [Change], shared: Bool, named: Set<String>, foreign: Set<String>,
                         saved: Set<String>) -> (own: Set<String>, other: Set<String>) {
        var own: Set<String> = []
        var other: Set<String> = []
        for file in changed {
            let paths = file.paths
            if !paths.isDisjoint(with: saved) {
                other.insert(file.path)
            } else if !shared || (paths.isSubset(of: named) && paths.isDisjoint(with: foreign)) {
                own.insert(file.path)
            } else {
                other.insert(file.path)
            }
        }
        return (own, other)
    }

    // MARK: Evidence

    /// What the writer log says about one turn's window.
    struct Evidence: Equatable, Sendable {
        var shared = false
        /// Repository-relative paths of the turn's own successful calls.
        var named: Set<String> = []
        /// Paths other agents' calls named, whatever those calls' outcome, and who.
        var foreign: [String: AgentID] = [:]
        /// Paths Shepherd wrote for the person during the window.
        var saved: Set<String> = []
        /// An agent that shared the working tree, for a message that names no file.
        var partner: AgentID?
        /// The log lost something that overlapped the window: nothing can be proven own.
        var lossy = false
    }

    /// Reads `log` for `window`. `sameTree` says whether a directory is in the turn's working
    /// tree, `relative` resolves a call's path from its directory to one under the root (or
    /// nil), `savedPath` does the same for an absolute path Shepherd wrote.
    static func evidence(window: WriterLog.Window, log: WriterLog, now: Double,
                         sameTree: (String) -> Bool, relative: (_ path: String, _ cwd: String) -> String?,
                         savedPath: (String) -> String?) -> Evidence {
        var evidence = Evidence()
        func join(_ agent: AgentID) {
            evidence.shared = true
            if evidence.partner == nil { evidence.partner = agent }
        }
        func overlapping(_ interval: Interval) -> Bool { isShared(window: window.interval, writers: [interval], now: now) }
        for other in log.windows where other.agent != window.agent && overlapping(other.interval) && sameTree(other.cwd) {
            join(other.agent)
        }
        for call in log.calls {
            if call.agent == window.agent {
                if call.turn == window.turn, call.ok == true, let path = relative(call.path, call.cwd) {
                    evidence.named.insert(path)
                }
                continue
            }
            guard overlapping(call.interval) else { continue }
            let landing = relative(call.path, call.cwd)
            guard landing != nil || sameTree(call.cwd) else { continue }
            join(call.agent)
            if let landing { evidence.foreign[landing] = evidence.foreign[landing] ?? call.agent }
        }
        for span in log.spans where overlapping(span.interval) {
            if let tree = span.tree {
                if sameTree(tree) { evidence.shared = true }
            } else {
                evidence.saved.formUnion(span.paths.compactMap(savedPath))
            }
        }
        if log.lost.contains(where: overlapping) {
            evidence.lossy = true
            evidence.shared = true
        }
        return evidence
    }

    /// `classify` over `evidence`: a lossy log proves nothing, so every file is other.
    static func classify(changed: [Change], evidence: Evidence) -> (own: Set<String>, other: Set<String>) {
        if evidence.lossy { return ([], Set(changed.map(\.path))) }
        return classify(changed: changed, shared: evidence.shared, named: evidence.named,
                        foreign: Set(evidence.foreign.keys), saved: evidence.saved)
    }

    // MARK: Paths

    /// Where pi writes `raw` when it runs in `cwd` (`resolveToCwd`): unicode spaces become
    /// spaces, a leading `@` goes, `~` and `~/` are the home folder, a `file://` URL is its path,
    /// a relative path joins the directory. The result is cleaned of `.` and `..`, its parent
    /// folder is replaced by `realParent`'s answer (the caller's `realpath`, so a symlinked
    /// folder lands where git sees it), and it is kept only under `root`, as a path from it.
    static func relativePath(_ raw: String, cwd: String, home: String, root: String,
                             realParent: (String) -> String) -> String? {
        var path = String(raw.unicodeScalars.map { Self.unicodeSpaces.contains($0.value) ? " " : Character($0) })
        if path.hasPrefix("@") { path.removeFirst() }
        if path.hasPrefix("file://") {
            guard let url = URL(string: path), url.isFileURL else { return nil }
            path = url.path
        }
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + String(path.dropFirst())
        }
        guard !path.isEmpty else { return nil }
        let absolute = path.hasPrefix("/") ? path : cwd + "/" + path
        let clean = normalized(absolute)
        guard clean != "/", let slash = clean.lastIndex(of: "/") else { return nil }
        let parent = slash == clean.startIndex ? "/" : String(clean[..<slash])
        let name = String(clean[clean.index(after: slash)...])
        let real = realParent(parent)
        let resolved = real == "/" ? "/" + name : real + "/" + name
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard resolved.hasPrefix(prefix), resolved.count > prefix.count else { return nil }
        return String(resolved.dropFirst(prefix.count))
    }

    /// An absolute path without `.`, `..` or repeated slashes, read lexically.
    static func normalized(_ absolute: String) -> String {
        var parts: [Substring] = []
        for part in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// pi's `UNICODE_SPACES`: no-break, en to hair, narrow no-break, medium mathematical, ideographic.
    private static let unicodeSpaces: Set<UInt32> = Set([0x00A0, 0x202F, 0x205F, 0x3000] + Array(0x2000...0x200A))

    // MARK: The own tree

    /// What `git update-index -z --index-info` takes to move a tree that has the `start` of a
    /// turn to the end of it for `own` paths only, from `git diff --raw --no-abbrev --no-renames
    /// -z start end`: `<mode> <id>\t<path>`, a deletion as mode 000000 and the zero id.
    static func indexInfo(rawDiff: Data, own: Set<String>) -> Data {
        let fields = rawDiff.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var output = Data()
        var index = 0
        while index + 1 < fields.count {
            let meta = fields[index].dropFirst().split(separator: " ")
            let path = fields[index + 1]
            index += 2
            guard meta.count >= 4, own.contains(String(path)) else { continue }
            output.append(Data("\(meta[1]) \(meta[3])\t\(path)\0".utf8))
        }
        return output
    }
}
