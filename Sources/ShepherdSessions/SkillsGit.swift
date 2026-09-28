import Foundation

/// The git a host's skills are fetched with (Settings ▸ Skills): a partial clone per repository
/// (commits and trees, no file contents until a skill needs them) in Shepherd's support directory,
/// read without ever checking anything out. Every call blocks, so the store runs it off the
/// server's queue.
struct SkillsGit {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// One entry of `git ls-tree -r`: a file's mode, object and path.
    struct Entry: Equatable {
        var mode: String
        var type: String
        var object: String
        var path: String

        var isFile: Bool { type == "blob" && (mode == "100644" || mode == "100755") }
        var isExecutable: Bool { mode == "100755" }
    }

    /// The repository's cache.
    let directory: URL
    let cloneURL: String

    static let executable = URL(fileURLWithPath: "/usr/bin/git")
    /// A clone or fetch that takes longer than this has stalled.
    static let networkTimeout: TimeInterval = 150

    // MARK: Fetching

    /// Clones the repository into the cache, or brings the cache up to date, then answers its
    /// default branch and that branch's newest commit.
    func refresh() throws -> (branch: String, commit: String) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            try run(["fetch", "--quiet", "--prune", "--no-tags", "origin"], timeout: Self.networkTimeout)
            // The default branch may have moved; a failure leaves the one it had.
            _ = try? run(["remote", "set-head", "origin", "--auto"], timeout: Self.networkTimeout)
        } else {
            try fileManager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.removeItem(at: directory)
            do {
                try Self.run(["clone", "--quiet", "--no-checkout", "--no-tags", "--filter=blob:none", cloneURL, directory.path],
                             in: nil, timeout: Self.networkTimeout)
            } catch {
                try? fileManager.removeItem(at: directory)
                throw error
            }
        }
        let branch = try defaultBranch()
        return (branch, try resolve("refs/remotes/origin/\(branch)"))
    }

    /// The full commit a name or abbreviation stands for, fetching once if the cache hasn't
    /// seen it.
    func commit(_ name: String) throws -> String {
        if let commit = try? resolve(name) { return commit }
        try run(["fetch", "--quiet", "--no-tags", "origin"], timeout: Self.networkTimeout)
        return try resolve(name)
    }

    // MARK: Reading

    /// Every file and link in the commit, or only those under `path` ("" for all).
    func tree(_ commit: String, under path: String = "") throws -> [Entry] {
        var arguments = ["ls-tree", "-r", "-z", "--full-tree", commit]
        if !path.isEmpty { arguments += ["--", path] }
        let output = try run(arguments)
        return output.split(separator: 0).compactMap { record in
            guard let line = String(data: Data(record), encoding: .utf8), let tab = line.firstIndex(of: "\t") else { return nil }
            let fields = line[..<tab].split(separator: " ").map(String.init)
            guard fields.count == 3 else { return nil }
            return Entry(mode: fields[0], type: fields[1], object: fields[2], path: String(line[line.index(after: tab)...]))
        }
    }

    /// The contents of each object, in order (nil for one git doesn't have). A partial clone
    /// fetches the missing ones in a single round trip first.
    func contents(_ objects: [String]) throws -> [Data?] {
        guard !objects.isEmpty else { return [] }
        prefetch(objects)
        let output = try run(["cat-file", "--batch"], input: Data((objects.joined(separator: "\n") + "\n").utf8))
        var results: [Data?] = []
        var index = output.startIndex
        while index < output.endIndex, results.count < objects.count {
            guard let newline = output[index...].firstIndex(of: 0x0A) else { break }
            let header = String(decoding: output[index..<newline], as: UTF8.self).split(separator: " ")
            index = output.index(after: newline)
            guard header.count == 3, let size = Int(header[2]),
                  let end = output.index(index, offsetBy: size, limitedBy: output.endIndex) else {
                results.append(nil)
                continue
            }
            results.append(Data(output[index..<end]))
            index = end < output.endIndex ? output.index(after: end) : end
        }
        while results.count < objects.count { results.append(nil) }
        return results
    }

    /// The newest commit at or before `commit` that changed `path`, and when it was made.
    func lastChange(of path: String, at commit: String) throws -> (commit: String, date: Double?) {
        var arguments = ["log", "-1", "--format=%H%x09%ct", commit]
        if !path.isEmpty { arguments += ["--", path] }
        let line = String(decoding: try run(arguments), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = line.split(separator: "\t").map(String.init)
        guard let found = fields.first, !found.isEmpty else { return (commit, nil) }
        return (found, fields.count > 1 ? Double(fields[1]) : nil)
    }

    /// How many files under `path` differ between two commits.
    func changedFiles(under path: String, from old: String, to new: String) throws -> Int {
        var arguments = ["diff", "--no-renames", "--name-only", "-z", old, new]
        if !path.isEmpty { arguments += ["--", path] }
        return try run(arguments).split(separator: 0).count
    }

    // MARK: Private

    private func defaultBranch() throws -> String {
        if let head = try? run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]) {
            let name = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("origin/"), name.count > "origin/".count { return String(name.dropFirst("origin/".count)) }
        }
        for candidate in ["main", "master"] where (try? resolve("refs/remotes/origin/\(candidate)")) != nil {
            return candidate
        }
        throw Failure(message: "The repository has no default branch.")
    }

    private func resolve(_ name: String) throws -> String {
        let output = try run(["rev-parse", "--verify", "--quiet", "\(name)^{commit}"])
        let commit = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commit.isEmpty else { throw Failure(message: "No commit \(name) in the repository.") }
        return commit
    }

    /// Asks the remote for the objects a partial clone lacks, all at once, as git itself does
    /// before a checkout. Best effort: a failure leaves `cat-file` to fetch each one it needs.
    private func prefetch(_ objects: [String]) {
        guard let promisor = try? run(["config", "--get", "remote.origin.promisor"]),
              String(decoding: promisor, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return }
        _ = try? run(["-c", "fetch.negotiationAlgorithm=noop", "fetch", "--quiet", "--no-tags", "--no-write-fetch-head",
                      "--recurse-submodules=no", "--filter=blob:none", "--stdin", "origin"],
                     input: Data((objects.joined(separator: "\n") + "\n").utf8), timeout: Self.networkTimeout)
    }

    @discardableResult
    private func run(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 60) throws -> Data {
        try Self.run(["-C", directory.path] + arguments, in: nil, input: input, timeout: timeout)
    }

    /// Runs git and answers its output; a non-zero exit throws its last line of stderr. It never
    /// asks for credentials: a repository that needs them and has none fails.
    @discardableResult
    static func run(_ arguments: [String], in directory: URL?, input: Data? = nil, timeout: TimeInterval = 60) throws -> Data {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GCM_INTERACTIVE"] = "never"
        environment["GIT_ASKPASS"] = "/usr/bin/true"
        environment["SSH_ASKPASS"] = "/usr/bin/true"
        environment["GIT_SSH_COMMAND"] = environment["GIT_SSH_COMMAND"] ?? "ssh -o BatchMode=yes"
        let result: BoundedCommand.Result
        do {
            result = try BoundedCommand.run([executable.path] + arguments, directory: directory,
                                            environment: environment, input: input, timeout: timeout)
        } catch BoundedCommand.Failure.timedOut {
            throw Failure(message: "git took too long and was stopped.")
        } catch {
            throw Failure(message: "Couldn't run git: \(error)")
        }
        guard result.status == 0 else {
            let message = String(decoding: result.errors, as: UTF8.self)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty && !$0.hasPrefix("hint:") } ?? "git exited with status \(result.status)."
            throw Failure(message: message.hasPrefix("fatal: ") ? String(message.dropFirst("fatal: ".count)) : message)
        }
        return result.output
    }
}
