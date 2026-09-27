import Foundation

/// The pi Shepherd starts, and the node its own scripts run on beside pi. Found once, where the
/// app starts (`PiSetup.resolve`). Nothing starts it directly: Shepherd's launcher in its pi
/// home (`PiHome`) execs `command`, and `PiLaunch` builds every line that starts the launcher.
///
/// In the app it is the engine inside the bundle (`BundledPiEngine`): node at
/// `Contents/Helpers/node` running pi's `dist/bundle/cli.js`. It never falls back to a `pi` or
/// `node` on PATH: a missing engine keeps its expected paths, and the launcher says it's missing.
/// Debug builds (`swift test`, the Dev scheme) honour `SHEPHERD_PI_ENGINE`: one executable that
/// takes pi's arguments, which the tests point at a stand-in so that no test reaches a real pi.
/// Release builds ignore it, so an inherited or `launchctl` value can never redirect every agent.
public struct PiEngine: Equatable, Sendable {
    /// How a program is named on a line.
    public enum Program: Equatable, Sendable {
        /// A command name looked up on PATH: only the node a Debug override brings, when the build
        /// has no engine of its own (`swift test`).
        case onPath(String)
        /// An absolute path, run as it is and never looked up.
        case executable(String)
    }

    /// What starts pi, before pi's own arguments: the engine's node and entry, or the override's
    /// one file. Absolute paths only.
    public var command: [String]
    /// pi's package directory (`PI_PACKAGE_DIR`); nil for an override, which brings its own.
    public var packageDirectory: String?
    /// pi's version, from the engine's package.json; nil for an override or a missing engine.
    public var version: String?
    /// The node Shepherd's own scripts run on (the MCP probe, the skills reader).
    public var node: Program

    public init(command: [String], packageDirectory: String?, version: String?, node: Program) {
        self.command = command
        self.packageDirectory = packageDirectory
        self.version = version
        self.node = node
    }

    /// The Debug-only override: one executable that takes pi's argv.
    public static let overrideEnvKey = "SHEPHERD_PI_ENGINE"

    /// Whether this build honours `SHEPHERD_PI_ENGINE`: Debug builds only.
    #if DEBUG
    public static let honoursOverride = true
    #else
    public static let honoursOverride = false
    #endif

    /// The engine a bundle ships.
    public static func bundled(_ engine: BundledPiEngine) -> PiEngine {
        PiEngine(command: engine.command, packageDirectory: engine.packageDirectory.path, version: engine.version,
                 node: .executable(engine.node.path))
    }

    /// The engine `app` should hold but doesn't (a damaged install): its expected paths, which the
    /// launcher finds missing, so the agent says why instead of starting some other pi.
    public static func missing(app: URL) -> PiEngine {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let node = contents.appendingPathComponent(BundledPiEngine.nodePath).path
        let package = contents.appendingPathComponent(BundledPiEngine.packagePath, isDirectory: true)
        return PiEngine(command: [node, package.appendingPathComponent(BundledPiEngine.entryPath).path],
                        packageDirectory: package.path, version: nil, node: .executable(node))
    }

    /// The engine for this environment and app. With the override honoured and set, pi is that
    /// file (a relative value resolves against the working directory, never on PATH), and the
    /// node beside it is the app's own when it has one, else `node` on PATH (the tests' node).
    /// Otherwise it is the engine inside `app`, or its expected paths when it's missing.
    public static func locate(environment: [String: String], app: URL = Bundle.main.bundleURL,
                              honoursOverride: Bool = PiEngine.honoursOverride) -> PiEngine {
        let bundled = BundledPiEngine(app: app)
        if honoursOverride, let value = environment[overrideEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            let path = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
            return PiEngine(command: [path], packageDirectory: nil, version: nil,
                            node: bundled.map { .executable($0.node.path) } ?? .onPath("node"))
        }
        return bundled.map(PiEngine.bundled) ?? .missing(app: app)
    }
}

/// The engine Shepherd ships inside the app: Node at `Contents/Helpers/node` and pi's package at
/// `Contents/Resources/pi-engine`, started as `node <package>/dist/bundle/cli.js`.
/// `scripts/pi_engine.py` stages that layout and the Mac target's "Embed pi engine" phase copies
/// it in (`Tests/Release` holds the two to these paths).
public struct BundledPiEngine: Equatable, Sendable {
    public static let nodePath = "Helpers/node"
    public static let packagePath = "Resources/pi-engine"
    public static let entryPath = "dist/bundle/cli.js"
    /// The bundle's library entry, which Shepherd's own scripts import (the skills reader).
    public static let libraryPath = "dist/bundle/index.js"

    /// Node, the one executable the engine ships.
    public let node: URL
    /// pi's package directory (`PI_PACKAGE_DIR`).
    public let packageDirectory: URL
    /// The file node runs: the package's `bin`.
    public let entry: URL
    /// pi's version, from its package.json.
    public let version: String

    /// The engine under `contents` (an app's Contents, or a staged tree with the same layout),
    /// or nil when node isn't executable, the entry is missing, or package.json names no version.
    public init?(contents: URL) {
        let node = contents.appendingPathComponent(Self.nodePath)
        let package = contents.appendingPathComponent(Self.packagePath, isDirectory: true)
        let entry = package.appendingPathComponent(Self.entryPath)
        let files = FileManager.default
        guard files.isExecutableFile(atPath: node.path), files.fileExists(atPath: entry.path),
              let data = try? Data(contentsOf: package.appendingPathComponent("package.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = manifest["version"] as? String, !version.isEmpty
        else { return nil }
        self.node = node
        self.packageDirectory = package
        self.entry = entry
        self.version = version
    }

    /// The engine inside an app bundle.
    public init?(app: URL) {
        self.init(contents: app.appendingPathComponent("Contents", isDirectory: true))
    }

    /// What starts pi, before pi's own arguments.
    public var command: [String] { [node.path, entry.path] }
}
