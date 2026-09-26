import Foundation

/// Which pi Shepherd runs and where that pi keeps its state, resolved once where the app starts
/// and passed in from there: the server holds it, and everything that launches pi, reads its
/// config or touches its sessions takes it (or a part of it) from the server. Code under test
/// never reads these from the process environment itself.
///
/// Today the home and "your pi" are one folder, the user's pi home, found the way pi finds it;
/// a later change gives Shepherd its own home and keeps "your pi" for one-way imports.
public struct PiSetup: Sendable {
    /// What starts pi (`PiLaunch` builds the lines).
    public let engine: PiEngine
    /// The pi agent directory Shepherd's agents run in: config, sessions, catalog.
    public let home: URL
    /// The folder the user's own terminal pi uses.
    public let yourPi: URL
    /// The model catalog, asked of `engine` against `home`, kept for this setup's lifetime.
    public let catalog: PiModelCatalog

    public init(engine: PiEngine, home: URL, yourPi: URL? = nil) {
        self.engine = engine
        self.home = home.standardizedFileURL
        self.yourPi = (yourPi ?? home).standardizedFileURL
        catalog = PiModelCatalog(engine: engine, home: self.home)
    }

    /// Where pi keeps its session files: `<home>/sessions`.
    public var sessionsRoot: URL { home.appendingPathComponent("sessions", isDirectory: true) }

    /// The setup for an environment: the engine `PiEngine.locate` finds, and pi's own agent
    /// directory (`PI_CODING_AGENT_DIR`, else `~/.pi/agent`) as both the home and "your pi".
    public static func resolve(environment: [String: String]) -> PiSetup {
        PiSetup(engine: PiEngine.locate(environment: environment), home: PiConfig.agentDirectory(environment: environment))
    }

    /// The app's: resolved from the process environment the first time it is asked for. In a
    /// test process that environment is the scratch one `ShepherdTestIsolation` set as it loaded.
    public static let app = resolve(environment: ProcessInfo.processInfo.environment)
}
