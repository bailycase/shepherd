import Foundation
import GameController
import Observation

/// Whether a hardware keyboard is attached, as the Mac always has one: the sidebar's New thread row shows its chord (⌘N) only then
/// (iPadSidebar, DuoOpenThread). Read it in a view body and the view redraws when a keyboard connects or leaves.
@MainActor
@Observable
final class HardwareKeyboard {
    static let shared = HardwareKeyboard()

    private(set) var attached = GCKeyboard.coalesced != nil
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    private init() {
        // The observers live as long as the app; the notifications arrive on the main queue.
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    private func refresh() {
        let now = GCKeyboard.coalesced != nil
        if attached != now { attached = now }
    }
}
