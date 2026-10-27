import Foundation

/// Whether this build talks to sandbox or production APNs.
///
/// The `aps-environment` entitlement is set per build configuration via `$(APS_ENVIRONMENT)`:
/// - **Debug** → `development` (APNs sandbox)
/// - **Release / Nightly** → `production` (APNs production; TestFlight uses production)
///
/// This enum mirrors that with `#if DEBUG`. No receipt sniffing, no private entitlement APIs.
enum PushEnvironment: String, Codable, Sendable {
    case sandbox, production

    /// Matches the `aps-environment` entitlement for this build configuration.
    static let current: PushEnvironment = {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }()

    /// The relay API string this environment sends. Verified at init to catch a build
    /// misconfiguration (e.g. wrong `APS_ENVIRONMENT` override) before it reaches APNs.
    static func verified() -> PushEnvironment {
        let env = current
        #if DEBUG
        assert(env == .sandbox, "DEBUG build must use sandbox APNs (aps-environment = development)")
        #else
        assert(env == .production, "Release build must use production APNs (aps-environment = production)")
        #endif
        return env
    }
}
