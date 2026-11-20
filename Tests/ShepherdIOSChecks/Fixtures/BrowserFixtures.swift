import Foundation
import UIKit
import WebKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// The Browser (DuoSidePaneTabs › Browser): a thread's page pushed full screen. Studio offers
// `browser.tunnel.v1`, answers the dev-server query with two scripts, and serves a canned dev server
// through the tunnel on `BrowserFixture.port`, so the page loads through the real forwarder, hub and
// connection. The forwarder listens on the simulator's loopback, which is the Mac's: the port is
// one nothing else should hold.
//
// `browser`: nothing runs, so the page offers Start on the host. `browser-page`: the dev server
// runs, and the page finds and opens it. `browser-waiting`: Start ran and the port is tried.
// `browser-offline`: the host is offline. `browser-legacy`: an older host, no tunnels.
extension FixtureCatalog {
    static var browser: [FixtureScreen] {
        let ref = FixtureData.ref(FixtureData.preview)
        let routes: [MobileRoute] = [.thread(ref), .browser(.page(ref))]
        return [
            FixtureScreen(name: "browser", hosts: BrowserFixture.hosts(running: false), routes: routes, prepare: { _ in
                await FixtureCheck.wait("dev servers looked for", seconds: 30) {
                    MobileBrowsers.shared.existing(ref)?.lookedForRunning == true
                }
            }),
            FixtureScreen(name: "browser-page", hosts: BrowserFixture.hosts(running: true), routes: routes, prepare: { _ in
                await FixtureCheck.wait("page loaded through the tunnel", seconds: 20) {
                    guard let page = MobileBrowsers.shared.existing(ref) else { return false }
                    return page.url != nil && !page.isLoading && page.webView?.url != nil
                }
                let title = try? await MobileBrowsers.shared.existing(ref)?.webView?.evaluateJavaScript("document.title") as? String
                FixtureCheck.report(title == BrowserFixture.title
                    ? "FIXTURE CHECK ok browser-page \(title ?? "")"
                    : "FIXTURE CHECK FAILED browser-page title \(title ?? "nil"), notice \(MobileBrowsers.shared.existing(ref)?.notice ?? "none")")
            }),
            // Start ran (or a server was picked): its port is tried until it answers.
            FixtureScreen(name: "browser-waiting", hosts: BrowserFixture.hosts(running: false), routes: routes, prepare: { _ in
                await FixtureCheck.wait("dev servers looked for", seconds: 30) {
                    MobileBrowsers.shared.existing(ref)?.lookedForRunning == true
                }
                MobileBrowsers.shared.existing(ref)?.wait(for: URL(string: "http://localhost:\(BrowserFixture.port)")!)
            }),
            // The thread's host is offline: nothing listens, and the page says so.
            FixtureScreen(name: "browser-offline", routes: [.browser(.page(FixtureData.ref(FixtureData.preview, on: FixtureData.laptop)))]),
            FixtureScreen(name: "browser-legacy", hosts: BrowserFixture.hosts(running: false, capable: false), routes: routes),
            // iPadPaneBrowser: the pane beside the thread, the pay button picked, its popover open, and an element already
            // added to the draft.
            FixtureScreen(name: "browser-pad-pick", hosts: BrowserFixture.hosts(running: true, html: BrowserFixture.checkout), routes: routes,
                          prepare: { app in await BrowserFixture.pick(app, ref: ref) }),
            FixtureScreen(name: "browser-tabs", hosts: BrowserFixture.hosts(running: true, html: BrowserFixture.payments), routes: routes,
                          prepare: { app in await BrowserFixture.tabs(app, ref: ref, state: .two) }),
            FixtureScreen(name: "browser-tabs-popup", hosts: BrowserFixture.hosts(running: true, html: BrowserFixture.payments), routes: routes,
                          prepare: { app in await BrowserFixture.tabs(app, ref: ref, state: .popup) }),
            FixtureScreen(name: "browser-tabs-full", hosts: BrowserFixture.hosts(running: true, html: BrowserFixture.payments), routes: routes,
                          prepare: { app in await BrowserFixture.tabs(app, ref: ref, state: .full) }),
            FixtureScreen(name: "browser-tabs-full-menu", hosts: BrowserFixture.hosts(running: true, html: BrowserFixture.payments), routes: routes,
                          prepare: { app in await BrowserFixture.tabs(app, ref: ref, state: .fullMenu) }),
            FixtureScreen(name: "browser-tabs-close", hosts: BrowserFixture.hosts(running: true, html: BrowserFixture.payments), routes: routes,
                          prepare: { app in await BrowserFixture.tabs(app, ref: ref, state: .close) }),
        ]
    }
}

enum BrowserFixture {
    /// The dev server's port on the host, and the one forwarded on the device.
    static let port = 41_731
    static let popupPort = 41_732
    static let title = "Widget gallery"

    static func hosts(running: Bool, capable: Bool = true, html: String = BrowserFixture.html) -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        guard let index = hosts.firstIndex(where: { $0.id == FixtureData.studio }) else { return hosts }
        if !capable {
            hosts[index].capabilities = hosts[index].defaultCapabilities.filter { $0 != RemoteProtocol.browserTunnelCapability }
            return hosts
        }
        let servers = [
            DevServer(script: "dev", command: "pnpm dev", packageName: "widget-gallery", directory: "/Users/dev/Shepherd",
                      manifest: "package.json", port: port),
            DevServer(script: "storybook", command: "pnpm storybook", packageName: "widget-gallery", directory: "/Users/dev/Shepherd",
                      manifest: "package.json", port: 6006),
        ]
        hosts[index].reply = { request in
            guard case .agentQuery(let id, _, .devServers) = request else { return nil }
            return .agentResult(id: id, result: .devServers(servers))
        }
        let server = Server(running: running, html: html)
        hosts[index].tunnel = { server.answer($0) }
        return hosts
    }

    /// A dev server that answers every GET of `/` with the gallery and anything else with a 404,
    /// one request per tunnel (`Connection: close`).
    final class Server: @unchecked Sendable {
        let running: Bool
        let html: String
        private let lock = NSLock()
        private var requests: [Int: Data] = [:]

        init(running: Bool, html: String) {
            self.running = running
            self.html = html
        }

        func answer(_ frame: BrowserTunnelFrame) -> [BrowserTunnelFrame] {
            switch frame {
            case .open(let tunnel, _, let port):
                guard running, port == BrowserFixture.port || port == BrowserFixture.popupPort else {
                    return [.close(tunnel: tunnel, code: BrowserTunnelCode.refused)]
                }
                return [.opened(tunnel: tunnel)]
            case .data(let tunnel, let bytes):
                let request: Data = lock.withLock {
                    requests[tunnel, default: Data()].append(bytes)
                    return requests[tunnel] ?? Data()
                }
                var frames: [BrowserTunnelFrame] = [.credit(tunnel: tunnel, bytes: bytes.count)]
                guard request.range(of: Data("\r\n\r\n".utf8)) != nil else { return frames }
                let line = String(decoding: request.prefix { $0 != 0x0D }, as: UTF8.self)
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let found = path == "/" || path.hasPrefix("/?")
                let body = Data((found ? html : "Not found").utf8)
                let head = "HTTP/1.1 \(found ? "200 OK" : "404 Not Found")\r\nContent-Type: \(found ? "text/html" : "text/plain"); charset=utf-8\r\n"
                    + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                frames += BrowserTunnelChunks.split(Data(head.utf8) + body).map { .data(tunnel: tunnel, bytes: $0) }
                frames.append(.finish(tunnel: tunnel))
                return frames
            case .finish, .close:
                lock.withLock { requests[frame.tunnel] = nil }
                return []
            case .opened, .credit, .keepalive:
                return []
            }
        }
    }

    static let html = """
    <!doctype html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Widget gallery</title>
    <style>
    :root{color-scheme:light dark}
    body{font-family:-apple-system,sans-serif;margin:0;padding:14px;background:#f6f7f9;color:#14161a}
    h1{font-size:15px;margin:0 0 10px}
    .grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}
    .wg{border-radius:12px;background:#fff;border:1px solid #e3e5ea;padding:10px;font-size:12px;color:#5b616e}
    .wg b{display:block;font-size:13px;color:#14161a;margin-bottom:4px}
    .wide{grid-column:span 2}
    @media (prefers-color-scheme:dark){body{background:#1c1e22;color:#eceef2}.wg{background:#141518;border-color:#2b2e34;color:#a3a8b3}.wg b{color:#eceef2}}
    </style></head><body>
    <h1>Widget gallery</h1>
    <div class="grid">
    <div class="wg"><b>Needs you</b>Fix inventory sync retries</div>
    <div class="wg"><b>Working</b>2 agents</div>
    <div class="wg wide"><b>Needs you · Working</b>Fix inventory sync retries · 2 working</div>
    <div class="wg"><b>Done</b>4 today</div>
    <div class="wg"><b>Start a thread</b>Shortcuts intent</div>
    </div></body></html>
    """

    /// A made-up checkout page (iPadPaneBrowser's acme): the pay button says where it comes from, as a dev build's
    /// `data-source` does.
    static let checkout = """
    <!doctype html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Checkout</title>
    <style>
    body{font-family:-apple-system,sans-serif;margin:0;background:#f6f7f9;color:#14161a}
    header{display:flex;align-items:center;gap:8px;padding:12px 18px;background:#fff;border-bottom:1px solid #e3e5ea;font-weight:600}
    header i{width:20px;height:20px;border-radius:5px;background:#5b4ff0;display:inline-block}
    header span{margin-left:auto;font-weight:400;font-size:12px;color:#5b616e}
    main{padding:18px}
    h1{font-size:20px;margin:0 0 12px}
    label{display:block;font-size:12px;font-weight:600;margin:12px 0 6px}
    .field{background:#fff;border:1px solid #d9dce2;border-radius:8px;padding:10px 12px;font-size:13px}
    .summary{margin-top:14px;background:#fff;border:1px solid #e3e5ea;border-radius:10px;padding:10px 14px;font-size:13px}
    .row{display:flex;justify-content:space-between;padding:4px 0;color:#5b616e}
    .row.promo{color:#1f8a5b}.row.total{color:#14161a;font-weight:700;border-top:1px solid #e3e5ea;margin-top:4px;padding-top:8px}
    button.pay{margin-top:14px;width:240px;height:44px;border:0;border-radius:8px;background:#5b4ff0;color:#fff;font-size:14px;font-weight:600}
    </style></head><body>
    <header><i></i>acme<span>Secure checkout</span></header>
    <main>
    <h1>Checkout</h1>
    <label>Email</label><div class="field">pat@example.com</div>
    <label>Card</label><div class="field">4242 4242 4242 4242</div>
    <label>Promo code</label><div class="field">FALL24</div>
    <div class="summary">
    <div class="row"><span>Subtotal</span><span>$160.00</span></div>
    <div class="row promo"><span>Promo FALL24</span><span>−$12.00</span></div>
    <div class="row total"><span>Total</span><span>$148.00</span></div>
    </div>
    <button class="pay" data-source="src/components/Checkout.tsx:88">Pay $148.00</button>
    </main></body></html>
    """

    /// Picks the pay button the way a tap in Select does (the picker's `pickAt`), adds it to the draft, then picks it again
    /// so its popover stays open, as the board draws both.
    @MainActor static func pick(_ app: MobileApp, ref: AgentRef) async {
        app.navigator.padColumns = .detailOnly
        await FixtureCheck.wait("the checkout page loaded through the tunnel", seconds: 20) {
            guard let page = MobileBrowsers.shared.existing(ref) else { return false }
            return page.url != nil && !page.isLoading && page.webView?.url != nil
        }
        guard let page = MobileBrowsers.shared.existing(ref), let webView = page.webView else { FixtureCheck.fail("no page") }
        let tap = """
        const r = document.querySelector('button.pay').getBoundingClientRect();
        return window.__shepherdBrowser.pickAt(r.left + r.width / 2, r.top + r.height / 2);
        """
        for round in 0..<2 {
            page.setSelecting(true)
            _ = try? await webView.callAsyncJavaScript(tap, arguments: [:], in: nil, contentWorld: BrowserPage.world)
            await FixtureCheck.wait("the pay button picked", seconds: 10) { page.picked != nil && !page.selecting }
            if round == 0 {
                let store = app.threads.store(for: ref)
                if let element = page.picked { store.attach(element: element) }
                store.draft = "Make this full width on phones"
            }
        }
        await FixtureCheck.wait("the thread without its sidebar", seconds: 10) {
            if app.navigator.padColumns != .detailOnly { app.navigator.padColumns = .detailOnly }
            return splitView()?.displayMode == .secondaryOnly && splitView()?.transitionCoordinator == nil
        }
        let picked = page.picked
        let chips = app.threads.store(for: ref).attachedElements.map(\.element.label)
        let ok = picked?.label == "button.pay" && picked?.sourceShort == "Checkout.tsx:88" && picked?.width == 240 && chips == ["button.pay"]
        FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED"): button.pay picked (\(picked?.label ?? "nil") \(picked?.sourceShort ?? "nil")), chips \(chips)")
    }

    static let payments = """
    <!doctype html>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="light dark">
    <title>Refund overview</title>
    <style>
    body{margin:0;font:15px -apple-system,sans-serif;color:light-dark(#24282e,#e5e7eb);background:light-dark(#fbfbfa,#181b1c)}
    header,main{padding:20px 24px}header{border-bottom:1px solid light-dark(#e0e2e4,#333638);font-weight:600}
    h1{font-size:26px;margin:0 0 8px}p,small{color:light-dark(#5c626a,#a4aab2)}
    section{border:1px solid light-dark(#e0e2e4,#333638);border-radius:8px;padding:16px;margin:24px 0}
    strong{display:block;font-size:26px;margin:8px 0 12px}a{display:inline-block;border-radius:6px;background:#3570c1;color:white;padding:8px 12px;text-decoration:none}
    </style>
    <header>Acme payments</header>
    <main><h1></h1><p></p><section><small></small><strong></strong><a target="_blank" href="/?view=checkout">Open checkout</a></section></main>
    <script>
    const view = new URLSearchParams(location.search).get('view');
    const checkout = view === 'checkout';
    document.title = checkout ? 'Checkout' : view || 'Refund overview';
    document.querySelector('h1').textContent = document.title;
    document.querySelector('p').textContent = checkout ? 'Team plan · 5 seats · billed monthly.' : 'Track refunds and their ledger events.';
    document.querySelector('small').textContent = checkout ? 'Due today' : 'Refunded this month';
    document.querySelector('strong').textContent = checkout ? '$148.00' : '$12,480.00';
    setTimeout(() => {
        console.log('[dev] connected.');
        console.log(checkout ? 'GET /api/checkout 200' : 'GET /api/refunds 200');
        console.warn(checkout ? 'Checkout: test mode is on.' : 'Refund list: one transaction is pending.');
        console.log('GET /api/events 200');
    }, 100);
    </script>
    """

    enum TabState { case two, popup, full, fullMenu, close }

    @MainActor static func tabs(_ app: MobileApp, ref: AgentRef, state: TabState) async {
        app.navigator.padColumns = .detailOnly
        await FixtureCheck.wait("browser pane and real console output", seconds: 25) {
            guard let page = MobileBrowsers.shared.existing(ref) else { return false }
            return app.navigator.layout == .pad && page.allowsPopupTabs && page.title == "Refund overview"
                && page.console.warnings == 1 && page.console.network > 0
        }
        guard let tabs = MobileBrowsers.shared.existingTabs(ref), let root = tabs.selectedPage, let web = root.webView else {
            FixtureCheck.fail("no browser tab")
        }
        if state == .close {
            _ = try? await web.evaluateJavaScript("document.querySelector('a').port = '\(popupPort)'")
        }
        _ = try? await web.evaluateJavaScript("document.querySelector('a').click()")
        await FixtureCheck.wait("the popup opened in a separate tab with its own console", seconds: 15) {
            tabs.selection.ids.count == 2 && tabs.notice == .popup && tabs.selectedPage?.title == "Checkout"
                && tabs.selectedPage?.console.lines.contains { $0.text == "GET /api/checkout 200" } == true
        }
        guard let popup = tabs.selectedPage, popup.source == .link,
              root.console.lines.contains(where: { $0.text == "GET /api/refunds 200" }),
              !root.console.lines.contains(where: { $0.text == "GET /api/checkout 200" }) else {
            FixtureCheck.fail("the popup reused the opener's console")
        }
        switch state {
        case .two:
            tabs.select(root.id)
            guard tabs.notice == nil else { FixtureCheck.fail("popup note survived a tab switch") }
        case .popup:
            break
        case .close:
            await checkClosingTabs(tabs, root: root, popup: popup)
        case .full, .fullMenu:
            let otherTitles = ["Payouts", "Ledger", "Invoices", "Support", "Test transactions", "Staging refunds"]
            for title in otherTitles {
                guard let tab = tabs.add(), let url = URL(string: "http://localhost:\(port)/?view=" + title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!) else {
                    FixtureCheck.fail("could not fill browser tabs")
                }
                tab.open(url)
            }
            tabs.select(root.id)
            await FixtureCheck.wait("opener web view is visible again", seconds: 10) { web.window != nil }
            _ = try? await web.evaluateJavaScript("document.querySelector('a').click()")
            await FixtureCheck.wait("a full strip redirects the popup into the selected tab", seconds: 15) {
                tabs.selection.ids.count == 8 && tabs.notice == .cap && tabs.selectedPage === root
                    && root.title == "Checkout" && root.console.warnings == 1
            }
            await FixtureCheck.wait("every tab has its WebKit title", seconds: 15) {
                tabs.items.suffix(otherTitles.count).map(\.title) == otherTitles
            }
        }
        tabs.selectedPage?.consoleOpen = true
        await FixtureCheck.wait("browser pane without its sidebar", seconds: 10) {
            if app.navigator.padColumns != .detailOnly { app.navigator.padColumns = .detailOnly }
            return splitView()?.displayMode == .secondaryOnly && splitView()?.transitionCoordinator == nil
        }
        tabs.fixtureListOpen = state == .fullMenu
        FixtureCheck.report("FIXTURE CHECK ok browser tabs \(state), \(tabs.items.count) tabs")
    }

    @MainActor private static func checkClosingTabs(_ tabs: MobileBrowserTabs, root: BrowserPage, popup: BrowserPage) async {
        guard popup.url?.port == popupPort, tabs.ports.ports == [port, popupPort], let web = popup.webView else {
            FixtureCheck.fail("popup did not claim its own port")
        }
        tabs.close(root.id)
        guard tabs.items.map(\.id) == [popup.id], tabs.selectedPage === popup, root.webView == nil,
              tabs.ports.ports == [popupPort] else {
            FixtureCheck.fail("closing the opener did not keep only the popup and its port")
        }
        let ok = try? await web.callAsyncJavaScript("return (await fetch('/?after=close', { cache: 'no-store' })).ok",
                                                    arguments: [:], in: nil, contentWorld: .page) as? Bool
        guard ok == true else { FixtureCheck.fail("the popup's tunnel stopped serving after the opener closed") }

        await tabs.ports.forwarder.waitForClose(of: port)
        guard let sibling = tabs.add(), tabs.notice == nil,
              sibling.open(URL(string: "http://localhost:\(port)/")!) else {
            FixtureCheck.fail("could not open a sibling or clear the popup note on a new tab")
        }
        tabs.select(popup.id)
        tabs.closeOthers()
        guard tabs.items.map(\.id) == [popup.id], tabs.selectedPage === popup, popup.webView === web,
              sibling.webView == nil, tabs.ports.ports == [popupPort] else {
            FixtureCheck.fail("close others did not retain the selected page and release its sibling's port")
        }

        tabs.close(popup.id)
        guard let blank = tabs.selectedPage, blank.id != popup.id, blank.url == nil, tabs.items.map(\.id) == [blank.id],
              popup.webView == nil, tabs.ports.ports.isEmpty else {
            FixtureCheck.fail("closing the last tab did not leave a blank tab with no claims")
        }
        FixtureCheck.report("FIXTURE CHECK ok second-port popup survived opener close; closeOthers and last-tab close released their claims")
    }

    @MainActor static func splitView() -> UISplitViewController? {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow
        func find(_ controller: UIViewController?) -> UISplitViewController? {
            guard let controller else { return nil }
            if let split = controller as? UISplitViewController { return split }
            return controller.children.lazy.compactMap(find).first ?? find(controller.presentedViewController)
        }
        return find(window?.rootViewController)
    }
}
