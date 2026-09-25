import Foundation
import ShepherdProtocol

/// git as the Changes engine runs it: blocking (callers are on the engine's own queues, never
/// the server queue or the main thread), with a configuration that keeps git's output
/// parseable and git itself quiet — no prompts, hooks, pagers, external diff drivers, automatic
/// gc, or optional index refreshes.
struct ChangesGit {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String

        var text: String { String(decoding: stdout, as: UTF8.self) }
        var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static let executable = "/usr/bin/git"

    #if DEBUG
    /// Tests: how many times git ran, by directory (each test's repository is its own).
    static let runs = ChangesLocked<[String: Int]>([:])
    #endif

    /// Configuration every call carries, ahead of the command.
    static let configuration = [
        "-c", "core.quotepath=off", "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0",
        "-c", "maintenance.auto=false", "-c", "diff.relative=false", "-c", "color.ui=false",
        "-c", "core.pager=cat", "-c", "advice.addIgnoredFile=false",
    ]

    /// Runs git in `directory`. `index` points git at another index file (never the user's, for
    /// a command that writes one); `literalPaths` turns off pathspec magic, so paths after `--`
    /// mean exactly those files.
    static func run(_ arguments: [String], in directory: String, index: String? = nil, literalPaths: Bool = false,
                    input: Data? = nil) throws -> Result {
        #if DEBUG
        runs.withValue { $0[directory, default: 0] += 1 }
        #endif
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = configuration + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["LC_ALL"] = "C"
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_LITERAL_PATHSPECS", "GIT_EXTERNAL_DIFF"] {
            environment.removeValue(forKey: key)
        }
        if let index { environment["GIT_INDEX_FILE"] = index }
        if literalPaths { environment["GIT_LITERAL_PATHSPECS"] = "1" }
        process.environment = environment

        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ChangesError(ChangesError.gitFailed, "Could not run git in \(directory): \(error.localizedDescription)")
        }
        // stderr drains on its own thread so a chatty command never blocks on a full pipe.
        let errors = ChangesLocked(Data())
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            errors.withValue { $0 = data }
            drained.signal()
        }
        if let stdin, let input {
            // git may exit before reading all of it: a write then fails instead of raising
            // SIGPIPE, which would end the app.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .utility).async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        drained.wait()
        let message = String(decoding: errors.withValue { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(status: process.terminationStatus, stdout: output, stderr: message)
    }

    /// `run`, throwing unless git exits 0 (or one of `allowed`).
    static func checked(_ arguments: [String], in directory: String, index: String? = nil, literalPaths: Bool = false,
                        input: Data? = nil, allowed: Set<Int32> = [0]) throws -> Result {
        let result = try run(arguments, in: directory, index: index, literalPaths: literalPaths, input: input)
        guard allowed.contains(result.status) else {
            let detail = result.stderr.isEmpty ? "exit \(result.status)" : result.stderr
            throw ChangesError(ChangesError.gitFailed, "git \(arguments.first ?? "") failed: \(detail)")
        }
        return result
    }
}

/// A value behind a lock, for state the engine's queues share.
final class ChangesLocked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    @discardableResult
    func withValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

// MARK: Parsing

/// git's machine output (`-z`) as the engine reads it. Pure, so the unit tests read it too.
enum ChangesParse {
    /// `git diff --raw --numstat -z`: every file's status from the raw records and its counts
    /// from the numstat ones.
    static func files(rawNumstat data: Data) -> [ChangesFile] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var statuses: [(status: Character, old: String, new: String)] = []
        var counts: [String: (added: Int, removed: Int, binary: Bool)] = [:]
        var index = 0
        while index < fields.count {
            let field = fields[index]
            if field.hasPrefix(":") {
                // ":100644 100644 abc def M" then one path, or two for a rename or copy.
                let status = field.split(separator: " ").last?.first ?? "M"
                let twoPaths = status == "R" || status == "C"
                guard index + (twoPaths ? 2 : 1) < fields.count else { break }
                let old = fields[index + 1]
                let new = twoPaths ? fields[index + 2] : old
                statuses.append((status, old, new))
                index += twoPaths ? 3 : 2
            } else if !field.isEmpty {
                // "3\t1\tpath", or "3\t1\t" then the old and new paths of a rename.
                let parts = field.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { index += 1; continue }
                let binary = parts[0] == "-"
                let added = Int(parts[0]) ?? 0, removed = Int(parts[1]) ?? 0
                if parts[2].isEmpty {
                    guard index + 2 < fields.count else { break }
                    counts[fields[index + 2]] = (added, removed, binary)
                    index += 3
                } else {
                    counts[String(parts[2])] = (added, removed, binary)
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return statuses.map { entry in
            let count = counts[entry.new] ?? (0, 0, false)
            let status: ChangesFileStatus
            switch entry.status {
            case "A": status = .added
            case "D": status = .deleted
            case "R": status = .renamed
            case "C": status = .added
            default: status = .modified
            }
            return ChangesFile(path: entry.new, oldPath: status == .renamed ? entry.old : nil, status: status,
                               added: count.added, removed: count.removed, isBinary: count.binary)
        }
    }

    /// `git diff --name-status --no-renames -z`: each path and whether the turn added, deleted
    /// or modified it.
    static func nameStatus(_ data: Data) -> [(status: Character, path: String)] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var result: [(Character, String)] = []
        var index = 0
        while index + 1 < fields.count {
            result.append((fields[index].first ?? "M", fields[index + 1]))
            index += 2
        }
        return result
    }

    /// `git for-each-ref` with fields separated by NUL, one ref per line.
    static func branches(_ text: String, current: String?) -> [ChangesBranch] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { return nil }
            let ref = parts[0], name = parts[1]
            let isRemote = ref.hasPrefix("refs/remotes/")
            // A remote's HEAD is a pointer to one of its branches, not a branch.
            if isRemote, ref.hasSuffix("/HEAD") { return nil }
            let worktree = parts.count > 3 && !parts[3].isEmpty ? parts[3] : nil
            return ChangesBranch(name: name, isRemote: isRemote, worktree: name == current ? nil : worktree,
                                 isCurrent: name == current, committedAt: Double(parts[2]) ?? 0)
        }
    }

    /// `git log --format=%H%x1f%h%x1f%s%x1f%ct%x1e`.
    static func commits(_ text: String) -> [ChangesCommit] {
        text.split(separator: "\u{1E}").compactMap { record in
            let parts = record.trimmingCharacters(in: .newlines).split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, !parts[0].isEmpty else { return nil }
            return ChangesCommit(id: parts[0], shortID: parts[1], subject: parts[2], date: Double(parts[3]) ?? 0)
        }
    }

    /// "origin/main" → "main"; a local branch stays as it is.
    static func baseName(_ base: String, remotes: Set<String>) -> String {
        guard let slash = base.firstIndex(of: "/"), remotes.contains(String(base[..<slash])) else { return base }
        return String(base[base.index(after: slash)...])
    }

    /// The first line of a prompt, trimmed and cut to `limit` characters.
    static func promptLine(_ text: String, limit: Int = 80) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
