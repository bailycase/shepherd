import Foundation
import ShepherdRemote

/// A run waiting on the model never waits silently forever. pi bounds each request itself (its
/// HTTP idle timeout, then its retries, each an event on stdout), so a run that has heard nothing
/// from pi for `stallBound`, with no tool, question, hook, compaction or retry under way, is a pi
/// that is stuck. Shepherd stops the run and its reply fails with `stallText`, so the thread shows
/// the turn-failed state with Retry (pi's checkpoint recovery continues an aborted reply too).
extension RPCThreadState {
    /// Long enough that a slow provider is never cut off: pi's own idle timeout (5 minutes) and a
    /// retry both say something before it passes. Tests shorten it (`SessionServer.threadStallBound`).
    static let defaultStallBound: Duration = .seconds(600)

    static func stallText(_ bound: Duration) -> String {
        let span = bound.formatted(.units(allowed: [.minutes, .seconds], width: .wide))
        return "No response from the model in \(span), so Shepherd stopped waiting. Retry to try again."
    }

    /// Server queue, at `agent_start`: one check at a time until the run settles.
    func watchForStall() {
        guard !stallWatching else { return }
        stallWatching = true
        scheduleStallCheck(after: stallBound)
    }

    private func scheduleStallCheck(after delay: Duration) {
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        queue.asyncAfter(deadline: .now() + max(seconds, 0.05)) { [weak self] in self?.checkStall() }
    }

    private func checkStall() {
        guard running, session.isAlive else { stallWatching = false; return }
        let bound = stallBound
        let quiet = lastEventAt.duration(to: .now)
        let waitingOnModel = runningTools.isEmpty && dialogs.isEmpty && retry == nil && hookStatus == nil
            && compactingRun == nil && !stopRequested && stallMessage == nil
        guard waitingOnModel, quiet >= bound else {
            scheduleStallCheck(after: quiet < bound ? bound - quiet : bound)
            return
        }
        let text = Self.stallText(bound)
        ShepherdLog.warning("rpc session \(session.id) stalled: nothing from pi in \(bound); stopping the run")
        stallMessage = text
        stallWatching = false
        session.request(.abort) { _ in }
        onRevision?()
    }
}
