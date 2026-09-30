import Foundation
import ShepherdProtocol
import ShepherdRemote

// A remote thread's agent drives the page this Mac shows (docs/browser.md › Remote › The agent drives
// the page you see). The host hands each `BrowserRequest` here and the page answers it with the same
// driver a local thread's agent has (`BrowserDriver.swift`); what differs is who is asking. A local
// agent is on this Mac, so its page may go anywhere this Mac's user may take it. A host's agent is on
// another machine, so the page must not become its window into this Mac's network: the rules below
// keep it to the host's own loopback ports (which the forwarded ports carry there) and the public web
// (`BrowserViewerPolicy`). `BrowserHost.swift`'s navigation policy enforces the same rules on every
// navigation the agent causes, a redirect and an iframe included.

/// Who a request comes from.
enum BrowserOrigin {
    /// The thread's own agent, on this Mac.
    case local
    /// An agent on the thread's host, through a viewer's claim.
    case host(BrowserHostGuard)
}

/// What a host's agent may ask of a page on this Mac.
struct BrowserHostGuard {
    let policy: BrowserViewerPolicy

    /// Ports of the host the agent may have this Mac forward for one page: each holds a listening
    /// socket here, so the count is bounded.
    static let maxForwardedPorts = 8

    /// The history step a request takes, if it takes one.
    static func historyStep(of request: BrowserRequest) -> BrowserHistoryStep? {
        switch request {
        case .back: .back
        case .forward: .forward
        case .reload: .reload
        default: nil
        }
    }

    /// Why `request` may not run now, in the outcome the agent reads; nil when it may. `page` is the
    /// address open now and `historyTarget` where a history step would land.
    ///
    /// `browser_open` takes only the addresses the policy allows. Every other request acts on, or
    /// reads, the page open now, so it must be one the agent may be shown: a private page the user
    /// opened by hand in this tab (a router, a file) is never read back to an agent on another
    /// Mac, and never its address or title.
    func refusal(for request: BrowserRequest, page: URL?, historyTarget: URL?) async -> BrowserOutcome? {
        if case .open(let text, _) = request {
            // An address that does not parse at all is the driver's own refusal to word.
            guard case .success(let url) = BrowserURLPolicy.agentURL(text) else { return nil }
            if case .refused(let why) = await policy.verdict(for: url) { return .failure(code: "refused_url", message: why.message) }
            return nil
        }
        if let refusal = await pageRefusal(page) { return refusal }
        if let historyTarget, case .refused(let why) = await policy.pageVerdict(for: historyTarget) {
            return .failure(code: "refused_url", message: why.message)
        }
        return nil
    }

    /// A refusal when the page open is not one the agent may be shown or act on.
    func pageRefusal(_ page: URL?) async -> BrowserOutcome? {
        guard case .refused = await policy.pageVerdict(for: page) else { return nil }
        return .failure(code: "refused_url", message: Self.pageMessage)
    }

    static let pageMessage = "The page open in this browser is on the network of the Mac showing it, so the browser won't read it "
        + "or act on it. Use browser_open to go to localhost or a public address."
}

extension BrowserSession {
    /// Serves a request an agent on the thread's host sent through this viewer's claim.
    func performFromHost(_ request: BrowserRequest, policy: BrowserViewerPolicy) async -> BrowserOutcome {
        await perform(request, origin: .host(BrowserHostGuard(policy: policy)))
    }
}
