import Foundation
import Observation
import UIKit
import ShepherdRemote

/// Routes a push notification tap to the right thread. Handles both warm and cold launch.
/// On cold launch the payload is held until the first window is ready.
@MainActor
@Observable
final class PushRouter {
    /// A tap waiting for the app to be ready (cold launch).
    private(set) var pending: PushPayload?

    /// Route a notification tap. If the app is ready and can navigate, does so now;
    /// otherwise holds it. Never clears `pending` unless routing actually succeeded.
    func route(_ payload: PushPayload, hosts: MobileHosts?, windows: MobileWindows?) {
        guard let hosts, let windows else {
            pending = payload
            return
        }
        guard let ref = payload.agentRef, hosts.host(ref.host) != nil else {
            pending = payload
            return
        }
        if navigate(to: ref, windows: windows) {
            pending = nil
        } else {
            pending = payload
        }
    }

    /// Called when the first window is ready, to drain any pending cold-launch tap.
    func drainPending(hosts: MobileHosts, windows: MobileWindows) {
        guard let payload = pending else { return }
        if let ref = payload.agentRef, hosts.host(ref.host) != nil {
            if navigate(to: ref, windows: windows) {
                pending = nil
            }
        } else {
            // Host not known (forgotten?); discard stale payload.
            pending = nil
        }
    }

    /// Navigate to a thread in the foreground window. Returns true if a window was found.
    @discardableResult
    private func navigate(to ref: AgentRef, windows: MobileWindows) -> Bool {
        guard let window = windows.notificationWindow else { return false }
        window.navigator.reveal(.thread(ref))
        return true
    }
}
