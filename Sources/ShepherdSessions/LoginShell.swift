import Foundation

/// Async login-shell runner for commits from review, branch actions and missions. `zsh -l`
/// resolves the user's PATH (gh, brew-installed git) exactly like Shepherd's pi launch path.
/// Prompting is disabled so a missing credential fails fast instead of hanging a non-TTY child.
public enum LoginShell {
    public struct Output: Equatable, Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String

        public init(status: Int32, stdout: String, stderr: String) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    private final class CompletionState: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return false }
            finished = true
            return true
        }
    }

    private final class CapturedData: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()

        func set(stdout: Data) {
            lock.lock()
            self.stdout = stdout
            lock.unlock()
        }

        func set(stderr: Data) {
            lock.lock()
            self.stderr = stderr
            lock.unlock()
        }

        func output(status: Int32) -> Output {
            lock.lock()
            defer { lock.unlock() }
            return Output(
                status: status,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self)
            )
        }
    }

    public static func run(
        _ script: String,
        cwd: String? = nil,
        timeout: TimeInterval? = nil
    ) async -> Output {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // Startup files can cd elsewhere; reselect the requested checkout before any command.
            let directory = cwd.map { "cd -- \(shellQuoted($0)) || exit\n" } ?? ""
            process.arguments = ["-l", "-c", directory + script]
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            env["GH_PROMPT_DISABLED"] = "1"
            process.environment = env
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let state = CompletionState()
            let captured = CapturedData()
            let reads = DispatchGroup()

            @Sendable func finish(_ output: Output) {
                guard state.claim() else { return }
                continuation.resume(returning: output)
            }

            // Register before launch so a fast exit cannot race completion setup.
            reads.enter()
            reads.enter()
            process.terminationHandler = { process in
                reads.notify(queue: .global(qos: .userInitiated)) {
                    finish(captured.output(status: process.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                finish(Output(status: 127, stdout: "", stderr: error.localizedDescription))
                return
            }

            DispatchQueue.global().async {
                captured.set(stdout: out.fileHandleForReading.readDataToEndOfFile())
                reads.leave()
            }
            DispatchQueue.global().async {
                captured.set(stderr: err.fileHandleForReading.readDataToEndOfFile())
                reads.leave()
            }

            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard state.claim() else { return }
                    process.terminate()
                    continuation.resume(returning: Output(status: 124, stdout: "", stderr: "timed out"))
                }
            }
        }
    }
}

/// Single-quote a string for safe interpolation into a zsh script.
public func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

extension LoginShell {
    /// git's closing advice after a failed remote operation; it never names the problem.
    static let gitRemoteBoilerplate: Set<String> = [
        "fatal: Could not read from remote repository.",
        "Please make sure you have the correct access rights",
        "and the repository exists.",
    ]

    /// A failed step's text: stderr, else stdout, else the exit status. A sheet shows only the
    /// first line (the rest is its tooltip), so the line that names the problem moves to the
    /// front: a rejected ref, else the first `fatal:`/`error:` that isn't git's closing
    /// boilerplate, ahead of the `To <remote>` header and hints.
    public static func failureDetail(_ output: Output) -> String {
        let err = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = err.isEmpty ? out : err
        guard !text.isEmpty else { return "exit \(output.status)" }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let candidates = lines.indices.filter { !gitRemoteBoilerplate.contains(lines[$0]) }
        let telling = candidates.first { lines[$0].hasPrefix("! [") }
            ?? candidates.first { index in ["fatal:", "error:"].contains { lines[index].lowercased().hasPrefix($0) } }
        var reordered = lines
        if let telling, telling > 0 { reordered.insert(reordered.remove(at: telling), at: 0) }
        // git pads its ref columns ("! [rejected]        a -> a"); the one-line summary doesn't.
        reordered[0] = reordered[0].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return reordered.joined(separator: "\n")
    }

    /// `pi --print` with the prompt alone, on the text generation model: no session, tools,
    /// extensions or context files. Commit messages from review are drafted this way.
    public static func draftCommand(prompt: String, model: String, home: PiHome) -> String {
        PiLaunch.draft(home: home, model: draftModel(model, environment: ProcessInfo.processInfo.environment), prompt: prompt).script
    }

    /// The one model a draft runs on: the text generation model from Settings, else the first of
    /// `SHEPHERD_TEXT_GENERATION_MODELS` (the namer's list), else Haiku. A draft is one `pi --print`
    /// call, so unlike the namer it cannot walk a list or fall back to a thread's own model.
    static func draftModel(_ configured: String, environment: [String: String]) -> String {
        let picked = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !picked.isEmpty { return picked }
        if let first = environment["SHEPHERD_TEXT_GENERATION_MODELS"]?.split(separator: ",").first {
            let fromEnvironment = String(first).trimmingCharacters(in: .whitespaces)
            if !fromEnvironment.isEmpty { return fromEnvironment }
        }
        return "anthropic/claude-haiku-4-5"
    }
}
