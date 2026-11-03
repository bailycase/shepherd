import Foundation
import Observation
import os
import ShepherdRemote

/// Fixed-label signposts for Instruments (subsystem `com.shepherd.ios`, category `UI`): when the
/// app first has something usable to show, each reconnect, and iPad thread switches. They carry
/// no content, names or ids, and stay on the device.
enum MobileSignposts {
    static let signposter = OSSignposter(subsystem: "com.shepherd.ios", category: "UI")

    /// An iPad thread selected: one kept mounted (a visibility flip) or one mounted anew.
    static func threadSwitch(retained: Bool) {
        if retained {
            signposter.emitEvent("Thread switch", "retained")
        } else {
            signposter.emitEvent("Thread switch", "mounted")
        }
    }
}

/// When the app first has something usable on screen, and how long each reconnect takes to get
/// there. Usable is not "a socket opened": it is onboarding (no hosts), a host's threads
/// (its state arrives with the handshake), or every host's failure with its way to retry.
///
/// The first time per launch that a window shows with the hosts settled, within the SDK's own
/// 30 s deadline, it calls `onLaunchReady` (the
/// diagnostics' full-display report, `MobileDiagnostics.reportFullyDisplayed`); a later
/// foreground's reconnect only signposts: the SDK times one launch screen, not each return.
@MainActor
final class MobileReadiness {
    enum Milestone: String {
        case onboarding, live, failed
    }

    /// Where the hosts stand: nil while a connection is still being tried, or before any is.
    static func milestone(_ phases: [RemoteHostPhase]) -> Milestone? {
        if phases.isEmpty { return .onboarding }
        if phases.contains(.connected) { return .live }
        if phases.contains(.connecting) { return nil }
        return phases.contains { $0.failure != nil } ? .failed : nil
    }

    /// Sentry ends a launch screen's full-display span itself after this long.
    static let reportDeadline: Duration = .seconds(30)

    private let hosts: MobileHosts
    private let onLaunchReady: () -> Void
    private let started = ContinuousClock.now
    private var launch: OSSignpostIntervalState?
    private var reconnect: OSSignpostIntervalState?
    private var appeared = false

    /// What launch reached first, and whether the diagnostics heard it (for checks).
    private(set) var launchMilestone: Milestone?
    private(set) var reported = false
    /// Reconnects that reached a milestone, and how many began while last known threads showed.
    private(set) var reconnects = 0
    private(set) var cachedShown = 0

    init(hosts: MobileHosts, onLaunchReady: @escaping () -> Void) {
        self.hosts = hosts
        self.onLaunchReady = onLaunchReady
        launch = MobileSignposts.signposter.beginInterval("Launch ready")
        track()
    }

    private func track() {
        let (phases, cached) = withObservationTracking {
            (hosts.hosts.map(\.phase), hosts.hosts.contains { !$0.state.agents.isEmpty })
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        observe(phases, cached: cached)
    }

    /// A window's root is on screen (`ShepherdIOSApp`). Diagnostics started in the app's `init`,
    /// before any window: only from here may the launch be reported, whatever the hosts reached
    /// while this object was being made (it is made before diagnostics start).
    func windowAppeared() {
        guard !appeared else { return }
        appeared = true
        if let milestone = Self.milestone(hosts.hosts.map(\.phase)) { finishLaunch(milestone) }
    }

    private func finishLaunch(_ milestone: Milestone) {
        guard let launch else { return }
        self.launch = nil
        MobileSignposts.signposter.endInterval("Launch ready", launch, "\(milestone.rawValue, privacy: .public)")
        launchMilestone = milestone
        // Past the SDK's own deadline its launch screen's span has ended: a report now would
        // land on whatever screen it times next.
        if ContinuousClock.now - started < Self.reportDeadline {
            reported = true
            onLaunchReady()
        }
    }

    private func observe(_ phases: [RemoteHostPhase], cached: Bool) {
        let milestone = Self.milestone(phases)
        if launch != nil {
            if appeared, let milestone { finishLaunch(milestone) }
            return
        }
        if reconnect == nil, milestone == nil, phases.contains(.connecting) {
            // Back from the background or a drop: the last known threads show meanwhile.
            reconnect = MobileSignposts.signposter.beginInterval("Reconnect")
            if cached {
                cachedShown += 1
                MobileSignposts.signposter.emitEvent("Cached content")
            }
        } else if let reconnect, milestone != nil || !phases.contains(.connecting) {
            self.reconnect = nil
            let outcome = milestone?.rawValue ?? "abandoned"
            MobileSignposts.signposter.endInterval("Reconnect", reconnect, "\(outcome, privacy: .public)")
            if milestone != nil { reconnects += 1 }
        }
    }
}
