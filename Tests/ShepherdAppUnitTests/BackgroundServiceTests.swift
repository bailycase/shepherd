import Testing
@testable import ShepherdApp
import ShepherdProtocol

/// When the app registers the background host's launchd job, through a fake seam: launchd is
/// never touched.
@Suite("Background service registration")
struct BackgroundServiceTests {
    private let nightly = ShepherdEdition.nightlyBundleIdentifier
    private let stable = "/Applications/Shepherd Nightly.app"

    @Test func onlyASignedShepherdOrNightlyAtAStablePathOutsideTestsMayRegister() {
        #expect(BackgroundService.mayRegister(bundleIdentifier: nightly, bundlePath: stable, environment: [:], adHoc: false))
        #expect(BackgroundService.mayRegister(bundleIdentifier: ShepherdEdition.mainBundleIdentifier, bundlePath: "/Applications/Shepherd.app",
                                               environment: [:], adHoc: false))
        #expect(!BackgroundService.mayRegister(bundleIdentifier: "com.bailycase.shepherd.dev", bundlePath: stable, environment: [:], adHoc: false))
        #expect(!BackgroundService.mayRegister(bundleIdentifier: nightly, bundlePath: stable, environment: ["SHEPHERD_SUPPORT_DIR": "/tmp/s"], adHoc: false))
        #expect(!BackgroundService.mayRegister(bundleIdentifier: nightly, bundlePath: "/private/var/folders/x/T/AppTranslocation/1A2B/d/Shepherd Nightly.app",
                                               environment: [:], adHoc: false))
        #expect(!BackgroundService.mayRegister(bundleIdentifier: nightly, bundlePath: stable, environment: [:], adHoc: true))
    }

    @Test func onlyAJobNeverRegisteredIsRegisteredAndOneTurnedOffStaysOff() {
        final class Launchd { var status = BackgroundService.Status.notRegistered; var registered = 0 }
        let launchd = Launchd()
        let service = BackgroundService(status: { launchd.status }, register: { launchd.registered += 1; launchd.status = .enabled },
                                        unregister: {}, openLoginItems: {})
        #expect(service.prepare(may: false) == nil && launchd.registered == 0)
        #expect(service.prepare(may: true) == .enabled && launchd.registered == 1)
        #expect(service.prepare(may: true) == .enabled && launchd.registered == 1, "registered once")
        launchd.status = .requiresApproval
        #expect(service.prepare(may: true) == .requiresApproval && launchd.registered == 1, "turned off in Login Items: no prompt again")
    }
}
