import Darwin
import Foundation
import ShepherdProtocol

/// Finding another Mac's Shepherd over the user's own `ssh` (Add a Mac ▸ Connect over SSH), for a network where Bonjour doesn't reach it.
///
/// It runs `ssh` as the user would (`BatchMode=yes`, so nothing prompts; a bounded connect and run; the user's `~/.ssh/config`, keys
/// and agent apply) and asks the other Mac's installed Shepherd where it listens: `shepherd-cli fleet-where` there prints the host's
/// own answer (`FleetWhere`) and writes nothing. SSH only *finds*: nobody is paired by it. The code typed or shown does that, over a
/// direct connection to the address this finds, after the answering Mac's id is checked.
public struct FleetSSHFinder: Sendable {
    /// What the app calls itself on disk: `/Applications/<appName>.app`.
    public var appName: String
    /// The environment `ssh` runs in, whose `PATH` finds it (and whose `SSH_AUTH_SOCK` is the user's agent).
    public var environment: [String: String]
    /// The longest the whole run takes, and ssh's own limit on connecting.
    public var timeout: TimeInterval
    public var connectTimeout: Int

    public init(appName: String = ShepherdEdition.current.displayName, environment: [String: String] = ProcessInfo.processInfo.environment,
                timeout: TimeInterval = 15, connectTimeout: Int = 8) {
        self.appName = appName
        self.environment = environment
        self.timeout = timeout
        self.connectTimeout = connectTimeout
    }

    /// Why a Mac wasn't found, in words for the person. `message` is the sentence the sheet shows.
    public enum Failure: Error, Equatable, Sendable {
        /// What was typed isn't `user@host`.
        case badTarget
        case noSSH
        case timedOut
        /// ssh itself failed (no key, an unknown host key, no route, a refused connection): its own reason, summarized.
        case connection(String)
        /// The Mac has no Shepherd of this edition that answers `fleet-where`: not installed, or too old.
        case notInstalled
        /// Shepherd is installed there but its host isn't running.
        case notRunning
        /// Its host is running but isn't listening, so nothing could reach it.
        case notServing
        /// It answered with something that isn't Shepherd's answer.
        case unreadable

        public var message: String {
            switch self {
            case .badTarget: "Enter it the way you type it after ssh: user@host."
            case .noSSH: "Couldn't find ssh on this Mac."
            case .timedOut: "ssh didn't finish in time. Check that the Mac is on and reachable, then try again."
            case .connection(let reason): reason
            case .notInstalled: "Shepherd isn't installed in Applications on that Mac, or is too old to answer over ssh. Update it, or use a pairing link."
            case .notRunning: "Shepherd isn't running on that Mac. Open it there, then try again."
            case .notServing: "Shepherd is open on that Mac but isn't serving. Turn on Settings ▸ Experiments ▸ Fleet there, then try again."
            case .unreadable: "That Mac answered, but not as Shepherd does. Use a pairing link instead."
            }
        }
    }

    /// `user@host` or a bare host or ssh alias: letters, digits and `._-:%+@`, never a leading dash (an option for ssh) and never a space.
    public static func isTarget(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 253 + 64 + 1, !text.hasPrefix("-"), text.filter({ $0 == "@" }).count <= 1,
              !text.hasPrefix("@"), !text.hasSuffix("@") else { return false }
        return text.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "._-:%+@[]".unicodeScalars.contains($0)) }
    }

    /// The host part of `target`, for adding to the routes the Mac reported: what the person types after ssh reaches it, so it is a way
    /// to it (the Mac checked by id like any other).
    public static func host(of target: String) -> String? {
        let host = target.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? target
        return FleetRouteReport.isHost(host) ? host : nil
    }

    /// The script the other Mac's shell runs: the installed app's own CLI, in Applications or the user's. It prints nothing but the
    /// CLI's answer, or says why on stderr.
    static func remoteCommand(appName: String) -> String {
        let script = """
        for d in "/Applications/\(appName).app" "$HOME/Applications/\(appName).app"; do \
        if [ -x "$d/Contents/MacOS/shepherd-cli" ]; then exec "$d/Contents/MacOS/shepherd-cli" fleet-where; fi; done; \
        echo shepherd-not-installed >&2; exit 127
        """
        return "/bin/sh -c '\(script)'"
    }

    /// The first `ssh` on `PATH`, else the system's.
    func sshExecutable() -> String? {
        let search = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/usr/bin"]
        return search.map { ($0 as NSString).appendingPathComponent("ssh") }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Asks the Mac `target` where its Shepherd listens. Never longer than `timeout`; throws `Failure`.
    public func find(_ target: String) async throws -> FleetWhere {
        let target = target.trimmingCharacters(in: .whitespaces)
        guard Self.isTarget(target) else { throw Failure.badTarget }
        guard let ssh = sshExecutable() else { throw Failure.noSSH }
        let argv = [ssh, "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeout)", "-o", "ClearAllForwardings=yes",
                    "--", target, Self.remoteCommand(appName: appName)]
        let (environment, timeout) = (self.environment, self.timeout)
        let result: BoundedCommand.Result = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try BoundedCommand.run(argv, environment: environment, timeout: timeout, outputLimit: 1 << 20))
                } catch BoundedCommand.Failure.timedOut {
                    continuation.resume(throwing: Failure.timedOut)
                } catch {
                    continuation.resume(throwing: Failure.noSSH)
                }
            }
        }
        return try Self.interpret(status: result.status, output: result.output, errors: String(decoding: result.errors, as: UTF8.self), target: target)
    }

    /// What ssh's exit and output say.
    static func interpret(status: Int32, output: Data, errors: String, target: String) throws -> FleetWhere {
        if status == 0 {
            guard let found = FleetWhere.read(output) else { throw Failure.unreadable }
            return found
        }
        switch status {
        case 127 where errors.contains("shepherd-not-installed"): throw Failure.notInstalled
        case FleetWhereCommand.notRunningStatus: throw Failure.notRunning
        case FleetWhereCommand.notServingStatus: throw Failure.notServing
        // A Shepherd from before `fleet-where` says it doesn't know the argument.
        case 1 where errors.contains("unknown arguments"): throw Failure.notInstalled
        case 255: throw Failure.connection(connectionFailure(errors, target: target))
        default: throw Failure.unreadable
        }
    }

    /// ssh's own complaint, as a sentence a person can act on.
    static func connectionFailure(_ errors: String, target: String) -> String {
        let text = errors.lowercased()
        if text.contains("permission denied") {
            return "ssh was refused. Shepherd never asks for a password, so \(target) needs a key that works without one: check that ssh \(target) works in Terminal."
        }
        if text.contains("host key verification failed") || text.contains("remote host identification has changed") {
            return "ssh doesn't trust that Mac's host key yet. Run ssh \(target) once in Terminal to check it, then try again."
        }
        if text.contains("could not resolve hostname") { return "No Mac is called \(Self.host(of: target) ?? target) on this network." }
        if text.contains("connection refused") { return "That Mac refused the connection. Is Remote Login on? (System Settings ▸ General ▸ Sharing)" }
        if text.contains("timed out") || text.contains("no route to host") || text.contains("network is unreachable") {
            return "Couldn't reach \(Self.host(of: target) ?? target) over ssh. Check that it is on and that you can reach it from here."
        }
        let last = errors.split(whereSeparator: \.isNewline).last.map { String($0.prefix(160)) } ?? ""
        return last.isEmpty ? "ssh couldn't connect." : "ssh couldn't connect: \(last)"
    }
}
