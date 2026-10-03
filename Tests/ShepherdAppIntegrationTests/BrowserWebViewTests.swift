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
/// selector and, when the page provides one, its source, and project-scoped saved website data.
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

    @Test func threadsWithoutAProjectKeepSeparateWebsiteData() async throws {
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

    @Test func projectCookieControlsUseThePagesStoreAndLeaveOtherWebsiteDataAlone() async throws {
        let web = try TinyWebServer(pages: BrowserAgentTests.pages)
        try await web.start()
        defer { web.stop() }
        let project = Fixture.space("project", path: "/projects/project")
        let other = Fixture.space("other", path: "/projects/other")
        let a = Fixture.agent("a", in: project), b = Fixture.agent("b", in: other)
        let sessions = BrowserSessions(dataStores: .ephemeral)
        sessions.prune(state: Fixture.state(spaces: [project, other], agents: [a, b]))
        #expect(await sessions.cookieSites(projectID: project.id).isEmpty)
        let page = sessions.session(for: a.agent.id), otherPage = sessions.session(for: b.agent.id)
        defer { page.close(); otherPage.close() }
        page.load(web.url("/terms"))
        otherPage.prepareWebView()
        try await eventuallyOnMain("the page to load") { page.hasPage && !page.isLoading }
        let view = try #require(page.webView)
        let cookies = view.configuration.websiteDataStore.httpCookieStore
        for (index, domain) in [".Example.test", "example.TEST", ".example.test", "alpha.test", ".alpha.test", "ALPHA.TEST", "zeta.test"].enumerated() {
            let cookie = try #require(HTTPCookie(properties: [.domain: domain, .path: "/", .name: "cookie\(index)", .value: "synthetic"]))
            await cookies.setCookie(cookie)
        }
        let otherCookie = try #require(HTTPCookie(properties: [.domain: "example.test", .path: "/", .name: "other", .value: "synthetic"]))
        let otherView = try #require(otherPage.webView)
        await otherView.configuration.websiteDataStore.httpCookieStore.setCookie(otherCookie)
        _ = try await view.callAsyncJavaScript("""
            localStorage.setItem('cart', 'one item');
            const cache = await caches.open('cart-cache');
            await cache.put('/cached', new Response('saved'));
            """, arguments: [:], in: nil, contentWorld: .page)
        #expect(await sessions.cookieSites(projectID: project.id) == [
            BrowserCookieSite(site: "alpha.test", count: 3), BrowserCookieSite(site: "example.test", count: 3),
            BrowserCookieSite(site: "zeta.test", count: 1),
        ])

        await sessions.clearCookies(projectID: project.id, site: ".EXAMPLE.TEST")
        // WebKit's readback can briefly lag its deletion callbacks.
        try await eventually("the site's cookies deleted") { @Sendable () async -> Bool in
            await sessions.cookieSites(projectID: project.id)
                == [BrowserCookieSite(site: "alpha.test", count: 3), BrowserCookieSite(site: "zeta.test", count: 1)]
        }
        await sessions.clearCookies(projectID: project.id)
        try await eventually("all project cookies deleted") { @Sendable () async -> Bool in
            await sessions.cookieSites(projectID: project.id).isEmpty
        }
        #expect(await sessions.cookieSites(projectID: other.id) == [BrowserCookieSite(site: "example.test", count: 1)])
        let kept = try await view.callAsyncJavaScript("""
            const cached = await (await caches.open('cart-cache')).match('/cached');
            return localStorage.getItem('cart') === 'one item' && (await cached.text()) === 'saved';
            """, arguments: [:], in: nil, contentWorld: .page)
        #expect(kept as? Bool == true, "clearing cookies keeps local storage and Cache Storage")
    }

    /// A project's logins outlive its last thread, but go when the project is removed.
    /// No page is loaded here: the persistent store test never parks a window on screen.
    @Test(.enabled(if: persistentTestsEnabled, "run scripts/test-browser-persistence.py on macOS 27+"))
    func savedLoginsSurviveDeletingTheLastThreadButNotItsProject() async throws {
        try Self.requireScratchHome()
        let first = Fixture.space("first", path: "/projects/first")
        let second = Fixture.space("second", path: "/projects/second")
        let a = Fixture.agent("a", in: first)
        let b = Fixture.agent("b", in: first, cwd: "/worktrees/first-b")
        let c = Fixture.agent("c", in: second)
        let ids: Set<UUID> = [BrowserDataStores.identifier(forProject: first.id), BrowserDataStores.identifier(forProject: second.id)]
        defer { for id in ids { BrowserDataStores.persistent.remove(identifier: id) } }
        let sessions = BrowserSessions(dataStores: .persistent)
        sessions.prune(state: Fixture.state(spaces: [first, second], agents: [a, b, c]))
        for agent in [a, b, c] { _ = sessions.session(for: agent.agent.id) }
        try await Self.savedCookie(project: first.id, write: true)
        #expect(await BrowserDataStores.persistent.store(identifier: BrowserDataStores.identifier(forProject: second.id))
            .httpCookieStore.allCookies().isEmpty)

        sessions.prune(state: Fixture.state(spaces: [first, second], agents: []))
        #expect(sessions.existing(a.agent.id) == nil && sessions.existing(b.agent.id) == nil)
        let newThread = Fixture.agent("new", in: first)
        sessions.prune(state: Fixture.state(spaces: [first, second], agents: [newThread]))
        _ = sessions.session(for: newThread.agent.id)
        try await Self.savedCookie(project: first.id, write: false)

        sessions.prune(state: ShepherdState())
        try await eventually("both projects' stores removed") { @Sendable () async -> Bool in await Self.noneOf(ids) }
    }

    @Test(.enabled(if: persistentTestsEnabled, "run scripts/test-browser-persistence.py on macOS 27+"))
    func aSavedProjectCookieSurvivesAProcessRestart() async throws {
        try Self.requireScratchHome()
        let project = SpaceID().rawValue
        let identifier = BrowserDataStores.identifier(forProject: SpaceID(rawValue: project))
        defer { BrowserDataStores.persistent.remove(identifier: identifier) }
        await #expect(processExitsWith: .success) { [project = project as String] in
            await recordingErrors { try await Self.savedCookie(project: SpaceID(rawValue: project), write: true) }
        }
        await #expect(processExitsWith: .success) { [project = project as String] in
            await recordingErrors {
                try await Self.savedCookie(project: SpaceID(rawValue: project), write: false)
                await BrowserSessions(dataStores: .persistent).clearCookies(projectID: SpaceID(rawValue: project))
                await MainActor.run {
                    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApplication.shared)
                }
            }
        }
        await #expect(processExitsWith: .success) { [project = project as String] in
            await recordingErrors {
                try Self.requireScratchHome()
                #expect(await BrowserSessions(dataStores: .persistent).cookieSites(projectID: SpaceID(rawValue: project)).isEmpty)
            }
        }
    }

    private nonisolated static var persistentTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["SHEPHERD_BROWSER_TEST_HOME"] != nil
            && ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }

    private nonisolated static func requireScratchHome() throws {
        let home = try #require(ProcessInfo.processInfo.environment["SHEPHERD_BROWSER_TEST_HOME"])
        let root = URL(fileURLWithPath: home).resolvingSymlinksInPath()
        try #require(FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath() == root)
        for directory in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
            let url = try FileManager.default.url(for: directory, in: .userDomainMask, appropriateFor: nil, create: false)
            try #require(url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
                         "WebKit's files must stay inside the scratch home")
        }
    }

    private static func savedCookie(project: SpaceID, write: Bool) async throws {
        try requireScratchHome()
        let store = BrowserDataStores.persistent.store(identifier: BrowserDataStores.identifier(forProject: project))
        #expect(store.isPersistent)
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral, websiteDataStore: store)
        defer { session.close() }
        if write {
            session.prepareWebView()
            let cookie = try #require(HTTPCookie(properties: [.domain: "localhost", .path: "/", .name: "signin",
                .value: project.rawValue, .expires: Date().addingTimeInterval(86_400)]))
            #expect(!cookie.isSessionOnly)
            await store.httpCookieStore.setCookie(cookie)
        }
        let cookies = await store.httpCookieStore.allCookies()
        #expect(cookies.map(\.name) == ["signin"])
        #expect(cookies.first?.value == project.rawValue)
        #expect(await BrowserSessions(dataStores: .persistent).cookieSites(projectID: project)
            == [BrowserCookieSite(site: "localhost", count: 1)])
    }

    private nonisolated static func noneOf(_ ids: Set<UUID>) async -> Bool {
        await Set(WKWebsiteDataStore.allDataStoreIdentifiers).isDisjoint(with: ids)
    }
}
