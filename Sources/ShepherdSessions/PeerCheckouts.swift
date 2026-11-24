import Foundation
import ShepherdProtocol

/// A bounded, read-only probe for `agent_list details`. Returns only states, never paths from git.
enum PeerCheckouts {
    /// Run off the main actor and server queue. Check a directory only once per batch; don't queue
    /// or cache the observations. A slow checkout must not hold up listing for the tool's full timeout.
    static func read(_ directories: [String]) -> [String: PeerCheckoutStatus] {
        let clock = ProcessInfo.processInfo
        let deadline = clock.systemUptime + 8
        var statuses: [String: PeerCheckoutStatus] = [:]
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

    private static func status(in directory: String, timeout: TimeInterval) -> PeerCheckoutStatus {
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
                    "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignore-submodules=none"]
        guard let result = try? BoundedCommand.run(argv, environment: environment, timeout: timeout, outputLimit: 1 << 20),
              result.status == 0, result.errors.isEmpty else { return .unknown }
        return result.output.isEmpty ? .clean : .dirty
    }
}
