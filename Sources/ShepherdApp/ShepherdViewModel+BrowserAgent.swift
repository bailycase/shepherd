import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// The agent's browser tools on the thread's own page: the background host relays each request
/// (`remoteBrowserDrive`), and the page answers.
extension ShepherdViewModel {
    /// The agent asked to show its Browser (`browser_show`): the thread's side pane opens on the
    /// Browser tab. The user stays in whichever thread they are in; opening a page alone shows nothing.
    func agentShowedBrowser(_ session: BrowserSession) {
        showSidePane(session.remote.map { SidePaneOwner.remote($0.ref) } ?? SidePaneOwner.local(session.agentID), tab: .browser)
    }

    /// The card's Take over.
    func takeOverBrowser(_ session: BrowserSession) {
        session.takeOver()
    }
}
