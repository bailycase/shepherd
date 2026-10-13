import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Browser tab behavior", .mainActorExclusive, .integrationTimeLimit)
@MainActor
struct BrowserTabsTests {
    private func result(_ outcome: BrowserOutcome) throws -> String {
        guard case .result(let text, _) = outcome else { throw TabFailure(outcome: outcome) }
        return text
    }
    private struct TabFailure: Error { let outcome: BrowserOutcome }
    private func code(_ outcome: BrowserOutcome) -> String? {
        if case .failure(let code, _) = outcome { return code }
        return nil
    }

    @Test func theAgentKeepsItsTargetWhileTheUserBrowsesAnotherTab() async throws {
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        defer { session.close() }
        _ = try result(await session.perform(.open(url: "about:blank", note: nil)))
        _ = try result(await session.perform(.eval(expression: "document.body.innerHTML='<button onclick=\"document.title=123\">Agent button</button>'; document.title='Agent page'", note: nil)))
        let userPage = try #require(session.tabs.newTab())
        #expect(userPage.load(try #require(URL(string: "about:blank"))))
        try await eventuallyOnMain("the user's page") { userPage.loadState == .finished }
        let snapshot = try result(await session.perform(.read(selector: nil, maxChars: nil)))
        #expect(snapshot.contains("Agent button"))
        #expect(session.tabs.selectedPage === userPage)
        #expect(session.tabs.agentPage === session)
        #expect(userPage.agentOverlay == nil)
        _ = try result(await session.perform(.click(ref: "e1", double: false, note: nil)))
        #expect(session.pageTitle == "123")
        #expect(userPage.pageTitle != "123")
        _ = try result(await session.perform(.tab(id: userPage.tabID.uuidString, request: .eval(expression: "document.title='User page'", note: nil))))
        #expect(userPage.pageTitle == "User page")
        #expect(session.pageTitle == "123")
        userPage.takeOver()
        #expect(code(await session.perform(.eval(expression: "document.title='wrong'", note: nil))) == "taken_over")
        session.handBack()
        _ = try result(await session.perform(.eval(expression: "document.title='Handed back'", note: nil)))
        #expect(userPage.pageTitle == "Handed back")
    }

    @Test func agentTabsOpenInTheBackgroundAndEightIsTheBound() async throws {
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        defer { session.close() }
        let original = session.tabs.selectedPage.tabID
        for _ in 1..<8 { _ = try result(await session.perform(.newTab(url: nil, note: nil))) }
        #expect(session.tabs.pages.count == 8)
        #expect(session.tabs.selectedPage.tabID == original)
        #expect(session.tabs.pages.last?.tabUnseen == true)
        #expect(code(await session.perform(.newTab(url: nil, note: nil))) == "too_many_tabs")
        #expect(session.tabs.pages.count == 8)
        #expect(session.tabs.notice == .cap)
        let opened = try #require(session.tabs.openedPage)
        session.tabs.showOpenedPage()
        #expect(session.tabs.selectedPage === opened)
        #expect(!opened.tabUnseen)
        #expect(session.tabs.openedPage == nil)
        let listing = try result(await session.perform(.tabs))
        #expect(listing.hasPrefix(BrowserReport.notice))
        #expect(listing.contains(opened.tabID.uuidString))
        session.tabs.closeOthers()
        #expect(session.tabs.pages.count == 1)
        session.tabs.close(opened.tabID)
        #expect(session.tabs.pages.count == 1)
        #expect(!session.tabs.selectedPage.hasPage)
        #expect(code(await session.perform(.open(url: "about:blank", note: nil))) == "no_tab")
        _ = try result(await session.perform(.newTab(url: "about:blank", note: nil)))
    }

    @Test func newTabsShareSpaceCookiesButKeepIndependentHistoryAndConsole() async throws {
        let server = try TinyWebServer(pages: [
            "/one": "<title>One</title><script>document.cookie='tab=shared; path=/';console.log('first')</script>",
            "/two": "<title>Two</title><script>console.log('second')</script>",
        ])
        try await server.start()
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        defer { session.close(); server.stop() }
        _ = try result(await session.perform(.open(url: server.url("/one").absoluteString, note: nil)))
        _ = try result(await session.perform(.newTab(url: server.url("/two").absoluteString, note: nil)))
        let second = try #require(session.tabs.agentTarget)
        let cookies = try result(await session.perform(.eval(expression: "document.cookie", note: nil)))
        #expect(cookies.contains("tab=shared"))
        #expect(session.pageTitle == "One")
        #expect(second.pageTitle == "Two")
        #expect(!second.canGoBack)
        #expect(session.console.entries.contains { $0.text == "first" })
        #expect(!session.console.entries.contains { $0.text == "second" })
        #expect(second.console.entries.contains { $0.text == "second" })
    }

    @Test func aNewWindowBecomesATabAndFallsBackAtTheBound() async throws {
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        defer { session.close() }
        _ = try result(await session.perform(.open(url: "about:blank", note: nil)))
        _ = try result(await session.perform(.eval(expression: "window.open('about:blank') !== null", note: nil)))
        try await eventuallyOnMain("a popup tab") { session.tabs.pages.count == 2 }
        #expect(session.tabs.notice == .popup)
        #expect(session.tabs.selectedPage === session)
        #expect(session.tabs.pages.last?.tabSource == .link)
        for _ in 2..<8 { _ = try #require(session.tabs.newTab()) }
        let outcome = await session.perform(.eval(expression: "window.open('about:blank')", note: nil))
        _ = try result(outcome)
        #expect(session.tabs.pages.count == 8)
        #expect(session.tabs.notice == .cap)
    }

    @Test func theFirstAgentNavigationDoesNotReplaceAUserOpenedPage() async throws {
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        defer { session.close() }
        session.load(try #require(URL(string: "data:text/html,<title>User page</title>")))
        try await eventuallyOnMain("the user page") { session.pageTitle == "User page" }
        _ = try result(await session.perform(.open(url: "about:blank", note: nil)))
        #expect(session.tabs.pages.count == 2)
        #expect(session.tabs.selectedPage === session)
        #expect(session.pageTitle == "User page")
        #expect(session.tabs.agentTarget !== session)
    }

    @Test func cleanupAfterClosingTheRootKeepsAMountedPaneReadable() {
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        session.tabs.close(session.tabID)
        session.close()
        #expect(session.tabs.pages.isEmpty)
        #expect(session.tabs.selectedPage === session)
        #expect(!session.tabs.selectedPage.hasPage)
        #expect(!session.tabs.canAdd)
        #expect(session.tabs.newTab() == nil)
        #expect(session.tabs.pages.isEmpty)
    }

    @Test func closingAnAgentTabNeverRetargetsToTheUsersPage() async throws {
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        defer { session.close() }
        let user = try #require(session.tabs.newTab())
        session.tabs.close(session.tabID)
        #expect(session.tabs.selectedPage === user)
        #expect(code(await session.perform(.read(selector: nil, maxChars: nil))) == "no_tab")
        #expect(code(await session.perform(.tab(id: session.tabID.uuidString, request: .read(selector: nil, maxChars: nil)))) == "no_tab")
        _ = try result(await session.perform(.selectTab(id: user.tabID.uuidString)))
        #expect(session.tabs.agentTarget === user)
        user.takeOver()
        #expect(code(await session.perform(.closeTab(id: user.tabID.uuidString))) == "taken_over")
        #expect(session.tabs.pages.count == 1)
    }

    @Test func stoppingCancelsQueuedRequestsAcrossTabsAndClosingCannotResurrectAPage() async throws {
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        defer { session.close() }
        _ = try result(await session.perform(.open(url: "about:blank", note: nil)))
        _ = try result(await session.perform(.newTab(url: "about:blank", note: nil)))
        let active = try #require(session.tabs.agentTarget)
        let waiting = Task { await session.perform(.wait(text: "never", ref: nil, gone: false, ms: nil, timeout: 20)) }
        try await eventuallyOnMain("wait active") { active.presence.inFlight > 0 && active.agentOverlay?.note.contains("never") == true }
        let before = session.tabs.operationTail
        let queued = Task { await session.perform(.tab(id: session.tabID.uuidString,
            request: .eval(expression: "document.title='Must not run'", note: nil))) }
        try await eventuallyOnMain("cross-tab action queued") { session.tabs.operationTail != before }
        session.abandonQueued()
        #expect(code(await waiting.value) == "cancelled")
        #expect(code(await queued.value) == "cancelled")
        #expect(session.pageTitle != "Must not run")
        let again = Task { await session.perform(.wait(text: "never", ref: nil, gone: false, ms: nil, timeout: 20)) }
        try await eventuallyOnMain("wait active again") { active.presence.inFlight > 0 && active.agentOverlay?.note.contains("never") == true }
        session.tabs.close(active.tabID)
        let closed = await again.value
        #expect(code(closed) == "cancelled", "\(closed)")
        #expect(active.webView == nil)
        #expect(!session.tabs.pages.contains { $0 === active })
    }

    @Test func aTabListReportsOnlyMetadataValidatedBeforeDNSWaits() async throws {
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        defer { session.close() }
        session.load(try #require(URL(string: "about:blank")))
        try await eventuallyOnMain("blank page loaded") { session.loadState == .finished }
        let view = try #require(session.webView)
        view.loadHTMLString("<title>Public page</title>", baseURL: try #require(URL(string: "https://public.example/")))
        try await eventuallyOnMain("public page loaded") { session.pageTitle == "Public page" && !session.isLoading }
        let pending = Locked<CheckedContinuation<[String]?, Never>?>(nil)
        defer { pending.withValue { $0?.resume(returning: nil); $0 = nil } }
        let policy = BrowserViewerPolicy(resolver: { _ in
            await withCheckedContinuation { continuation in pending.withValue { $0 = continuation } }
        }, localAddresses: { [] })
        let listing = Task { await session.performFromHost(.tabs, policy: policy) }
        try await eventuallyOnMain("tab-list DNS to wait") { pending.current != nil }
        session.load(try #require(URL(string: "data:text/html,<title>Private secret</title>secret")))
        try await eventuallyOnMain("private page loaded during DNS") { session.pageTitle == "Private secret" }
        pending.withValue { $0?.resume(returning: ["93.184.216.34"]); $0 = nil }
        let text = try result(await listing.value)
        #expect(text.contains("Public page"))
        #expect(text.contains("https://public.example/"))
        #expect(!text.contains("Private secret"))
        #expect(!text.contains("data:"))
    }

    @Test func aRemoteScriptNeverRunsOnAPrivatePageOpenedDuringDNSValidation() async throws {
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        defer { session.close() }
        session.load(try #require(URL(string: "about:blank")))
        try await eventuallyOnMain("blank page") { session.loadState == .finished }
        let view = try #require(session.webView)
        view.loadHTMLString("<title>Public page</title>", baseURL: try #require(URL(string: "https://public.example/")))
        try await eventuallyOnMain("public page") { session.pageTitle == "Public page" && !session.isLoading }
        let pending = Locked<CheckedContinuation<[String]?, Never>?>(nil)
        defer { pending.withValue { $0?.resume(returning: nil); $0 = nil } }
        let policy = BrowserViewerPolicy(resolver: { _ in
            await withCheckedContinuation { continuation in pending.withValue { $0 = continuation } }
        }, localAddresses: { [] })
        let action = Task { await session.performFromHost(.eval(
            expression: "document.body.dataset.executed='yes'; throw new Error(document.title)", note: nil), policy: policy) }
        try await eventuallyOnMain("script DNS to wait") { pending.current != nil }
        session.load(try #require(URL(string: "data:text/html,<title>Private secret</title><body>private</body>")))
        try await eventuallyOnMain("private page") { session.pageTitle == "Private secret" }
        pending.withValue { $0?.resume(returning: ["93.184.216.34"]); $0 = nil }
        let denied = await action.value
        #expect(code(denied) == "page_changed")
        #expect(!String(describing: denied).contains("Private secret"))
        let check = try result(await session.perform(.eval(expression: "document.body.dataset.executed", note: nil)))
        #expect(check.contains("Result: undefined"))
    }

    @Test func aRefusedAgentOpenDoesNotChangeWhoOpenedTheUserPage() async throws {
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        defer { session.close() }
        session.load(try #require(URL(string: "data:text/html,<title>User page</title>")))
        try await eventuallyOnMain("user page") { session.pageTitle == "User page" }
        session.takeOver()
        #expect(code(await session.perform(.open(url: "about:blank", note: nil))) == "taken_over")
        #expect(session.tabSource == .user)
        session.handBack()
        #expect(code(await session.perform(.open(url: "file:///private", note: nil))) == "refused_url")
        #expect(session.tabSource == .user)
        #expect(session.tabs.pages.count == 1)
        _ = try result(await session.perform(.open(url: "about:blank", note: nil)))
        #expect(session.pageTitle == "User page")
        #expect(session.tabs.pages.count == 2)
    }

    @Test func aRemoteAgentNeverReceivesAPrivateTabsTitleOrAddress() async throws {
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        defer { session.close() }
        session.load(try #require(URL(string: "data:text/html,<title>private-secret-title</title>secret")))
        try await eventuallyOnMain("private page") { session.pageTitle == "private-secret-title" }
        let policy = BrowserViewerPolicy()
        let listing = try result(await session.performFromHost(.tabs, policy: policy))
        #expect(listing.contains("[private page]"))
        #expect(!listing.contains("private-secret-title"))
        #expect(!listing.contains("data:"))
        #expect(code(await session.performFromHost(.closeTab(id: session.tabID.uuidString), policy: policy)) == "refused_url")
        #expect(session.tabs.pages.count == 1)
        #expect(session.pageTitle == "private-secret-title")
        #expect(code(await session.performFromHost(.tab(id: session.tabID.uuidString,
            request: .read(selector: nil, maxChars: nil)), policy: policy)) == "refused_url")
        let count = session.tabs.pages.count
        #expect(code(await session.performFromHost(.newTab(url: "http://192.168.1.1", note: nil), policy: policy)) == "refused_url")
        #expect(session.tabs.pages.count == count)
    }
}
