import Foundation
import ShepherdProtocol

/// A bounded, read-only probe for `agent_list details`. Returns only state and counts, never names from git.
enum PeerCheckouts {
    struct Observation: Equatable, Sendable {
        var status: PeerCheckoutStatus
        var commitsAheadOfLocalUpstream: Int?

        static let unknown = Self(status: .unknown)
    }

    /// Run off the main actor and server queue. Check a directory only once per batch; don't queue
    /// or cache the observations. A slow checkout must not hold up listing for the tool's full timeout.
    static func read(_ directories: [String]) -> [String: Observation] {
        let clock = ProcessInfo.processInfo
        let deadline = clock.systemUptime + 8
        var statuses: [String: Observation] = [:]
        for directory in directories where statuses[directory] == nil {
            let remaining = deadline - clock.systemUptime
            guard remaining > 0 else { break }
            statuses[directory] = status(in: directory, timeout: min(2, remaining))
        }
        return statuses
    }

    // `status` can call configured clean filters, even without index writes. Allow only Apple's git
    // (including the executable its system shim selects), with no filesystem writes or network.
    // An unsupported tool location or sandbox failure yields unknown, not an unrestricted retry.
    private static let profile = #"""
        (version 1)
        (allow default)
        (deny process-exec (with no-log))
        (allow process-exec (literal "/usr/bin/git") (literal "/Library/Developer/CommandLineTools/usr/bin/git")
                           (regex #"^/Applications/[^/]+/Contents/Developer/usr/bin/git$"))
        (deny file-write* (with no-log))
        (allow file-write-data (literal "/dev/null"))
        (deny network* (with no-log))
        """#

    private static func status(in directory: String, timeout: TimeInterval) -> Observation {
        let cwd = (directory as NSString).expandingTildeInPath
        guard cwd.hasPrefix("/"), !cwd.utf8.contains(0) else { return .unknown }
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("GIT_") || ["GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM"].contains(key)
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ALLOW_PROTOCOL"] = ""
        environment["GIT_NO_LAZY_FETCH"] = "1"
        let argv = ["/usr/bin/sandbox-exec", "-p", profile, "/usr/bin/git", "--no-optional-locks", "-C", cwd,
                    "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "core.splitIndex=false",
                    "status", "--porcelain=v2", "--branch", "--ahead-behind", "-z",
                    "--untracked-files=normal", "--ignore-submodules=none"]
        guard let result = try? BoundedCommand.run(argv, environment: environment, timeout: timeout, outputLimit: 1 << 20),
              result.status == 0, result.errors.isEmpty,
              result.output.starts(with: "# branch.oid ".utf8), result.output.last == 0 else { return .unknown }

        // The same status invocation supplies branch headers before any file records. Never parse
        // later records as headers: the second path of a rename can begin with "# branch.ab ".
        var records = result.output[...]
        var ahead: Int?
        while records.starts(with: "# ".utf8), let end = records.firstIndex(of: 0) {
            let header = records[..<end]
            let prefix = "# branch.ab ".utf8
            if header.starts(with: prefix) {
                // Git emits numeric counts only for a resolved upstream comparison. No header (or
                // unavailable counts) on detached/unborn HEAD or if the upstream can't be resolved.
                let counts = String(decoding: header.dropFirst(prefix.count), as: UTF8.self)
                    .split(separator: " ", omittingEmptySubsequences: false)
                if counts.count == 2, counts[0].first == "+", counts[1].first == "-",
                   let value = Int(counts[0]), value >= 0, let behind = Int(counts[1]), behind <= 0 {
                    ahead = value
                }
            }
            records = records[records.index(after: end)...]
        }
        return Observation(status: records.isEmpty ? .clean : .dirty, commitsAheadOfLocalUpstream: ahead)
    }
}
