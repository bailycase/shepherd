import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// The agent's browser tools on the thread's own page (docs/browser.md): the server hands each
/// request here, only for the agent whose connection asked, and the page answers.
extension ShepherdViewModel {
    func installBrowserAgentControl() {
        server.onBrowserRequest = { [weak self] agentID, request, respond in
            MainActor.assumeIsolated {
                guard let self else {
                    respond(.failure(code: "unavailable", message: "Shepherd is closing."))
                    return
                }
                self.serveBrowser(request, for: agentID, respond: respond)
            }
        }
        // The user's next message to a thread gives the agent the page back after a take over.
        server.onUserMessage = { [weak self] agentID in
            MainActor.assumeIsolated { self?.browsers.existing(agentID)?.handBack() }
        }
    }

    /// One browser tool call. A thread's page is made the first time it opens something.
    func serveBrowser(_ request: BrowserRequest, for agentID: AgentID, respond: @escaping (BrowserOutcome) -> Void) {
        guard let agent = state.agents.first(where: { $0.id == agentID }) else {
            respond(.failure(code: "no_such_agent", message: "no such agent"))
            return
        }
        guard agent.designID == nil else {
            respond(.failure(code: "not_a_thread", message: "A design's agent has no browser."))
            return
        }
        let session = browsers.session(for: agentID)
        Task { @MainActor [weak self] in
            let outcome = await session.perform(request)
            if case .open = request, case .result = outcome, let url = session.url { self?.agentOpenedPage(session, url) }
            respond(outcome)
        }
    }

    /// The agent opened a page: nothing opens the pane by itself. The Browser tab takes a dot, with
    /// a brief line under it, and the header's button the same while the pane is out of sight.
    func agentOpenedPage(_ session: BrowserSession, _ url: URL) {
        session.noteAgentOpened(url)
        let owner = SidePaneOwner.local(session.agentID)
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
