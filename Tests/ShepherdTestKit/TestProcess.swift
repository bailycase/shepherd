import Foundation
import ShepherdTestIsolation

/// The scratch directories `ShepherdTestIsolation` gave this test process when it loaded, before
/// any test ran: `SHEPHERD_SUPPORT_DIR` (and with it Shepherd's pi home, `support/pi`),
/// `ZDOTDIR`, `SHEPHERD_YOUR_PI` ("your pi"), `SHEPHERD_PI_ENGINE`, and a directory first on
/// `PATH` all point in here, and the whole tree is removed when the process exits.
public enum TestProcess {
    public static let root = URL(fileURLWithPath: String(cString: shepherd_test_isolation_root()), isDirectory: true)

    /// `SHEPHERD_SUPPORT_DIR`: where the app installs extensions, themes, and shell integration.
    public static var supportDirectory: URL { root.appendingPathComponent("support", isDirectory: true) }

    /// First on `PATH`, also in login shells: `gh` and `pi` here refuse to run, and so does
    /// `piEngine` until a test installs the stub over it (`StubPi.installAsEngine()`).
    public static var binDirectory: URL { root.appendingPathComponent("bin", isDirectory: true) }

    /// `SHEPHERD_PI_ENGINE`: the engine Shepherd's launcher starts (`PiEngine`), never one found on
    /// PATH (unset for the opt-in live-model run).
    public static var piEngine: URL { binDirectory.appendingPathComponent("pi-engine") }

    /// Shepherd's own pi home in this process: `support/pi`, where the app writes its launcher,
    /// settings and sessions.
    public static var piHome: URL { supportDirectory.appendingPathComponent("pi", isDirectory: true) }

    /// Where the stub engine records each launch it gets, one JSON object a line: its argv, its
    /// working directory and its environment (`StubPi.installAsEngine`).
    public static var piLaunches: URL { binDirectory.appendingPathComponent("pi-launches.jsonl") }

    /// `ZDOTDIR`, so login shells never run the user's dotfiles; its startup files keep
    /// `binDirectory` first on PATH and set the decoys (`piDecoyDirectory`).
    public static var zdotdir: URL { root.appendingPathComponent("zdotdir", isDirectory: true) }

    /// Where the startup files' decoys point (`PI_CODING_AGENT_DIR`, `PI_PACKAGE_DIR`,
    /// `NODE_OPTIONS`, `JITI_ALIAS`), as a user's own might: never `piAgentDirectory`.
    public static var piDecoyDirectory: URL { root.appendingPathComponent("pi-decoy", isDirectory: true) }

    /// "Your pi" (`SHEPHERD_YOUR_PI`): what the app reads of the user's own pi, and never writes.
    /// The process's `PI_CODING_AGENT_DIR` names it too, as a decoy: Shepherd's home never comes
    /// from it. Unset for the opt-in live-model run.
    public static var piAgentDirectory: URL { root.appendingPathComponent("pi-agent", isDirectory: true) }
}
