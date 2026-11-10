import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// An agent on another Mac drives the page this Mac shows for its thread. The page is a remote thread's `BrowserSession`; the host hands
/// each browser request to the viewer that owns the agent's browser, and this is where it arrives.
extension ShepherdViewModel {
    func installRemoteBrowserDrive() {
        remoteHosts.onBrowserDrive = { [weak self] hostID, client, push in
            MainActor.assumeIsolated { self?.remoteBrowserDrive(hostID: hostID, client: client, push: push) }
        }
        // The host's own address for the agent's page, for a viewer that claims it to open.
        server.onBrowserPageURL = { [weak self] agentID in
            MainActor.assumeIsolated {
                guard let session = self?.browsers.existing(agentID), let url = session.tabs.agentTarget?.url,
                      BrowserDriveURL.offered(url.absoluteString) != nil else { return nil }
                return url.absoluteString
            }
        }
    }

    /// One thing a host said about an agent's browser.
    func remoteBrowserDrive(hostID: UUID, client: RemoteHostClient, push: BrowserDrivePush) {
        let ref = RemoteAgentRef(hostID: hostID, agentID: push.agentID)
        // A thread of the background host that the app shows as its own: its page is the thread's
        // local one, as in process (`localHost`).
        let own = localHost?.id == hostID && state.agents.contains { $0.id == push.agentID }
        switch push {
        case .request(let token, _, let request):
            // Only the page this Mac claimed on this connection runs what the host sends, or the
            // thread's own page when the background host's agent is this app's.
            let claimed = browsers.existing(ref).flatMap { session in session.remote?.drives(for: client) == true ? session : nil }
            let session = own ? browsers.session(for: push.agentID) : claimed
            guard let session, own || session.remote != nil else {
                client.browserAnswer(token: token, outcome: .failure(code: BrowserDriveCode.viewerGone,
                                                                      message: "The Mac showing this page is not driving it any more."))
                return
            }
            Task { @MainActor [weak self] in
                let outcome = if let remote = session.remote {
                    await session.performFromHost(request, policy: remote.policy)
                } else {
                    await session.perform(request)
                }
                client.browserAnswer(token: token, outcome: outcome)
                if request.opensPage, case .result = outcome, let url = session.tabs.agentTarget?.url { self?.agentOpenedPage(session, url) }
            }
        case .abandoned:
            (own ? browsers.existing(push.agentID) : browsers.existing(ref))?.abandonQueued()
        case .ended(_, let reason):
            browsers.existing(ref)?.remote?.driveEnded(reason: reason)
        case .handBack:
            (own ? browsers.existing(push.agentID) : browsers.existing(ref))?.handBack()
        case .opened(_, let address):
            // The agent opened a page in the host's own browser (no viewer owned it): the tab says
            // so, and nothing opens by itself.
            guard BrowserDriveURL.offered(address) != nil, let url = URL(string: address) else { return }
            agentOpenedPage(own ? browsers.session(for: push.agentID) : browsers.session(for: ref, hosts: remoteHosts), url)
        }
    }

    /// A remote thread's Browser tab came on screen or went out of sight: it claims the agent's
    /// browser, or lets it go after a while.
    func browserPaneAppeared(_ session: BrowserSession) {
        session.remote?.paneShown()
    }

    func browserPaneDisappeared(_ session: BrowserSession) {
        session.remote?.paneHidden()
    }

    /// A host's connection changed: every remote page's claim follows it, whether or not its tab is
    /// on screen.
    func syncRemoteBrowserDrive() {
        browsers.forEachRemoteSession { $0.remote?.syncDriveConnection() }
    }
}
