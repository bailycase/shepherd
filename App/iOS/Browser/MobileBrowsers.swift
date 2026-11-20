import Foundation
import ShepherdProtocol
import ShepherdRemote

/// Every thread's Browser on this device, and the one forwarder their ports share. A browser keeps
/// its ports only while its host is connected: the app's going to the background drops every
/// connection (`MobileHosts.setForeground`), so nothing listens on the loopback then, and a page
/// takes its ports again when its host is back.
@MainActor
final class MobileBrowsers {
    static let shared = MobileBrowsers()

    /// Thread browsers kept at once; the least recently shown one closes past it.
    /// ponytail: a fixed few, raise it (or close by memory warning) if people juggle more threads' pages.
    static let maxPages = 3

    let forwarder = BrowserPortForwarder()
    private var browsers: [AgentRef: MobileBrowserTabs] = [:]
    /// Least recently shown first.
    private var recent: [AgentRef] = []

    func tabs(_ ref: AgentRef, host: MobileHost) -> MobileBrowserTabs {
        recent.removeAll { $0 == ref }
        recent.append(ref)
        if let tabs = browsers[ref] { return tabs }
        let tabs = MobileBrowserTabs(ref: ref, host: host, forwarder: forwarder)
        browsers[ref] = tabs
        if host.phase == .connected { tabs.resume() }
        while recent.count > Self.maxPages {
            browsers.removeValue(forKey: recent.removeFirst())?.closeAll()
        }
        return tabs
    }

    #if DEBUG
    func existing(_ ref: AgentRef) -> BrowserPage? { existingTabs(ref)?.selectedPage }
    func existingTabs(_ ref: AgentRef) -> MobileBrowserTabs? { browsers[ref] }
    #endif

    func connected(_ host: MobileHost) {
        for tabs in browsers.values where tabs.ref.host == host.id { tabs.resume() }
    }

    func disconnected(_ host: MobileHost) {
        for tabs in browsers.values where tabs.ref.host == host.id { tabs.suspend() }
    }

    func forget(host: UUID) {
        for (ref, tabs) in browsers where ref.host == host {
            tabs.closeAll()
            browsers[ref] = nil
        }
        recent.removeAll { $0.host == host }
    }
}
