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
    /// A relative path or `~` is resolved; an empty value is ignored. Shepherd
    /// Nightly needs no override: its edition has its own folder.
    public static let supportDirectoryEnvKey = "SHEPHERD_SUPPORT_DIR"

    /// `environment` is the process environment and `edition` the running app's, unless a
    /// caller (a test) passes its own. The override wins over the edition's folder.
    public static func supportDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        edition: ShepherdEdition = .current
    ) -> URL {
        if let override = environment[supportDirectoryEnvKey],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(edition.supportDirectoryName, isDirectory: true)
    }

    public static func socketURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        supportDirectory(environment: environment).appendingPathComponent("shepherd.sock")
    }

    public static func stateURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        supportDirectory(environment: environment).appendingPathComponent("state.json")
    }

    /// Shared secret for remote Shepherd clients (the TCP listener). Created
    /// on first use with 0600 permissions; deleting it revokes every client.
    public static func remoteTokenURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        supportDirectory(environment: environment).appendingPathComponent("remote-token")
    }

    /// Shepherd's root instructions for pi (Settings ▸ Instructions): `AGENTS.md`,
    /// `APPEND_SYSTEM.md` and their history. The instructions extension reads them from here, so
    /// pi's own `~/.pi/agent` is never written.
    public static func instructionsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        supportDirectory(environment: environment).appendingPathComponent("instructions", isDirectory: true)
    }

    /// Overrides where this host's agent skills live (Settings ▸ Skills). Tests point it at a
    /// scratch folder, so they never touch the user's skills; pi itself always reads
    /// `~/.agents/skills`.
    public static let skillsDirectoryEnvKey = "SHEPHERD_SKILLS_DIR"

    /// The agent skills every pi session on this host can use: the Agent Skills folder pi reads
    /// at startup, `~/.agents/skills` (a folder per skill, each with a SKILL.md).
    public static func agentSkillsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment[skillsDirectoryEnvKey],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        return homeDirectory
            .appendingPathComponent(".agents", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// The user's home folder. iOS has no `homeDirectoryForCurrentUser`; its app home stands in.
    private static var homeDirectory: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
        #else
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    /// What Shepherd keeps beside the skills (Settings ▸ Skills): the skills that are off, the
    /// ones just removed (for Undo), each installed skill's source, and a cache of the
    /// repositories they came from.
    public static func skillsStateDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        supportDirectory(environment: environment).appendingPathComponent("skills", isDirectory: true)
    }
}

