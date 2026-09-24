import Foundation

/// Which Shepherd app this process belongs to. Shepherd and Shepherd Nightly install side by
/// side, and each owns a socket, a `state.json` and its pi processes, so they never share a
/// support directory, preferences or a default listener port.
///
/// The bundle identifier decides it: Sparkle updates and the preferences domain already follow
/// the identifier, so keying the rest off it means one build setting says which app a build is.
public enum ShepherdEdition: String, Sendable, CaseIterable {
    case main
    case nightly

    public static let mainBundleIdentifier = "com.bailycase.shepherd"
    public static let nightlyBundleIdentifier = "com.bailycase.shepherd.nightly"

    /// Anything that is not Shepherd Nightly (a SwiftPM tool, a test runner, the Dev build) is
    /// the everyday app.
    public init(bundleIdentifier: String?) {
        self = bundleIdentifier == Self.nightlyBundleIdentifier ? .nightly : .main
    }

    /// The running process's edition. A tool embedded in an app's `Contents/MacOS` (the CLI)
    /// shares that app's main bundle, and so its edition.
    public static let current = ShepherdEdition(bundleIdentifier: Bundle.main.bundleIdentifier)

    public var displayName: String {
        switch self {
        case .main: "Shepherd"
        case .nightly: "Shepherd Nightly"
        }
    }

    /// The folder under Application Support.
    public var supportDirectoryName: String { displayName }

    /// The remote listener's default port, one apart so both apps can serve at once.
    public var defaultRemoteListenerPort: UInt16 {
        switch self {
        case .main: 7433
        case .nightly: 7434
        }
    }
}
