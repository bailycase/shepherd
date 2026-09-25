import Foundation

// A review's diff: the files of `git diff`, each with its hunks and numbered lines. The remote
// protocol carries it JSON-encoded (`RemoteAgentResult.review(files:)`), so every client that
// reviews a host's changes decodes it; the Mac's `GitDiff` loads it from git.

public struct DiffLine: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case context
        case added
        case removed
    }

    public let kind: Kind
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?
    public let id: Int

    public init(kind: Kind, text: String, oldLine: Int?, newLine: Int?, id: Int) {
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
        self.id = id
    }
}

public struct DiffHunk: Codable, Hashable, Identifiable, Sendable {
    public let header: String
    public let lines: [DiffLine]

    public init(header: String, lines: [DiffLine]) {
        self.header = header
        self.lines = lines
    }

    public var id: String {
        "\(header)#\(lines.first?.id ?? 0)"
    }
}

public struct DiffFile: Codable, Hashable, Identifiable, Sendable {
    public let oldPath: String?
    public let newPath: String?
    public let displayPath: String
    public let isNew: Bool
    public let isDeleted: Bool
    public let isRenamed: Bool
    public let isBinary: Bool
    public let hunks: [DiffHunk]

    public var id: String { displayPath }
    // Stored, not computed: headers render on every scroll tick and a
    // flatMap over all lines per render was measurable on large diffs.
    public let addedCount: Int
    public let removedCount: Int

    public init(
        oldPath: String?,
        newPath: String?,
        displayPath: String,
        isNew: Bool,
        isDeleted: Bool,
        isRenamed: Bool,
        isBinary: Bool,
        hunks: [DiffHunk]
    ) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.displayPath = displayPath
        self.isNew = isNew
        self.isDeleted = isDeleted
        self.isRenamed = isRenamed
        self.isBinary = isBinary
        self.hunks = hunks
        let lines = hunks.flatMap(\.lines)
        self.addedCount = lines.filter { $0.kind == .added }.count
        self.removedCount = lines.filter { $0.kind == .removed }.count
    }
}

extension DiffFile {
    /// Unified diff text (`git diff`, `git diff --no-index`) → files, hunks, and numbered lines.
    public static func parse(_ unified: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: ParsedFile?

        for rawLine in unified.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.hasPrefix("diff --git ") {
                if let current {
                    files.append(current.result())
                }
                var next = ParsedFile()
                let paths = diffGitPaths(line)
                next.oldPath = paths.old
                next.newPath = paths.new
                current = next
                continue
            }

            if current == nil {
                guard line.hasPrefix("--- ") else { continue }
                current = ParsedFile()
            }

            if line.hasPrefix("@@"), let range = hunkRange(line) {
                current!.startHunk(header: line, oldLine: range.oldStart, newLine: range.newStart)
                continue
            }

            if current!.addHunkLine(line) {
                continue
            }

            if line.hasPrefix("--- "), current!.hunkHeader == nil, current!.hunks.isEmpty {
                current!.oldPath = markerPath(line)
                continue
            }
            if line.hasPrefix("+++ "), current!.hunkHeader == nil, current!.hunks.isEmpty {
                current!.newPath = markerPath(line)
                continue
            }

            if line.hasPrefix("new file mode ") {
                current!.isNew = true
            } else if line.hasPrefix("deleted file mode ") {
                current!.isDeleted = true
            } else if line.hasPrefix("rename from ") {
                current!.oldPath = cleanPath(String(line.dropFirst("rename from ".count)))
                current!.isRenamed = true
            } else if line.hasPrefix("rename to ") {
                current!.newPath = cleanPath(String(line.dropFirst("rename to ".count)))
                current!.isRenamed = true
            } else if line.hasPrefix("Binary files ") {
                current!.isBinary = true
                let body = String(line.dropFirst("Binary files ".count))
                if let separator = body.range(of: " and "),
                   body.hasSuffix(" differ") {
                    current!.oldPath = cleanPath(String(body[..<separator.lowerBound]), stripPrefix: true)
                    current!.newPath = cleanPath(String(body[separator.upperBound..<body.index(body.endIndex, offsetBy: -7)]), stripPrefix: true)
                }
            } else if line == "GIT binary patch" {
                current!.isBinary = true
            }
        }

        if let current {
            files.append(current.result())
        }
        return files
    }

    private struct HunkRange {
        let oldStart: Int
        let newStart: Int
    }

    private struct ParsedFile {
        var oldPath: String?
        var newPath: String?
        var isNew = false
        var isDeleted = false
        var isRenamed = false
        var isBinary = false
        var hunks: [DiffHunk] = []
        var hunkHeader: String?
        var hunkLines: [DiffLine] = []
        var oldLine = 0
        var newLine = 0
        var nextLineID = 0

        mutating func startHunk(header: String, oldLine: Int, newLine: Int) {
            finishHunk()
            hunkHeader = header
            self.oldLine = oldLine
            self.newLine = newLine
        }

        mutating func addHunkLine(_ line: String) -> Bool {
            guard hunkHeader != nil else { return false }
            if line.hasPrefix("\\ No newline at end of file") {
                return true
            }

            let kind: DiffLine.Kind
            let text: String
            switch line.first {
            case " ":
                kind = .context
                text = String(line.dropFirst())
            case "+":
                kind = .added
                text = String(line.dropFirst())
            case "-":
                kind = .removed
                text = String(line.dropFirst())
            default:
                return false
            }

            hunkLines.append(DiffLine(
                kind: kind,
                text: text,
                oldLine: kind == .added ? nil : oldLine,
                newLine: kind == .removed ? nil : newLine,
                id: nextLineID
            ))
            nextLineID += 1
            switch kind {
            case .context:
                oldLine += 1
                newLine += 1
            case .added:
                newLine += 1
            case .removed:
                oldLine += 1
            }
            return true
        }

        mutating func finishHunk() {
            guard let hunkHeader else { return }
            hunks.append(DiffHunk(header: hunkHeader, lines: hunkLines))
            self.hunkHeader = nil
            hunkLines.removeAll(keepingCapacity: true)
        }

        func result() -> DiffFile {
            var copy = self
            copy.finishHunk()
            let oldPath = copy.isNew ? nil : copy.oldPath
            let newPath = copy.isDeleted ? nil : copy.newPath
            return DiffFile(
                oldPath: oldPath,
                newPath: newPath,
                displayPath: newPath ?? oldPath ?? "(unknown)",
                isNew: copy.isNew || (oldPath == nil && newPath != nil),
                isDeleted: copy.isDeleted || (oldPath != nil && newPath == nil),
                isRenamed: copy.isRenamed || (oldPath != nil && newPath != nil && oldPath != newPath),
                isBinary: copy.isBinary,
                hunks: copy.hunks
            )
        }
    }

    private static func hunkRange(_ line: String) -> HunkRange? {
        let start = line.index(line.startIndex, offsetBy: min(2, line.count))
        guard let end = line.range(of: "@@", range: start..<line.endIndex) else { return nil }
        let tokens = line[start..<end.lowerBound].split(whereSeparator: \.isWhitespace)
        guard let old = tokens.first(where: { $0.first == "-" }),
              let new = tokens.first(where: { $0.first == "+" }),
              let oldStart = rangeStart(String(old.dropFirst())),
              let newStart = rangeStart(String(new.dropFirst())) else {
            return nil
        }
        return HunkRange(oldStart: oldStart, newStart: newStart)
    }

    private static func rangeStart(_ value: String) -> Int? {
        Int(value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
    }

    private static func diffGitPaths(_ line: String) -> (old: String?, new: String?) {
        let body = String(line.dropFirst("diff --git ".count))
        guard body.hasPrefix("a/"), let separator = body.range(of: " b/", options: .backwards) else {
            return (nil, nil)
        }
        let old = cleanPath(String(body[..<separator.lowerBound]), stripPrefix: true)
        let new = cleanPath(String(body[separator.upperBound...]), stripPrefix: true)
        return (old, new)
    }

    private static func markerPath(_ line: String) -> String? {
        cleanPath(String(line.dropFirst(4)), stripPrefix: true)
    }

    private static func cleanPath(_ raw: String, stripPrefix: Bool = false) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tab = path.firstIndex(of: "\t") {
            path = String(path[..<tab])
        }
        if path == "/dev/null" { return nil }
        if path.count >= 2, path.first == "\"", path.last == "\"" {
            path = String(path.dropFirst().dropLast())
        }
        if stripPrefix && (path.hasPrefix("a/") || path.hasPrefix("b/")) {
            path.removeFirst(2)
        }
        return path
    }
}
