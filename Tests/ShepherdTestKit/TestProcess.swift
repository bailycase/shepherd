import Foundation
import ShepherdTestIsolation

/// The scratch directories `ShepherdTestIsolation` gave this test process when it loaded, before
/// any test ran: `SHEPHERD_SUPPORT_DIR`, `ZDOTDIR`, `PI_CODING_AGENT_DIR`, and a directory first
/// on `PATH` all point in here, and the whole tree is removed when the process exits.
public enum TestProcess {
    public static let root = URL(fileURLWithPath: String(cString: shepherd_test_isolation_root()), isDirectory: true)

    /// `SHEPHERD_SUPPORT_DIR`: where the app installs extensions, themes, and shell integration.
    public static var supportDirectory: URL { root.appendingPathComponent("support", isDirectory: true) }

    /// First on `PATH`, empty until a test installs a stand-in there (the stub `pi`).
    public static var binDirectory: URL { root.appendingPathComponent("bin", isDirectory: true) }

    /// `ZDOTDIR`: empty, so login shells never run the user's dotfiles.
    public static var zdotdir: URL { root.appendingPathComponent("zdotdir", isDirectory: true) }

    /// `PI_CODING_AGENT_DIR`: the pi config the app reads and the session files it seeds (unset
    /// for the opt-in live-model run, which uses the user's pi).
    public static var piAgentDirectory: URL { root.appendingPathComponent("pi-agent", isDirectory: true) }
}
