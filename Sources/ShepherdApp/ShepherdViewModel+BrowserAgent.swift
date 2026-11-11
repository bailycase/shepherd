import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// The agent's browser tools on the thread's own page: the background host relays each request
/// (`remoteBrowserDrive`), and the page answers.
extension ShepherdViewModel {
    /// The agent opened a page: nothing opens the pane by itself. The Browser tab takes a dot, with
    /// a brief line under it, and the header's button the same while the pane is out of sight.
    func agentOpenedPage(_ session: BrowserSession, _ url: URL) {
        session.noteAgentOpened(url)
        let owner = session.remote.map { SidePaneOwner.remote($0.ref) } ?? SidePaneOwner.local(session.agentID)
        let panes = subagentInspector
        let showing = sidePaneOwner == owner && panes.open.contains(owner) && panes.run(for: owner) == nil
            && panes.tab(for: owner) == .browser
        guard !showing else { return }
        panes.addNews(owner, .browser)
    }

    /// The card's Take over.
    func takeOverBrowser(_ session: BrowserSession) {
        session.takeOver()
    }
}
