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
            DevServer(script: "dev", command: "pnpm dev", packageName: "acme-web", directory: root, manifest: "package.json", port: 5173),
            DevServer(script: "preview", command: "pnpm preview", packageName: "acme-web", directory: root, manifest: "package.json", port: 4173),
        ]
        let store = NativeThreadStore()
        try await Preview.render("browser-empty", size: Self.paneSize) {
            browserPane(workspace, session, store: store)
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

    /// Picked elements in the thread (PaneBrowser's composer): one sent with a message, one
    /// waiting in the queue, and one in the composer beside a draft.
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
