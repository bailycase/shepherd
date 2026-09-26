import Foundation
import ShepherdProtocol
import ShepherdRemote

/// Which pi Shepherd runs, the home it runs it in, and where the user's own pi is, resolved once
/// where the app starts and passed in from there: the server holds it, and everything that
/// launches pi, reads its config or touches its sessions takes it (or a part of it) from the
/// server. Code under test never reads these from the process environment itself.
///
/// The home is always `<support directory>/pi`, never the app's own `PI_CODING_AGENT_DIR` (which
/// a Shepherd started from an agent's shell inherits). "Your pi" is only ever read.
public struct PiSetup: Sendable {
    /// What the launcher starts.
    public let engine: PiEngine
    /// Shepherd's pi home, and the files it writes there.
    public let files: PiHome
    /// Finds the user's own pi, once.
    public let yourPi: YourPiLocator
    /// The model catalog, asked of Shepherd's pi, kept for this setup's lifetime.
    public let catalog: PiModelCatalog

    public init(engine: PiEngine, home: URL, yourPi: YourPiLocator = YourPiLocator(.fixed(nil))) {
        self.engine = engine
        let files = PiHome(directory: home, engine: engine)
        self.files = files
        self.yourPi = yourPi
        catalog = PiModelCatalog(home: files, ready: { PiSetup.prepare(files, yourPi: yourPi) == nil })
    }

    /// Shepherd's pi home: `PI_CODING_AGENT_DIR` for every pi it starts.
    public var home: URL { files.directory }
    /// The launcher every launch goes through.
    public var launcher: URL { files.launcher }
    /// Where pi keeps its session files: `<home>/sessions`.
    public var sessionsRoot: URL { files.sessions }

    /// The folder an agent's sessions in `cwd` live in, which every launch names with
    /// `--session-dir`: `<home>/sessions/--<cwd>--`, pi's own name for it.
    public func sessionDirectory(forCwd cwd: String) -> URL {
        files.sessionDirectory(forCwd: cwd)
    }

    /// The setup for an environment: the engine `PiEngine.locate` finds in `app`, the home in the
    /// environment's support directory, and "your pi" as `YourPiLocator` finds it.
    public static func resolve(environment: [String: String], app: URL = Bundle.main.bundleURL,
                               edition: ShepherdEdition = .current) -> PiSetup {
        let support = ShepherdPaths.supportDirectory(environment: environment, edition: edition)
        return PiSetup(engine: PiEngine.locate(environment: environment, app: app),
                       home: support.appendingPathComponent("pi", isDirectory: true),
                       yourPi: YourPiLocator.forEnvironment(environment, supportDirectory: support))
    }

    /// The app's: resolved from the process environment the first time it is asked for. In a
    /// test process that environment is the scratch one `ShepherdTestIsolation` set as it loaded.
    public static let app = resolve(environment: ProcessInfo.processInfo.environment)

    // MARK: Before a launch

    /// Why no pi may start in this home; nil when it may. Checks the home against "your pi", then
    /// writes Shepherd's files into the home. Blocking (a login shell the first time, pi's
    /// settings lock): call it off the main thread and the server queue.
    public func prepare() -> PiHomeProblem? {
        Self.prepare(files, yourPi: yourPi)
    }

    static func prepare(_ files: PiHome, yourPi: YourPiLocator) -> PiHomeProblem? {
        if let problem = check(files, yourPi: yourPi.resolve(), refused: yourPi.refusedDirectory()) { return problem }
        do {
            for note in try files.install() { ShepherdLog.info(note) }
        } catch {
            return PiHomeProblem("Shepherd couldn't set up its pi home at \(files.directory.path): \(error)")
        }
        return nil
    }

    /// The startup guards: the home and its sessions must not resolve inside "your pi", nor
    /// "your pi" inside them, and "your pi" must not hold the marker of a Shepherd home. A folder
    /// the user's startup files name that was refused as "your pi" for being inside a support
    /// folder (`refused`) must not overlap the home either: their terminal pi would share it. Reads
    /// only.
    public static func check(_ files: PiHome, yourPi: YourPi?, refused: URL? = nil) -> PiHomeProblem? {
        if let refused {
            let theirs = PiHome.canonical(refused.path)
            for mine in [files.directory, files.sessions].map({ PiHome.canonical($0.path) })
            where PiHome.isInside(mine, theirs) || PiHome.isInside(theirs, mine) {
                return PiHomeProblem("Your pi (PI_CODING_AGENT_DIR in your shell, \(refused.path)) overlaps Shepherd's own pi home, so Shepherd "
                    + "won't start pi there. Point PI_CODING_AGENT_DIR in your shell at your own pi.")
            }
        }
        guard let yourPi else { return nil }
        let ours = [files.directory, files.sessions].map { PiHome.canonical($0.path) }
        let theirs = ([yourPi.agentDirectory] + (yourPi.sessionDirectory.map { [$0] } ?? [])).map { PiHome.canonical($0.path) }
        for mine in ours {
            for yours in theirs where PiHome.isInside(mine, yours) || PiHome.isInside(yours, mine) {
                return PiHomeProblem("Shepherd's pi home (\(files.directory.path)) and your pi (\(yours)) overlap, so Shepherd won't start pi "
                    + "there. Move one of them (SHEPHERD_SUPPORT_DIR or PI_CODING_AGENT_DIR).")
            }
        }
        if FileManager.default.fileExists(atPath: yourPi.agentDirectory.appendingPathComponent(PiHome.markerName).path) {
            return PiHomeProblem("Your pi (\(yourPi.agentDirectory.path)) is marked as a Shepherd pi home, so Shepherd won't start pi. "
                + "Point PI_CODING_AGENT_DIR in your shell at your own pi.")
        }
        return nil
    }
}

/// Why Shepherd won't start pi in its home.
public struct PiHomeProblem: Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
