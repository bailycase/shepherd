import Foundation
import ShepherdCore

// Settings › Apps' apps, in `~/.shepherd/apps.json` and a space's `.shepherd/apps.json`
// (`AppsFile`), and their runs on a host (`RemoteRequest.apps`, `RemoteProtocol.appsCapability`).

/// One app: what it runs, where, and where its output and page go.
public struct AppDefinition: Codable, Hashable, Sendable, Identifiable {
    public enum Opens: String, Codable, Sendable, CaseIterable {
        /// Runs in a terminal tab, then opens `address` in the thread's Browser once it answers.
        case browser
        /// Runs in a terminal tab.
        case terminal
        /// Runs in a terminal tab and opens its own window (the Simulator, an Electron app).
        case window
    }

    /// Unique in its file: it names the app's terminal tab.
    public var name: String
    public var command: String
    /// A space's app: relative to the space's folder ("" is the folder itself). This Mac's: a
    /// path, `~` for the home folder.
    public var folder: String
    public var opens: Opens
    /// The page a browser app serves ("http://localhost:3000").
    public var address: String?
    /// A Run button in the thread header and on New thread while you are in its space.
    public var quickAction: Bool
    /// Agents can start and stop it (`app_run`, `app_stop`); a This Mac app is listed to agents
    /// only with it. Off unless the person turns it on.
    public var agents: Bool

    public var id: String { name }

    public init(name: String, command: String, folder: String = "", opens: Opens = .terminal, address: String? = nil,
                quickAction: Bool = false, agents: Bool = false) {
        self.name = name
        self.command = command
        self.folder = folder
        self.opens = opens
        self.address = address
        self.quickAction = quickAction
        self.agents = agents
    }

    private enum CodingKeys: String, CodingKey { case name, command, folder, opens, address, quickAction, agents }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        // An opening this Shepherd doesn't know runs in a terminal.
        opens = (try? c.decodeIfPresent(Opens.self, forKey: .opens)) ?? .terminal
        address = try c.decodeIfPresent(String.self, forKey: .address)
        quickAction = try c.decodeIfPresent(Bool.self, forKey: .quickAction) ?? false
        agents = try c.decodeIfPresent(Bool.self, forKey: .agents) ?? false
    }

    /// The page to open: the address when it is http(s) on any host.
    public var url: URL? {
        guard opens == .browser, let address, let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    /// The folder the command runs in: a space's app under `root` (the thread's folder, so a
    /// worktree thread runs its own copy); this Mac's from `home`.
    public func directory(root: String?, home: String) -> String {
        let folder = folder.trimmingCharacters(in: .whitespaces)
        guard let root else {
            if folder.isEmpty || folder == "~" { return home }
            return folder.hasPrefix("~/") ? home + folder.dropFirst() : folder
        }
        guard !folder.isEmpty, folder != "." else { return root }
        return URL(fileURLWithPath: root).appendingPathComponent(folder).standardizedFileURL.path
    }
}

/// A space's apps on a host, as its thread header lists them (`RemoteRequest.apps`). Every
/// request is answered with the space's apps as they are afterwards.
public enum RemoteAppsRequest: Codable, Hashable, Sendable {
    /// The apps a thread in the space can run: the space's own, then the host's for every space.
    case list(spaceID: SpaceID)
    /// Runs one (`mac`: one saved for every space), unless it is running. A space's app runs in
    /// `agentID`'s folder when given (a worktree thread runs its own copy), else the space's.
    case run(spaceID: SpaceID, name: String, mac: Bool, agentID: AgentID?)
    /// SIGTERM to its process group, SIGKILL after a grace period.
    case stop(spaceID: SpaceID, name: String, mac: Bool)
}

extension RemoteAppsRequest {
    public var spaceID: SpaceID {
        switch self {
        case .list(let id), .run(let id, _, _, _), .stop(let id, _, _): id
        }
    }
}

/// One app and what it is doing on the host.
public struct RemoteApp: Codable, Hashable, Sendable, Identifiable {
    public var app: AppDefinition
    /// Saved for every space on the host, not in this space.
    public var mac: Bool
    /// Its run since the host started; nil before it first runs.
    public var run: RemoteAppRun?

    public var id: String { (mac ? "mac/" : "space/") + app.name }

    public init(app: AppDefinition, mac: Bool, run: RemoteAppRun? = nil) {
        self.app = app
        self.mac = mac
        self.run = run
    }
}

/// An app's run on the host.
public struct RemoteAppRun: Codable, Hashable, Sendable {
    public enum Status: Codable, Hashable, Sendable {
        case starting
        case running
        /// Its exit code, 128 + the signal for a signal.
        case exited(code: Int32)
        /// It couldn't start, and why.
        case failed(String)
    }

    public var status: Status
    /// The port it serves on, once known.
    public var port: Int?
    /// Stop was asked for and it hasn't ended yet.
    public var stopping: Bool

    public var isLive: Bool { status == .starting || status == .running }

    public init(status: Status, port: Int? = nil, stopping: Bool = false) {
        self.status = status
        self.port = port
        self.stopping = stopping
    }
}

public struct RemoteAppsResult: Codable, Hashable, Sendable {
    /// The space's name.
    public var space: String
    public var apps: [RemoteApp]

    public init(space: String, apps: [RemoteApp]) {
        self.space = space
        self.apps = apps
    }
}
