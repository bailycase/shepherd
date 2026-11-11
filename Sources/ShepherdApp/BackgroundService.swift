import Foundation
import Security
import ServiceManagement
import ShepherdProtocol

/// The background host's launchd job (`SMAppService.agent`, the plist the "Background host
/// LaunchAgent" build phase writes). The app's one seam to launchd: tests pass a fake and never
/// touch it.
struct BackgroundService {
    enum Status: Equatable {
        /// Registered and allowed: launchd runs the host.
        case enabled
        /// Turned off in System Settings ▸ Login Items.
        case requiresApproval
        case notRegistered
        /// The bundle has no plist (an older build), or launchd doesn't know the job.
        case notFound
    }

    var status: () -> Status
    var register: () throws -> Void
    var unregister: () throws -> Void
    var openLoginItems: () -> Void

    static func app(bundleIdentifier: String) -> BackgroundService {
        let service = SMAppService.agent(plistName: bundleIdentifier + ".host.plist")
        return BackgroundService(
            status: {
                switch service.status {
                case .enabled: .enabled
                case .requiresApproval: .requiresApproval
                case .notRegistered: .notRegistered
                case .notFound: .notFound
                @unknown default: .notFound
                }
            },
            register: { try service.register() },
            unregister: { try service.unregister() },
            openLoginItems: { SMAppService.openSystemSettingsLoginItems() })
    }

    /// Whether this launch may register the job: Shepherd Nightly only for now, never with a
    /// support folder moved (Dev, tests), and only from a stable, signed bundle. BTM records the
    /// path it registers, so a translocated copy (opened from the DMG or Downloads) or an ad-hoc
    /// build would leave a job pointing nowhere.
    static func mayRegister(bundleIdentifier: String?, bundlePath: String, environment: [String: String], adHoc: Bool) -> Bool {
        bundleIdentifier == ShepherdEdition.nightlyBundleIdentifier
            && environment["SHEPHERD_SUPPORT_DIR"] == nil
            && !bundlePath.contains("/AppTranslocation/")
            && !adHoc
    }

    /// Whether the running app's signature is ad hoc (or missing).
    static func isAdHoc(_ bundle: URL = Bundle.main.bundleURL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32 else { return true }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }

    /// Registers the job when this launch may (`mayRegister`) and answers its status; nil when
    /// it may not, so the app supervises its own host (`HostSupervisor`). A failed registration is logged and read as
    /// whatever status launchd reports after it.
    func prepare(may: Bool) -> Status? {
        guard may else { return nil }
        // Only a job never registered is registered: one turned off in Login Items stays off.
        if [.notRegistered, .notFound].contains(status()) {
            do { try register() } catch { NSLog("Shepherd: background service not registered: \(error)") }
        }
        return status()
    }
}

extension BackgroundService.Status {
    /// What a paired device reads (`HostSettings.backgroundService`): agents keep running when
    /// Shepherd is quit, or stop because the job is off in Login Items; nil when there is no job.
    var keepsAgentsRunning: Bool? {
        switch self {
        case .enabled: true
        case .requiresApproval: false
        case .notRegistered, .notFound: nil
        }
    }
}
