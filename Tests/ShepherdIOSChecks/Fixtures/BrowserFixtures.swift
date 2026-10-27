import Foundation
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
        ]
    }
}

enum BrowserFixture {
    /// The dev server's port on the host, and the one forwarded on the device.
    static let port = 41_731
    static let title = "Widget gallery"

    static func hosts(running: Bool, capable: Bool = true) -> [FixtureHostData] {
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
        let server = Server(running: running)
        hosts[index].tunnel = { server.answer($0) }
        return hosts
    }

    /// A dev server that answers every GET of `/` with the gallery and anything else with a 404,
    /// one request per tunnel (`Connection: close`).
    final class Server: @unchecked Sendable {
        let running: Bool
        private let lock = NSLock()
        private var requests: [Int: Data] = [:]

        init(running: Bool) { self.running = running }

        func answer(_ frame: BrowserTunnelFrame) -> [BrowserTunnelFrame] {
            switch frame {
            case .open(let tunnel, _, let port):
                guard running, port == BrowserFixture.port else { return [.close(tunnel: tunnel, code: BrowserTunnelCode.refused)] }
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
                let body = Data((found ? BrowserFixture.html : "Not found").utf8)
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
}
