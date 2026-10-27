import Foundation
import ShepherdProtocol
import ShepherdRemote

/// Every thread's Browser page on this device, and the one forwarder their ports share. A page keeps
/// its ports only while its host is connected: the app's going to the background drops every
/// connection (`MobileHosts.setForeground`), so nothing listens on the loopback then, and a page
/// takes its ports again when its host is back.
@MainActor
final class MobileBrowsers {
    static let shared = MobileBrowsers()

    /// Pages kept at once, each with a web view; the least recently shown one closes past it.
    /// ponytail: a fixed few, raise it (or close by memory warning) if people juggle more threads' pages.
    static let maxPages = 3

    let forwarder = BrowserPortForwarder()
    private var pages: [AgentRef: BrowserPage] = [:]
    /// Least recently shown first.
    private var recent: [AgentRef] = []

    /// The thread's page, made the first time it shows.
    func page(_ ref: AgentRef, host: MobileHost) -> BrowserPage {
        recent.removeAll { $0 == ref }
        recent.append(ref)
        if let page = pages[ref] { return page }
        let page = BrowserPage(ref: ref, host: host, forwarder: forwarder)
        pages[ref] = page
        if host.phase == .connected { page.resume() }
        while recent.count > Self.maxPages {
            pages.removeValue(forKey: recent.removeFirst())?.close()
        }
        return page
    }

    /// The thread's page, if it has one (fixtures).
    func existing(_ ref: AgentRef) -> BrowserPage? { pages[ref] }

    func connected(_ host: MobileHost) {
        for page in pages.values where page.ref.host == host.id { page.resume() }
    }

    func disconnected(_ host: MobileHost) {
        for page in pages.values where page.ref.host == host.id { page.suspend() }
    }

    func forget(host: UUID) {
        for (ref, page) in pages where ref.host == host {
            page.close()
            pages[ref] = nil
        }
        recent.removeAll { $0.host == host }
    }
}
