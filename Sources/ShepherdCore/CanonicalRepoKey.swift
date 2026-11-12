import Foundation

/// A repository named the same way on every Mac: `host/owner/repo`, from a git remote's URL in any
/// of its spellings. `git@github.com:Acme/web.git`, `ssh://git@github.com/acme/web` and
/// `https://user:token@github.com/acme/web.git/` are one repo ("github.com/acme/web"); a fork has
/// another owner, so it is another repo.
///
/// The scheme, user, password and port are dropped (a port belongs to the transport, not the repo),
/// the host is lowercased, a trailing `/` and `.git` go, and on the well known forges the owner and
/// repo are lowercased too, because those treat them case-insensitively. On any other host the path
/// keeps its case. A local path or a URL with no owner and repo has no key.
public struct CanonicalRepoKey: Hashable, Sendable, CustomStringConvertible {
    public let value: String

    /// Hosts that fold the case of owner and repo, and the names that reach them.
    private static let forges: [String: String] = [
        "github.com": "github.com", "ssh.github.com": "github.com", "www.github.com": "github.com",
        "gitlab.com": "gitlab.com", "bitbucket.org": "bitbucket.org", "codeberg.org": "codeberg.org",
    ]

    public init?(remote: String) {
        let text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var host: String
        var path: String
        if let scheme = text.range(of: "://") {
            guard text[..<scheme.lowerBound].lowercased() != "file" else { return nil }
            let rest = text[scheme.upperBound...]
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            host = Self.hostOnly(String(rest[..<slash]))
            path = String(rest[slash...])
        } else if !text.hasPrefix("/"), !text.hasPrefix("."), !text.hasPrefix("~"), let colon = text.firstIndex(of: ":"),
                  !text[..<colon].contains("/") {
            // scp-like: [user@]host:path
            host = Self.hostOnly(String(text[..<colon]))
            path = "/" + text[text.index(after: colon)...]
        } else {
            return nil
        }
        guard !host.isEmpty, !host.contains(" ") else { return nil }
        host = host.lowercased()
        var segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard var last = segments.popLast() else { return nil }
        while last.hasSuffix(".git"), last.count > 4 { last = String(last.dropLast(4)) }
        segments.append(last)
        guard segments.count >= 2, !segments.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) else { return nil }
        if let forge = Self.forges[host] {
            host = forge
            segments = segments.map { $0.lowercased() }
        }
        value = ([host] + segments).joined(separator: "/")
    }

    /// `user:password@host:port` is `host`.
    private static func hostOnly(_ authority: String) -> String {
        var host = Substring(authority)
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        if host.hasPrefix("[") { return String(host) }
        if let colon = host.firstIndex(of: ":") { host = host[..<colon] }
        return String(host)
    }

    public var description: String { value }

    /// A repository with no origin, named by its first commit: `local/<12 hex digits>`. It is the same on every Mac that holds a clone of
    /// the repository, and it is only ever used to match a dispatch's repository (never stored as a space's `repoKey` by the host's
    /// own refresh): a thread can send work from a repository that has no remote, whose other Macs are then sent the repository itself.
    public static let localPrefix = "local/"

    public static func local(rootCommit: String) -> String? {
        let digits = rootCommit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard digits.count >= 12, digits.allSatisfy(\.isHexDigit) else { return nil }
        return localPrefix + digits.prefix(12)
    }

    public static func isLocal(_ key: String) -> Bool { key.hasPrefix(localPrefix) }
}
