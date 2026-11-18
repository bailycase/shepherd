import Foundation
import ShepherdProtocol

// Update Shepherd on a Mac, as the Mac and the phone draw it (FleetCheck, the Shepherd row's panel): what is ready for the Mac, what the buttons
// say, and while the host carries the update out, the state it is in. Plain values derived from the host's `FleetSnapshot` (`FleetSnapshot.updates`,
// `FleetPeerStatus.takesUpdates`, the Mac's last sample and Check report); the buttons are the caller's (`FleetCheckActions`).

/// The panel section for the build row of a Mac that is behind the fleet's newest build.
public struct FleetUpdateOffer: Equatable, Sendable {
    public struct Running: Equatable, Sendable {
        /// "Waiting for Mac Studio to wake", "Downloading 675", "Waiting for 2 threads to go idle", "Installing", "Relaunching".
        public var state: String
        public var note: String
        /// Cancel is offered: the update hasn't ended.
        public var cancellable: Bool
    }

    public var mac: UUID
    public var macName: String
    /// "Shepherd Nightly 675 is ready for Mac Studio".
    public var headline: String
    /// "Update Shepherd on Mac Studio".
    public var buttonTitle: String
    /// What the button does, in the board's words.
    public var note: String
    /// "Update now, stopping 2 threads"; nil when no thread works there (now is then the same as the button).
    public var nowTitle: String?
    /// The state of the update the host carries out, while it does.
    public var running: Running?
    /// How an update that ended went, when it didn't update the Mac: why, in the Mac's words.
    public var problem: String?
    /// The update failed (the problem is drawn as one), rather than found nothing to install or needs the person at that Mac.
    public var failed = false
    /// The Mac runs a Shepherd that can't be asked: there is no button, and the note says to update it there.
    public var canStart: Bool

    /// What the panel says of `mac`'s update. `newest` is the fleet's newest build.
    static func make(mac: UUID, entry: FleetCheckPage.Entry, newest: String?) -> FleetUpdateOffer {
        let name = entry.name
        let product = entry.product
        let build = newest.map { " \($0)" } ?? ""
        var offer = FleetUpdateOffer(mac: mac, macName: name, headline: "\(product)\(build) is ready for \(name)", buttonTitle: "Update Shepherd on \(name)",
                                     note: "\(name) installs it from its own update feed and relaunches. Threads working there wait: it updates once they’re idle. Asleep, it updates when it wakes.",
                                     nowTitle: nil, running: nil, problem: nil, failed: false, canStart: true)
        if entry.takesUpdates == false {
            offer.canStart = false
            offer.note = "Update Shepherd on \(name) yourself. It runs a Shepherd that can’t be updated from here."
            return offer
        }
        if let working = entry.working, working > 0 {
            offer.nowTitle = "Update now, stopping \(working) \(working == 1 ? "thread" : "threads")"
        }
        guard let job = entry.update else { return offer }
        if job.stage.isRunning || job.stage == .updated {
            offer.running = running(job, name: name, newest: newest)
        } else if let message = job.message, !message.isEmpty {
            offer.problem = message
            offer.failed = job.stage == .failed
        }
        return offer
    }

    /// The card of an update that goes on, or just ended well.
    static func running(_ job: FleetUpdateStatus, name: String, newest: String?) -> Running {
        let build = newest ?? "the update"
        let after = "This row checks again after."
        switch job.stage {
        case .waitingToWake:
            let then = job.when == .now ? "stops its threads" : "waits for its threads to go idle"
            return Running(state: "Waiting for \(name) to wake", note: "Then it downloads \(build), \(then), installs and relaunches. \(after)", cancellable: true)
        case .checking:
            return Running(state: "Asking \(name)’s update feed", note: "\(name) looks for what its own feed offers. \(after)", cancellable: true)
        case .downloading:
            return Running(state: "Downloading \(build)", note: "\(name) downloads it from its own update feed and checks its signature. \(after)", cancellable: true)
        case .waitingForThreads:
            let state = job.threads.map { $0 > 0 ? "Waiting for \($0) \($0 == 1 ? "thread" : "threads") to go idle" : "Waiting for its threads to go idle" } ?? "Waiting for its threads to go idle"
            return Running(state: state, note: "\(name) installs as soon as they’re idle. \(after)", cancellable: true)
        case .installing:
            return Running(state: "Installing", note: "\(name) installs the update, then relaunches. \(after)", cancellable: true)
        case .relaunching:
            return Running(state: "Relaunching", note: "\(name) restarts Shepherd to finish. This row checks again when it’s back.", cancellable: true)
        case .updated, .upToDate, .failed, .needsApp:
            return Running(state: "Updated", note: "\(name) is back on a newer build. Checking it again.", cancellable: false)
        }
    }
}
