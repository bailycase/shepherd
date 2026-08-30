import Foundation

struct DiffLine: Hashable, Identifiable {
    enum Kind: Hashable {
        case context
        case added
        case removed
    }

    let kind: Kind
    let text: String
    let oldLine: Int?
    let newLine: Int?
    let id: Int
}

struct DiffHunk: Hashable, Identifiable {
    let header: String
    let lines: [DiffLine]

    var id: String {
        "\(header)#\(lines.first?.id ?? 0)"
    }
}

struct DiffFile: Hashable, Identifiable {
    let oldPath: String?
    let newPath: String?
    let displayPath: String
    let isNew: Bool
    let isDeleted: Bool
    let isRenamed: Bool
    let isBinary: Bool
    let hunks: [DiffHunk]

    var id: String { displayPath }
    var addedCount: Int {
        hunks.flatMap(\.lines).filter { $0.kind == .added }.count
    }
    var removedCount: Int {
        hunks.flatMap(\.lines).filter { $0.kind == .removed }.count
    }
}

enum GitDiff {
    static func parse(_ unified: String) -> [DiffFile] {
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

    static func load(cwd: String, reference: String?) throws -> [DiffFile] {
        let diffArguments = ["-c", "core.quotepath=off", "diff", "--no-color", reference ?? "HEAD"]
        let tracked = try runGit(diffArguments, cwd: cwd)
        guard tracked.status == 0 else {
            throw GitDiffError.commandFailed(
                command: commandDescription(diffArguments), status: tracked.status, stderr: tracked.stderr
            )
        }

        var files = parse(tracked.stdout)
        guard reference == nil else { return files }

        let listArguments = ["-c", "core.quotepath=off", "ls-files", "--others", "--exclude-standard"]
        let untracked = try runGit(listArguments, cwd: cwd)
        guard untracked.status == 0 else {
            throw GitDiffError.commandFailed(
                command: commandDescription(listArguments), status: untracked.status, stderr: untracked.stderr
            )
        }

        for path in untracked.stdout.split(whereSeparator: \.isNewline).map(String.init) {
            let arguments = ["-c", "core.quotepath=off", "diff", "--no-color", "--no-index", "--", "/dev/null", path]
            let result = try runGit(arguments, cwd: cwd)
            guard result.status == 0 || result.status == 1 else {
                throw GitDiffError.commandFailed(
                    command: commandDescription(arguments), status: result.status, stderr: result.stderr
                )
            }
            files.append(contentsOf: parse(result.stdout))
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

    private enum GitDiffError: Error, CustomStringConvertible {
        case couldNotStart(String)
        case commandFailed(command: String, status: Int32, stderr: String)

        var description: String {
            switch self {
            case .couldNotStart(let message):
                return message
            case .commandFailed(let command, let status, let stderr):
                let detail = stderr.isEmpty ? "no stderr" : stderr
                return "git command failed (exit \(status)): \(command): \(detail)"
            }
        }
    }

    private struct GitResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func runGit(_ arguments: [String], cwd: String) throws -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw GitDiffError.couldNotStart("could not start git in \(cwd): \(error.localizedDescription)")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        return GitResult(
            status: process.terminationStatus,
            stdout: String(decoding: output, as: UTF8.self),
            stderr: String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func commandDescription(_ arguments: [String]) -> String {
        (["git"] + arguments).joined(separator: " ")
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
