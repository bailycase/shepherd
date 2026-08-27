import Foundation

/// Paths shared by the app, the session server, and the pi status extension.
/// The socket is hosted by the app itself and is same-user, filesystem-confined
/// IPC for pi children. It has no authentication and must not be treated as a
/// boundary against another process running as the same macOS user.
public enum ShepherdPaths {
    /// Overrides the support directory, so a second Shepherd can run with its
    /// own socket, state, and installed extensions.
    ///
    /// Both the socket and state.json live in this directory, and the server
    /// refuses to bind over a live socket — so without an override, a release
    /// build and a development build cannot run at the same time. Set this
    /// when running one alongside the other:
    ///
    ///     SHEPHERD_SUPPORT_DIR=~/Library/Application\ Support/Shepherd-dev
    ///
    /// A relative path or `~` is resolved; an empty value is ignored.
    public static let supportDirectoryEnvKey = "SHEPHERD_SUPPORT_DIR"

    public static func supportDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment[supportDirectoryEnvKey],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shepherd", isDirectory: true)
    }

    public static func socketURL() -> URL {
        supportDirectory().appendingPathComponent("shepherd.sock")
    }

    public static func stateURL() -> URL {
        supportDirectory().appendingPathComponent("state.json")
    }

    /// Shared secret for remote Shepherd clients (the TCP listener). Created
    /// on first use with 0600 permissions; deleting it revokes every client.
    public static func remoteTokenURL() -> URL {
        supportDirectory().appendingPathComponent("remote-token")
    }
}

