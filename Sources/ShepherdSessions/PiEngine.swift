import Foundation

/// Which pi Shepherd starts, and the node its own scripts run on beside pi. Found once, where the
/// app starts (`PiSetup.resolve`), and handed to `PiLaunch`, which builds every line that starts
/// either one.
///
/// Today it is the user's own `pi` and `node`, which a login shell finds on their PATH, as
/// always. Debug builds (`swift test`, the Dev scheme) honour `SHEPHERD_PI_ENGINE`: one
/// executable that takes pi's arguments, which the tests point at a stand-in so that no test
/// reaches a real pi. Release builds ignore it, so an inherited or `launchctl` value can never
/// redirect every agent.
public struct PiEngine: Equatable, Sendable {
    /// How a program is named on a launch line.
    public enum Program: Equatable, Sendable {
        /// A command name the login shell looks up on its PATH (today's `pi` and `node`).
        case onPath(String)
        /// An absolute path, run as it is and never looked up.
        case executable(String)
    }

    /// What starts pi, before pi's own arguments.
    public var pi: Program
    /// The node Shepherd's own scripts run on (the MCP probe, the skills reader).
    public var node: Program

    public init(pi: Program, node: Program) {
        self.pi = pi
        self.node = node
    }

    /// The Debug-only override: one executable that takes pi's argv.
    public static let overrideEnvKey = "SHEPHERD_PI_ENGINE"

    /// The user's `pi` and `node` on their login shell's PATH: what Shepherd runs today.
    public static let userPi = PiEngine(pi: .onPath("pi"), node: .onPath("node"))

    /// Whether this build honours `SHEPHERD_PI_ENGINE`: Debug builds only.
    #if DEBUG
    public static let honoursOverride = true
    #else
    public static let honoursOverride = false
    #endif

    /// The engine for this environment. With the override honoured and set, pi is that file (a
    /// relative value resolves against the working directory, never on PATH) and nothing falls
    /// back to the user's pi; otherwise it is the user's pi.
    public static func locate(environment: [String: String], honoursOverride: Bool = PiEngine.honoursOverride) -> PiEngine {
        if honoursOverride, let value = environment[overrideEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            let path = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
            return PiEngine(pi: .executable(path), node: userPi.node)
        }
        return .userPi
    }
}
