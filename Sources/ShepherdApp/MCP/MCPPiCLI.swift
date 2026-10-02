import Foundation
import ShepherdProtocol
import ShepherdSessions

/// What `pi mcp …` printed and how it ended.
struct MCPCLIResult: Equatable, Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut = false
}

/// Runs pi's own `mcp` subcommands in Shepherd's pi home (docs/mcp.md): `list --json` for each
/// server's state and tools, `login` and `logout` for OAuth. Injected, so unit tests don't need pi.
protocol MCPCLI: Sendable {
    /// `onLine` hears each line of stdout as it comes. Cancelling the task ends the process.
    func run(_ arguments: [String], environment: [String: String], timeout: TimeInterval,
             onLine: (@Sendable (String) -> Void)?) async -> MCPCLIResult
}

/// The real runner: the launcher in pi's home, from a login shell (`PiLaunch.mcp`), with the
/// environment the agents' pi would have for these servers.
struct PiMCPCLI: MCPCLI {
    var home: PiHome

    func run(_ arguments: [String], environment: [String: String], timeout: TimeInterval,
             onLine: (@Sendable (String) -> Void)?) async -> MCPCLIResult {
        let line = PiLaunch.mcp(home: home, arguments: arguments)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: line.argv[0])
        process.arguments = Array(line.argv.dropFirst())
        var env = ProcessInfo.processInfo.environment
        // Nothing of an agent's: the Shepherd that spawned this one may itself have been started in a thread.
        for key in env.keys where key.hasPrefix("SHEPHERD_") && key != "SHEPHERD_SUPPORT_DIR" { env[key] = nil }
        process.environment = env.merging(environment) { _, new in new }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let collected = Collected()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            for completed in collected.addOutput(chunk) { onLine?(completed) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { collected.addError(chunk) }
        }
        let exited = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { exited.continuation.yield($0.terminationStatus); exited.continuation.finish() }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return MCPCLIResult(status: 127, stdout: "", stderr: "Couldn’t run pi: \(error.localizedDescription)")
        }
        try? stdin.fileHandleForWriting.close()
        let timer = Task { [weak process] in
            try await Task.sleep(for: .seconds(timeout))
            collected.markTimedOut()
            process?.terminate()
            try await Task.sleep(for: .seconds(2))
            if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let status = await withTaskCancellationHandler {
            for await status in exited.stream { return status }
            return 1
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        timer.cancel()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        let rest = stdout.fileHandleForReading.readDataToEndOfFile()
        if !rest.isEmpty { for completed in collected.addOutput(rest) { onLine?(completed) } }
        if let last = collected.finishOutput() { onLine?(last) }
        collected.addError(stderr.fileHandleForReading.readDataToEndOfFile())
        return collected.result(status: status)
    }

    /// The output so far, shared with the pipes' handlers.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var output = Data()
        private var pending = Data()
        private var errors = Data()
        private var timedOut = false

        /// Adds a chunk and returns the lines it completed.
        func addOutput(_ chunk: Data) -> [String] {
            lock.withLock {
                output.append(chunk)
                pending.append(chunk)
                var lines: [String] = []
                while let newline = pending.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending = Data(pending[pending.index(after: newline)...])
                }
                return lines
            }
        }

        /// What stayed after the last newline.
        func finishOutput() -> String? {
            lock.withLock {
                defer { pending = Data() }
                return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
            }
        }

        func addError(_ chunk: Data) {
            lock.withLock {
                errors.append(chunk)
                if errors.count > 16_384 { errors = Data(errors.suffix(8192)) }
            }
        }

        func markTimedOut() { lock.withLock { timedOut = true } }

        func result(status: Int32) -> MCPCLIResult {
            lock.withLock {
                MCPCLIResult(status: status, stdout: String(decoding: output, as: UTF8.self),
                             stderr: String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                             timedOut: timedOut)
            }
        }
    }
}

// MARK: pi mcp list --json

/// `pi mcp list --json`: each server's state, as the page shows it.
struct MCPPiReport: Equatable, Sendable {
    struct Server: Equatable, Sendable {
        var name: String
        var enabled: Bool
        /// pi's words: `connected`, `needs-auth`, `failed`, `disabled`, `disconnected`, `idle`, `connecting`.
        var state: String
        var tools: [String]
        var error: String?
    }

    var servers: [Server]
    /// What pi found wrong in the file: `<path>: server "x": …`.
    var errors: [String]

    func server(_ name: String) -> Server? { servers.first { $0.name == name } }

    /// Read defensively: pi's output is not Shepherd's contract (docs/mcp.md). Nil when it isn't the JSON object.
    static func parse(_ text: String) -> MCPPiReport? {
        guard let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let servers = (root["servers"] as? [[String: Any]] ?? []).compactMap { item -> Server? in
            guard let name = item["name"] as? String else { return nil }
            return Server(name: name, enabled: item["enabled"] as? Bool ?? true, state: item["state"] as? String ?? "failed",
                          tools: (item["tools"] as? [Any])?.compactMap { $0 as? String } ?? [],
                          error: (item["error"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        return MCPPiReport(servers: servers, errors: (root["errors"] as? [Any] ?? []).compactMap { $0 as? String })
    }

    /// The server a config error names, with the message after its name.
    var configProblems: [String: String] {
        var out: [String: String] = [:]
        for error in errors {
            guard let open = error.range(of: "server \""), let close = error[open.upperBound...].firstIndex(of: "\"") else { continue }
            let name = String(error[open.upperBound..<close])
            let message = error[error.index(after: close)...].drop { $0 == ":" || $0 == " " }
            out[name] = String(message)
        }
        return out
    }
}

// MARK: pi's sign-ins

/// Whether pi holds sign-in credentials for a server: `<home>/mcp-auth.json`, keyed
/// `mcp__<name>|<url>` (pi's format, read defensively and never written).
enum MCPPiAuth {
    static func hasCredentials(server: String, url: String, in data: Data?) -> Bool {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let key = "mcp__" + server.replacingOccurrences(of: "-", with: "_") + "|" + url
        return root[key] != nil
    }
}
