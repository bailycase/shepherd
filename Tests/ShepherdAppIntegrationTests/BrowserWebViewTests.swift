import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
import WebKit
@testable import ShepherdApp

/// The Browser's page in a real, off-screen web view (docs/design/side-pane-changes.md › Side pane › Browser): the
/// console the page writes reaches the drawer, Select an element picks an element with its
/// selector and, when the page provides one, its source, and each thread's website data is its
/// own.
@MainActor
@Suite("Browser web view", .mainActorExclusive)
struct BrowserWebViewTests {
    /// A session showing `html` in an off-screen window, once its scripts are in.
    private func page(_ html: String, agent: AgentID = AgentID()) async throws -> (BrowserSession, OffscreenWindow) {
        let session = BrowserSession(agentID: agent, dataStores: .ephemeral)
        let encoded = Data(html.utf8).base64EncodedString()
        session.load(try #require(URL(string: "data:text/html;base64," + encoded)))
        let window = OffscreenWindow(size: CGSize(width: 800, height: 600), BrowserPageView(session: session).frame(width: 800, height: 600))
        try await eventuallyOnMain("the page to load") { session.hasPage && !session.isLoading && session.webView?.superview != nil }
        // Document-end scripts are in before the load finishes.
        let view = try #require(session.webView)
        let ready = try await view.callAsyncJavaScript("return !!window.__shepherdBrowser", arguments: [:], in: nil,
                                                       contentWorld: BrowserSession.world)
        #expect(ready as? Bool == true)
        return (session, window)
    }

    /// Clicks the element `selector` finds while Select an element is on.
    private func pick(_ selector: String, in session: BrowserSession) async throws {
        session.setSelecting(true)
        #expect(session.selecting)
        let view = try #require(session.webView)
        // Scripts run in the order they were sent: selecting is on before the click.
        _ = try await view.callAsyncJavaScript("document.querySelector(s).click()", arguments: ["s": selector], in: nil,
                                               contentWorld: BrowserSession.world)
        try await eventuallyOnMain("the pick to come back") { session.picked != nil }
    }

    @Test func theConsoleAndThePagesErrorsReachTheDrawer() async throws {
        let (session, window) = try await page("""
            <html><body><script>
              console.log('hello', { a: 1 });
              console.warn('careful');
              setTimeout(() => { throw new Error('boom'); }, 0);
            </script></body></html>
            """)
        defer { window.close() }
        try await eventuallyOnMain("three console lines") { session.console.lines.count >= 3 }
        let lines = session.console.lines
        #expect(lines.contains { $0.level == .log && $0.text == #"hello {"a":1}"# })
        #expect(lines.contains { $0.level == .warning && $0.text == "careful" })
        // The page's own error shows as a warning row too: no board draws a separate error count.
        #expect(lines.contains { $0.level == .warning && $0.text.contains("boom") })
        #expect(session.console.warnings == 2)
        try await eventuallyOnMain("the document counted") { session.console.network >= 1 }
    }

    @Test func aPickReportsItsSelectorLabelSizeAndMarkup() async throws {
        let (session, window) = try await page("""
            <html><body><main><form>
              <button class="pay primary" style="width: 240px; height: 44px">Pay $148.00</button>
              <button class="pay primary" style="width: 100px; height: 20px">Later</button>
            </form></main></body></html>
            """)
        defer { window.close() }
        try await pick("button:nth-of-type(2)", in: session)
        let element = try #require(session.picked)
        #expect(element.label == "button.pay")
        #expect(element.width == 100 && element.height == 20)
        #expect(element.source == nil, "no source unless the page provides one")
        #expect(element.html?.hasPrefix("<button class=\"pay primary\"") == true)
        #expect(!session.selecting, "picking ends selecting")
        let view = try #require(session.webView)
        let found = try await view.callAsyncJavaScript("return document.querySelectorAll(s).length === 1 && document.querySelector(s).textContent",
                                                       arguments: ["s": element.selector], in: nil, contentWorld: .page)
        #expect(found as? String == "Later", "the selector finds exactly that element: \(element.selector)")
    }

    /// A source comes from a data attribute, or from a React dev build's fiber, which only the
    /// page's own world can read.
    @Test func aPickCarriesTheSourceThePageProvides() async throws {
        let (session, window) = try await page("""
            <html><body>
              <div data-source="src/components/Checkout.tsx:88"><button id="pay">Pay</button></div>
              <button id="promo">Apply</button>
              <script>
                document.getElementById('promo')['__reactFiber$x1'] = { _debugSource: { fileName: 'src/Promo.tsx', lineNumber: 12 } };
              </script>
            </body></html>
            """)
        defer { window.close() }
        try await pick("#pay", in: session)
        #expect(session.picked?.source == "src/components/Checkout.tsx:88")
        #expect(session.picked?.selector == "#pay")
        try await pick("#promo", in: session)
        #expect(session.picked?.source == "src/Promo.tsx:12")
        let view = try #require(session.webView)
        let left = try await view.callAsyncJavaScript("return document.getElementById('promo').hasAttribute('data-shepherd-source')",
                                                      arguments: [:], in: nil, contentWorld: .page)
        #expect(left as? Bool == false, "the answer is taken off the page again")
    }

    /// The page can't see Shepherd's picker: its world is its own.
    @Test func thePageCannotReachThePicker() async throws {
        let (session, window) = try await page("<html><body><p>hi</p></body></html>")
        defer { window.close() }
        let view = try #require(session.webView)
        let seen = try await view.callAsyncJavaScript(
            "return [typeof window.__shepherdBrowser, typeof (window.webkit.messageHandlers.shepherdBrowser)]",
            arguments: [:], in: nil, contentWorld: .page)
        #expect(seen as? [String] == ["undefined", "undefined"])
    }

    @Test func eachThreadsWebsiteDataIsItsOwn() async throws {
        let a = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        let b = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        a.load(try #require(URL(string: "about:blank")))
        b.load(try #require(URL(string: "about:blank")))
        let storeA = try #require(a.webView?.configuration.websiteDataStore)
        let storeB = try #require(b.webView?.configuration.websiteDataStore)
        #expect(storeA !== storeB)
        let cookie = try #require(HTTPCookie(properties: [.domain: "localhost", .path: "/", .name: "session", .value: "a"]))
        await storeA.httpCookieStore.setCookie(cookie)
        #expect(await storeA.httpCookieStore.allCookies().map(\.name) == ["session"])
        #expect(await storeB.httpCookieStore.allCookies().isEmpty)
    }

    /// In the app each agent's store is on disk under an identifier of its own, and goes when the
    /// agent is deleted.
    ///
    /// On CI's macOS 26 runner this test process (no bundle identifier) died with SIGSEGV here,
    /// so it runs from macOS 27, where it passes; the app itself has an identifier.
    @Test(.enabled(if: ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)),
                   "identified website data stores crashed a bundle-less test process on macOS 26"))
    func anAgentsPersistentStoreIsItsOwnAndGoesWithIt() async throws {
        let first = AgentID(), second = AgentID(rawValue: "not-a-uuid")
        let idFirst = BrowserDataStores.identifier(for: first)
        let idSecond = BrowserDataStores.identifier(for: second)
        #expect(idFirst.uuidString.lowercased() == first.rawValue)
        #expect(idSecond == BrowserDataStores.identifier(for: AgentID(rawValue: "not-a-uuid")), "stable")
        #expect(idFirst != idSecond)

        let sessions = BrowserSessions(dataStores: .persistent)
        sessions.prune(live: [first, second])
        for agent in [first, second] { sessions.session(for: agent).load(try #require(URL(string: "about:blank"))) }
        try await Self.checkIsolation(sessions, first, second)
        #expect(Set(await WKWebsiteDataStore.allDataStoreIdentifiers).isSuperset(of: [idFirst, idSecond]))

        sessions.prune(live: [])
        #expect(sessions.existing(first) == nil && sessions.existing(second) == nil)
        let ids: Set<UUID> = [idFirst, idSecond]
        try await eventually("both stores removed") { @Sendable () async -> Bool in await Self.noneOf(ids) }
    }

    /// A cookie in the first agent's store is not in the second's; holds no store afterwards.
    private static func checkIsolation(_ sessions: BrowserSessions, _ first: AgentID, _ second: AgentID) async throws {
        let cookie = try #require(HTTPCookie(properties: [.domain: "localhost", .path: "/", .name: "first", .value: "1"]))
        let storeFirst = try #require(sessions.existing(first)?.webView?.configuration.websiteDataStore)
        await storeFirst.httpCookieStore.setCookie(cookie)
        #expect(await storeFirst.httpCookieStore.allCookies().map(\.name) == ["first"])
        let storeSecond = try #require(sessions.existing(second)?.webView?.configuration.websiteDataStore)
        #expect(await storeSecond.httpCookieStore.allCookies().isEmpty)
    }

    private nonisolated static func noneOf(_ ids: Set<UUID>) async -> Bool {
        await Set(WKWebsiteDataStore.allDataStoreIdentifiers).isDisjoint(with: ids)
    }
}
