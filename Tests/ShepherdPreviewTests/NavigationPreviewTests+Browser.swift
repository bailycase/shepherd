import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The side pane's Browser (PaneBrowser, PaneStates › Browser) and the element chips it puts in
/// the thread. A capture can't draw a web view, so the page itself renders blank: these check
/// the chrome around it.
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter PreviewTests/browser
extension PreviewTests {
    private static let paneSize = CGSize(width: AppLayout.paneDefaultWidth, height: 760)

    static let pay = BrowserElement(page: "http://localhost:5173/checkout", selector: "main > form > button.pay", label: "button.pay",
                                    source: "src/components/Checkout.tsx:88", width: 240, height: 44,
                                    html: "<button class=\"pay\">Pay $148.00</button>")

    /// The pane as the workspace draws it: the tab strip on Browser, then the tab.
    private func browserPane(_ workspace: PreviewWorkspace, _ session: BrowserSession, store: NativeThreadStore) -> some View {
        VStack(spacing: 0) {
            NWSidePaneTabs(SidePaneTabs.items(news: [], changedFiles: 2), selection: SidePaneTab.browser.rawValue, select: { _ in },
                           closeShortcut: "⇧⌘B", close: {}) {
                Button("Reset Width") {}
            }
            BrowserPane(vm: workspace.vm, session: session, store: store, active: false)
        }
        .background(Color.nw.bgWindow)
        // The pane's size, as `RightPaneSplit` gives it.
        .frame(width: Self.paneSize.width, height: Self.paneSize.height)
    }

    /// Nothing open (PaneStates › BrowserPane · nothing open): the dev servers the repository
    /// offers, and Open a URL with its keycaps.
    @Test func browserEmpty() async throws {
        let workspace = try PreviewWorkspace()
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        let root = URL(fileURLWithPath: "/repo")
        session.devServers = [
            DevServer(script: "dev", command: "pnpm dev", packageName: "acme-web", directory: root.path, manifest: "package.json", port: 5173),
            DevServer(script: "preview", command: "pnpm preview", packageName: "acme-web", directory: root.path, manifest: "package.json", port: 4173),
        ]
        let store = NativeThreadStore()
        try await Preview.render("browser-empty", size: Self.paneSize) {
            browserPane(workspace, session, store: store)
        }
    }

    /// A remote thread's page: a session whose host is "build-01", drawn without forwarding anything.
    private func remoteBrowser() throws -> BrowserSession {
        let hosts = RemoteHostStore(defaults: ScratchDefaults(), connects: false)
        hosts.addHost(name: "build-01", host: "build-01.local", port: 7433, token: "token")
        let ref = RemoteAgentRef(hostID: try #require(hosts.connections.first).id, agentID: AgentID())
        let remote = BrowserRemote(ref: ref, hosts: hosts, ports: BrowserPortForwarder())
        remote.forwardsPorts = false
        let session = BrowserSession(agentID: ref.agentID, dataStores: .ephemeral, remote: remote)
        // Kept alive with the session, which only holds the store weakly.
        Self.remoteHostStores.append(hosts)
        return session
    }

    nonisolated(unsafe) private static var remoteHostStores: [RemoteHostStore] = []

    /// A remote thread's Nothing open (PaneStates › BrowserPane · nothing open): the host chip names
    /// the host, and Start says "Start on build-01".
    @Test func browserRemoteEmpty() async throws {
        let workspace = try PreviewWorkspace()
        let session = try remoteBrowser()
        session.devServers = [
            DevServer(script: "dev", command: "pnpm dev", packageName: "acme-web", directory: "/host/acme-web", manifest: "package.json", port: 5173),
        ]
        try await Preview.render("browser-remote-empty", size: Self.paneSize) {
            browserPane(workspace, session, store: NativeThreadStore())
        }
    }

    /// A remote thread's page open (PaneStates › BrowserPane): `localhost:5173/checkout` with the
    /// host chip "build-01" and its console, as the board draws it (the page is a web view a capture
    /// can't draw, so it renders blank).
    @Test func browserRemotePage() async throws {
        let workspace = try PreviewWorkspace()
        let session = try remoteBrowser()
        session.load(try #require(URL(string: "http://localhost:5173/checkout")))
        // Nothing listens at 5173 here, so the load fails: what the console shows is the board's instead,
        // once the failed load is over (a new document starts it over).
        final class Seeded { var done = false }
        let seeded = Seeded()
        try await Preview.render("browser-remote-page", size: Self.paneSize, ready: {
            guard !session.isLoading else { return false }
            if !seeded.done {
                seeded.done = true
                session.console.clear()
                for (level, text) in [(NWConsoleLevel.log, "[vite] hmr update /src/components/Checkout.tsx"),
                                      (.log, "[vite] hmr update /src/components/PromoField.tsx"),
                                      (.warning, "Each child in a list should have a unique \"key\" prop.  PromoList.tsx:12")] {
                    session.console.append(level, text, at: Date(timeIntervalSince1970: 1_790_280_131))
                }
                session.console.setNetwork(24)
            }
            return true
        }) {
            browserPane(workspace, session, store: NativeThreadStore())
        }
    }

    /// A remote thread's page waiting for the dev server Start ran, and one whose port is in use on
    /// this Mac, with the reason floating under the toolbar.
    @Test func browserRemoteWaitingAndRefused() async throws {
        let workspace = try PreviewWorkspace()
        let waiting = try remoteBrowser()
        waiting.devServers = []
        waiting.wait(for: DevServer(script: "dev", command: "pnpm dev", packageName: nil, directory: "/host/acme-web",
                                    manifest: "package.json", port: 5173))
        try await Preview.render("browser-remote-waiting", size: Self.paneSize) {
            browserPane(workspace, waiting, store: NativeThreadStore())
        }
        waiting.stopWaiting()

        let refused = try remoteBrowser()
        refused.devServers = []
        refused.notice = BrowserNotice(message: "Port 5173 is in use on this Mac, so build-01’s 5173 can’t be forwarded. Stop what is using it and try again.")
        try await Preview.render("browser-remote-refused", size: Self.paneSize) {
            browserPane(workspace, refused, store: NativeThreadStore())
        }
    }

    /// The agent on the host driving a remote thread's page (docs/browser.md › Remote › The agent drives
    /// the page you see): the same ring, pointer and card with Take over over the viewer's own page,
    /// with the host's name in the address field. The page is a web view a capture can't draw.
    @Test func browserRemoteAgentIsUsingIt() async throws {
        let workspace = try PreviewWorkspace()
        let session = try remoteBrowser()
        session.load(try #require(URL(string: "http://localhost:5173/checkout")))
        session.consoleOpen = false
        final class Pointed { var done = false }
        let pointed = Pointed()
        try await Preview.render("browser-remote-agent-using-it", size: Self.paneSize, ready: {
            guard !session.isLoading else { return false }
            if !pointed.done {
                pointed.done = true
                session.agentBegan(note: "clicking through checkout")
                session.agentPointed(at: CGPoint(x: 316, y: 380))
                return false
            }
            return session.agentOverlay?.pointer != nil
        }) {
            browserPane(workspace, session, store: NativeThreadStore())
        }
    }

    /// The agent opened a page on the host while the viewer's Browser tab was out of sight (PaneStates
    /// › SidePaneTabs · the agent opened a tab, on a remote thread): the tab's dot and its brief tip.
    @Test func browserRemoteAgentOpenedATab() async throws {
        let session = try remoteBrowser()
        session.noteAgentOpened(try #require(URL(string: "http://localhost:5173/checkout")))
        let tip = try #require(SidePaneTabs.tip(opened: session.openedByAgent))
        try await Preview.render("browser-remote-agent-opened-tab", size: CGSize(width: 600, height: 150)) {
            VStack(spacing: 0) {
                NWSidePaneTabs(SidePaneTabs.items(news: [.browser], changedFiles: 2, browserTip: tip), selection: SidePaneTab.changes.rawValue,
                               select: { _ in }, closeShortcut: "⇧⌘B", close: {}) {
                    Button("Reset Width") {}
                }
                Spacer(minLength: 0)
            }
            .background(Color.nw.bgWindow)
        }
    }

    /// Another Mac claimed the agent's browser after this one: the notice under the toolbar says so.
    @Test func browserRemoteSuperseded() async throws {
        let workspace = try PreviewWorkspace()
        let session = try remoteBrowser()
        session.devServers = []
        session.notice = BrowserNotice(message: BrowserRemote.supersededMessage)
        try await Preview.render("browser-remote-superseded", size: Self.paneSize) {
            browserPane(workspace, session, store: NativeThreadStore())
        }
    }

    /// A page open at iPhone 16's width in its frame, an element picked (the outline and tag
    /// are the page's; the popover is Shepherd's), and the console with a warning and an error.
    @Test func browserPage() async throws {
        let workspace = try PreviewWorkspace()
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        session.load(try #require(URL(string: "about:blank#checkout")))
        session.viewport = .phone
        let store = NativeThreadStore()
        // What the page reports lands once its document is in (a new document starts them over).
        final class Seeded { var done = false }
        let seeded = Seeded()
        try await Preview.render("browser-page", size: Self.paneSize, ready: {
            guard !session.isLoading, session.console.network > 0 else { return false }
            if !seeded.done {
                seeded.done = true
                session.handle(.pick(Self.pay, rect: CGRect(x: 76, y: 380, width: 240, height: 44)))
                for (level, text) in [(NWConsoleLevel.log, "[vite] connected."), (.log, "[vite] hmr update /src/components/Checkout.tsx"),
                                      (.log, "[vite] hmr update /src/components/PromoField.tsx"),
                                      (.warning, "Each child in a list should have a unique \"key\" prop.  PromoList.tsx:12"),
                                      (.error, "TypeError: cart.items is undefined  Summary.tsx:31")] {
                    session.console.append(level, text, at: Date(timeIntervalSince1970: 1_790_280_131))
                }
                session.console.setNetwork(24)
            }
            return true
        }) {
            browserPane(workspace, session, store: store)
        }
    }

    /// The viewport menu open over a page at Laptop's width, shrunk to fit the pane, in the dark
    /// appearance; the console hidden.
    @Test func browserViewportMenu() async throws {
        let workspace = try PreviewWorkspace()
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        session.load(try #require(URL(string: "about:blank#cart")))
        session.viewport = .laptop
        session.dark = true
        session.consoleOpen = false
        session.menuOpen = true
        let store = NativeThreadStore()
        try await Preview.render("browser-viewport-menu", size: Self.paneSize) {
            browserPane(workspace, session, store: store)
        }
    }

    /// The agent using the page (PaneStates › BrowserPane · the agent is using it): the 2pt ring
    /// inset the page, the pointer where the last click landed, and the card under the toolbar
    /// with Take over. The page is a web view a capture can't draw, so it renders blank.
    @Test func browserAgentIsUsingIt() async throws {
        let workspace = try PreviewWorkspace()
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        session.load(try #require(URL(string: "about:blank#checkout")))
        session.consoleOpen = false
        let store = NativeThreadStore()
        // A new document takes the pointer away, so the agent points once the page is in.
        final class Pointed { var done = false }
        let pointed = Pointed()
        try await Preview.render("browser-agent-using-it", size: Self.paneSize, ready: {
            guard !session.isLoading, session.console.network > 0 else { return false }
            if !pointed.done {
                pointed.done = true
                session.agentBegan(note: "clicking through checkout")
                session.agentPointed(at: CGPoint(x: 316, y: 380))
                return false
            }
            return session.agentOverlay?.pointer != nil
        }) {
            browserPane(workspace, session, store: store)
        }
    }

    /// The same at a phone's width in its frame, where the pointer follows the page's zoom, and a
    /// long note truncating in the card.
    @Test func browserAgentIsUsingItAtAPhonesWidth() async throws {
        let workspace = try PreviewWorkspace()
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        session.load(try #require(URL(string: "about:blank#cart")))
        session.viewport = .phone
        session.consoleOpen = false
        let store = NativeThreadStore()
        final class Pointed { var done = false }
        let pointed = Pointed()
        try await Preview.render("browser-agent-using-it-phone", size: Self.paneSize, ready: {
            guard !session.isLoading, session.console.network > 0 else { return false }
            if !pointed.done {
                pointed.done = true
                session.agentBegan(note: "typing in “Card number” and checking that every field on the page took its value")
                session.agentPointed(at: CGPoint(x: 120, y: 300))
                return false
            }
            return session.agentOverlay?.pointer != nil
        }) {
            browserPane(workspace, session, store: store)
        }
    }

    /// pi opened a page while the pane was on another tab (PaneStates › SidePaneTabs · the agent
    /// opened a tab): the Browser tab takes its dot and a brief tip hangs under it; and the header's
    /// button, with the pane closed, says the same.
    @Test func browserAgentOpenedATab() async throws {
        let tip = NWSidePaneTabTip(text: "localhost:5173/checkout", openedAt: Date().addingTimeInterval(-10))
        try await Preview.render("browser-agent-opened-tab", size: CGSize(width: 600, height: 150)) {
            VStack(spacing: 0) {
                NWSidePaneTabs(SidePaneTabs.items(news: [.browser], changedFiles: 2, browserTip: tip), selection: SidePaneTab.changes.rawValue,
                               select: { _ in }, closeShortcut: "⇧⌘B", close: {}) {
                    Button("Reset Width") {}
                }
                Spacer(minLength: 0)
            }
            .background(Color.nw.bgWindow)
        }
        try await Preview.render("browser-agent-opened-button", size: CGSize(width: 420, height: 110)) {
            HStack {
                Spacer()
                NWPaneNewsTip(SidePaneTab.browser.newsText, shortcut: "⇧⌘B")
            }
            .padding(NW.Space.xl)
            .background(Color.nw.bgWindow)
        }
    }

    /// Picked elements: no board draws one as a chip on a sent bubble (the user's decision,
    /// 2026-09-29), so a sent message's element goes with it unseen and only its words show; one
    /// still waits in the queue as a chip, and one sits in the composer beside a draft.
    @Test func browserElementChips() async throws {
        var snapshot = QueueThreads.running
        snapshot.supportedActions.append("browserElements")
        snapshot.messages.append(NativeThreadMessage(entryID: "user:elements", role: "user",
                                                     blocks: [NativeThreadBlock(kind: .text, text: "Why does this jump when the promo opens?")],
                                                     timestamp: 1_790_280_100_000, browserElements: [Self.pay.withoutHTML]))
        let promo = BrowserElement(page: "http://localhost:5173/checkout", selector: "#promo", label: "input#promo", width: 320, height: 36)
        let queued = NativeQueuedMessage(id: UUID(), text: "And keep this field above the summary", sentAt: 1_790_280_200_000,
                                         elements: [promo])
        let fixture = QueueThreadFixture(snapshot, queue: [queued], draft: "Make this full width below 480px")
        fixture.store.attach(element: Self.pay)
        defer { fixture.store.stop() }
        try await Preview.render("browser-element-chips", size: CGSize(width: 1180, height: 900), ready: {
            fixture.store.ready && fixture.state.rows.count == 1
        }) {
            fixture.thread(title: "Fix pay button jump")
        }
    }
}
