import AppKit
import Foundation
import Network
import ShepherdCore
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The Browser's tab chrome (BrowserTabs{Agent,Elsewhere,Full,Opened,Popup,Two}) through the real
/// model: a root `BrowserSession`, its `BrowserTabs`, real web views loading pages a loopback server
/// serves, and `BrowserPane`. A capture can't draw a web view, so the page area renders blank; what is
/// drawn is the chrome with the real titles, addresses and notice words. Every page is on this Mac's
/// loopback, so each tile is the loopback color: the other tile colors are in `browser-tabs-board-*`
/// (plain values, `NWBrowserTabsBoard`).
///
///     SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter PreviewTests/browserTabs
extension PreviewTests {
    private static let tabsPaneSize = CGSize(width: AppLayout.paneDefaultWidth, height: 700)

    /// A loopback server of titled pages. Never leaves the machine.
    private final class Pages: @unchecked Sendable {
        private let listener: NWListener
        private let titles: [String: String]
        private(set) var port: UInt16 = 0

        init(_ titles: [String: String]) throws {
            self.titles = titles
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }

        func start() async throws {
            listener.newConnectionHandler = { [titles] connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    let line = String(decoding: data ?? Data(), as: UTF8.self).split(separator: " ")
                    let path = line.count > 1 ? String(line[1]) : "/"
                    let body = Data("<html><head><title>\(titles[path] ?? "Not found")</title></head><body></body></html>".utf8)
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                listener.stateUpdateHandler = { [listener] state in
                    switch state {
                    case .ready: listener.stateUpdateHandler = nil; continuation.resume()
                    case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                    default: break
                    }
                }
                listener.start(queue: .global())
            }
            port = listener.port?.rawValue ?? 0
        }

        func stop() { listener.cancel() }
        func url(_ path: String) -> URL { URL(string: "http://localhost:\(port)\(path)")! }
    }

    private static let tabTitles = [
        "/refunds": "Refund overview", "/checkout": "Checkout", "/docs": "Refunds API · Stripe Docs",
        "/stripe": "Stripe · Test mode", "/staging": "Refund overview · staging", "/grafana": "Refunds · Grafana",
        "/long": "A very long page title that a site might really send, well past any tab",
    ]

    /// A root page and `others` more, each loaded and titled, in the order the board draws them.
    @MainActor
    private func realTabs(_ pages: Pages, _ others: [(path: String, source: BrowserTabSource)], select: Int? = nil,
                          root path: String = "/refunds") async throws -> BrowserSession {
        let root = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        func loaded(_ page: BrowserSession, _ path: String) async throws {
            page.load(pages.url(path))
            let title = try #require(Self.tabTitles[path])
            try await eventuallyOnMain("\(path) to load as \(title)") { !page.isLoading && page.tabTitle == title }
        }
        try await loaded(root, path)
        for (path, source) in others {
            let page = try #require(root.tabs.add(source: source, select: false))
            try await loaded(page, path)
        }
        // A background tab is unseen until looked at; the board's "Two" has none.
        for page in root.tabs.pages { page.tabUnseen = false }
        root.tabs.dismissNotice()
        if let select { root.tabs.select(root.tabs.pages[select].tabID) }
        return root
    }

    @MainActor
    private func renderTabs(_ name: String, _ workspace: PreviewWorkspace, _ root: BrowserSession, listOpen: Bool = false) async throws {
        try await Preview.renderMatrix("browser-tabs-\(name)", size: Self.tabsPaneSize) {
            VStack(spacing: 0) {
                NWSidePaneTabs(SidePaneTabs.items(news: [], changedFiles: 2), selection: SidePaneTab.browser.rawValue, select: { _ in },
                               closeShortcut: "⇧⌘B", close: {}) { Button("Reset Width") {} }
                BrowserPane(vm: workspace.vm, session: root, store: NativeThreadStore(), active: false, listOpen: listOpen)
            }
            .background(Color.nw.bgWindow)
            .frame(width: Self.tabsPaneSize.width, height: Self.tabsPaneSize.height)
        }
    }

    @Test(.enabled(if: Preview.enabled)) @MainActor func browserTabsReal() async throws {
        let pages = try Pages(Self.tabTitles)
        try await pages.start()
        defer { pages.stop() }
        let workspace = try PreviewWorkspace()

        // Board 86: two tabs, the second opened by the agent.
        let two = try await realTabs(pages, [("/checkout", .agent)])
        defer { two.close() }
        try await renderTabs("two", workspace, two)

        // Board 83: eight tabs, the list open, and the cap's note (a link with no room).
        let full = try await realTabs(pages, [("/checkout", .agent), ("/docs", .agent), ("/stripe", .user), ("/staging", .agent),
                                              ("/grafana", .user), ("/docs", .link), ("/checkout", .user)], select: 7)
        defer { full.close() }
        #expect(full.tabs.pages.count == BrowserTabs.maxTabs && !full.tabs.canAdd)
        full.tabs.notice = .cap
        try await renderTabs("full", workspace, full, listOpen: true)

        // Board 84: the agent opened a tab in the background: the dot and the note with Show it.
        let opened = try await realTabs(pages, [])
        defer { opened.close() }
        let staged = try #require(opened.tabs.add(source: .agent, select: false))
        staged.load(pages.url("/staging"))
        try await eventuallyOnMain("the staging tab") { !staged.isLoading && staged.tabTitle == "Refund overview · staging" }
        try await renderTabs("opened", workspace, opened)

        // Board 85: a link opened a window.
        let popup = try await realTabs(pages, [("/stripe", .link)], select: 1)
        defer { popup.close() }
        popup.tabs.notice = .popup
        try await renderTabs("popup", workspace, popup)

        // Board 81: the agent is using the page that is shown.
        let agent = try await realTabs(pages, [("/checkout", .agent), ("/docs", .agent)], select: 1)
        defer { agent.close() }
        agent.tabs.selectedPage.agentBegan(note: "filling the checkout form")
        agent.tabs.selectedPage.agentPointed(at: CGPoint(x: 316, y: 380))
        try await renderTabs("agent", workspace, agent)

        // Board 82: the agent is in a tab that is not shown.
        let elsewhere = try await realTabs(pages, [("/checkout", .agent), ("/docs", .agent)])
        defer { elsewhere.close() }
        elsewhere.tabs.pages[1].agentBegan(note: "filling the checkout form")
        try await renderTabs("elsewhere", workspace, elsewhere)

        // Not drawn by a board: a long title, and a new tab with no page yet.
        let long = try await realTabs(pages, [], root: "/long")
        defer { long.close() }
        try await renderTabs("long", workspace, long)
        let blank = try await realTabs(pages, [])
        defer { blank.close() }
        blank.tabs.newTab()
        try await renderTabs("new", workspace, blank)
    }

    /// The same chrome from plain values: the board's tile colors, which no real page on loopback can show.
    @Test(.enabled(if: Preview.enabled), arguments: [
        ("two", NWBrowserTabsBoard.Scene.two), ("full", .full), ("opened", .opened), ("popup", .popup),
        ("agent", .agent), ("elsewhere", .elsewhere), ("single", .single),
    ])
    @MainActor func browserTabsBoard(name: String, scene: NWBrowserTabsBoard.Scene) async throws {
        try await Preview.renderMatrix("browser-tabs-board-\(name)", size: CGSize(width: NWBrowserTabsBoard.paneWidth, height: 560)) {
            NWBrowserTabsBoard(scene)
        }
    }
}
