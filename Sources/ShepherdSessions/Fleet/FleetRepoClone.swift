import Foundation
import ShepherdCore

/// One `git clone` onto this Mac for a dispatch (slice 4f): from the repository's origin with this Mac's own git sign-in (it never
/// prompts), or from a bundle the sending Mac made. It makes a checkout only at a folder it created itself a moment before, so it
/// can't write into an existing one, and git's own progress lines become `Update`s. Blocking: call it off the server queue.
final class FleetRepoClone: @unchecked Sendable {
    enum Outcome: Equatable {
        case done
        case cancelled
        /// git's own words for why it failed.
        case failed(String)
    }

    /// What git says it is doing: "receiving objects" and how far through it is.
    struct Update: Equatable, Sendable {
        var phase: String
        var fraction: Double?
    }

    /// The git to run. Tests point it at a wrapper that is slow, to stop a clone partway.
    nonisolated(unsafe) static var git = "/usr/bin/git"

    let source: String
    let destination: String
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    init(source: String, destination: String) {
        self.source = source
        self.destination = destination
    }

    /// Stops the clone. Safe at any time, from any thread; `run` then answers `.cancelled`.
    func cancel() {
        lock.withLock {
            stopped = true
            process?.terminate()
        }
    }

    private static let phases: Set<String> = ["enumerating objects", "counting objects", "compressing objects", "receiving objects", "resolving deltas",
                                              "updating files", "checking out files", "checking connectivity"]

    /// "Receiving objects:  37% (1234/3333), 2.5 MiB | 5 MiB/s" is `receiving objects`, 0.37. A line that isn't progress is nil.
    static func parse(_ line: String) -> Update? {
        var text = Substring(line.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.hasPrefix("remote:") { text = text.dropFirst("remote:".count).drop { $0 == " " } }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let phase = text[..<colon].lowercased()
        guard phases.contains(phase) else { return nil }
        let after = text[text.index(after: colon)...].drop { $0 == " " }
        let digits = after.prefix { $0.isNumber }
        guard !digits.isEmpty, after.dropFirst(digits.count).first == "%", let percent = Double(digits) else { return Update(phase: phase, fraction: nil) }
        return Update(phase: phase, fraction: min(1, max(0, percent / 100)))
    }

    /// Runs `git clone` into `destination`, which must be an empty folder this process made. `progress` hears each line git writes
    /// that says how far it is.
    func run(timeout: TimeInterval = 7_200, progress: @escaping @Sendable (Update) -> Void) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.git)
        process.arguments = ["clone", "--progress", "--", source, destination]
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // ssh would ask for a password on a terminal that isn't there; this makes it fail instead.
        if environment["GIT_SSH_COMMAND"] == nil, environment["GIT_SSH"] == nil { environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        let tail = Tail()
        let reader = errors.fileHandleForReading
        let drained = DispatchSemaphore(value: 0)
        // One reader: stderr's `\r` separated progress lines and its `\n` ended messages.
        DispatchQueue.global(qos: .utility).async {
            var pending = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let end = pending.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) {
                    let line = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...end)
                    if let update = Self.parse(line) { progress(update) } else { tail.add(line) }
                }
            }
            if !pending.isEmpty { tail.add(String(decoding: pending, as: UTF8.self)) }
            drained.signal()
        }

        let started: Bool = lock.withLock {
            if stopped { return false }
            do { try process.run() } catch { tail.add("couldn't run git: \(error.localizedDescription)"); return false }
            self.process = process
            return true
        }
        // This side's copy of the write end closes either way, so the reader sees the end of git's output.
        try? errors.fileHandleForWriting.close()
        guard started else {
            drained.wait()
            return lock.withLock { stopped } ? .cancelled : .failed(tail.text)
        }
        let finished = done.wait(timeout: .now() + timeout) == .success
        if !finished {
            process.terminate()
            _ = done.wait(timeout: .now() + 10)
        }
        drained.wait()
        let wasStopped = lock.withLock { process.terminationStatus != 0 && stopped }
        if wasStopped { return .cancelled }
        if !finished { return .failed("timed out after \(Int(timeout)) seconds") }
        return process.terminationStatus == 0 ? .done : .failed(tail.text)
    }

    /// The last few lines git wrote that weren't progress: its error.
    private final class Tail: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            lock.withLock { lines.append(text); if lines.count > 6 { lines.removeFirst() } }
        }
        var text: String {
            let kept = lock.withLock { lines }.filter { !$0.hasPrefix("Cloning into") }
            let wanted = kept.filter { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") || $0.hasPrefix("ssh:") }
            return String((wanted.isEmpty ? kept : wanted).suffix(3).joined(separator: " ").prefix(400))
        }
    }

    // MARK: Where it goes

    /// A folder name from a repository's key: "acme-web" from "github.com/acme/acme-web". A repository with no origin has only a first
    /// commit for a key, so the sender's name for it stands in.
    static func folderName(repoKey: String, name: String? = nil) -> String {
        let last = CanonicalRepoKey.isLocal(repoKey) ? (name?.fleetNonEmpty ?? "repo") : repoKey.split(separator: "/").last.map(String.init) ?? repoKey
        let kept = String(last.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar)) || "-_.".unicodeScalars.contains(scalar)) ? Character(scalar) : "-"
        }).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return kept.isEmpty ? "repo" : kept
    }

    /// Makes (and so owns) the empty folder a clone goes into, and returns it: `<developer>/<name>` when the developer folder is
    /// there and that path doesn't exist, otherwise `<repos>/<slug of the key>`, with the dispatch's first characters added when even
    /// that exists. A folder that exists is never used, whatever it holds. Nil when none could be made.
    static func claim(repoKey: String, name given: String? = nil, dispatchID: UUID, developer: URL?, repos: URL) -> URL? {
        let manager = FileManager.default
        let name = folderName(repoKey: repoKey, name: given)
        let slug = CanonicalRepoKey.isLocal(repoKey) ? "local-" + name : repoKey.split(separator: "/").map(String.init).joined(separator: "-")
        let suffix = String(dispatchID.uuidString.lowercased().prefix(6))
        var isDirectory: ObjCBool = false
        var options: [URL] = []
        if let developer, manager.fileExists(atPath: developer.path, isDirectory: &isDirectory), isDirectory.boolValue {
            options.append(developer.appendingPathComponent(name, isDirectory: true))
        }
        options += [repos.appendingPathComponent(slug, isDirectory: true), repos.appendingPathComponent("\(slug)-\(suffix)", isDirectory: true)]
        try? manager.createDirectory(at: repos, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for option in options {
            // Not recursive: it fails when the path is there, which is the point.
            if (try? manager.createDirectory(at: option, withIntermediateDirectories: false)) != nil { return option }
        }
        return nil
    }

    /// Brings the commits a bundle holds into `repo`, under `refs/fleet/<id>/` (its branches and HEAD), so a worktree can start at one of them.
    /// False when the bundle can't be used (it lacks a commit the repository doesn't have either).
    @discardableResult
    static func fetchBundle(_ path: String, into repo: String, id: UUID) -> Bool {
        let prefix = "refs/fleet/\(id.uuidString.lowercased())"
        let heads = FleetDispatchGit.run(["fetch", "--quiet", path, "+refs/heads/*:\(prefix)/heads/*"], in: repo, timeout: 300)
        let head = FleetDispatchGit.run(["fetch", "--quiet", path, "+HEAD:\(prefix)/HEAD"], in: repo, timeout: 300)
        return heads?.status == 0 || head?.status == 0
    }

    /// Removes what `fetchBundle` made: the commits stay for as long as the worktree's branch holds them.
    static func dropBundleRefs(from repo: String, id: UUID) {
        let prefix = "refs/fleet/\(id.uuidString.lowercased())/"
        guard let listed = FleetDispatchGit.run(["for-each-ref", "--format=%(refname)", prefix], in: repo), listed.status == 0 else { return }
        for ref in listed.output.split(separator: "\n") { _ = FleetDispatchGit.run(["update-ref", "-d", String(ref)], in: repo) }
    }

    /// Points a clone's `origin` where the repository really is. A clone from a bundle names the bundle file as its origin, which goes.
    static func fixOrigin(at folder: String, to origin: String?) {
        if let origin { _ = FleetDispatchGit.run(["remote", "set-url", "origin", origin], in: folder) }
        else { _ = FleetDispatchGit.run(["remote", "remove", "origin"], in: folder) }
    }
}
