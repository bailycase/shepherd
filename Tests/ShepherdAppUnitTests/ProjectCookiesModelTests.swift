import Foundation
import Testing
import ShepherdCore
import ShepherdTestSupport
@testable import ShepherdApp

private struct CookieReadFailure: Error {}

@MainActor @Suite("Project Browser cookie settings", .mainActorExclusive)
struct ProjectCookiesModelTests {
    @Test func countsAndFiltersContainOnlySiteMetadata() async {
        let scope = ProjectCookieScope(projectID: SpaceID())
        let model = ProjectCookiesModel(read: { _ in [BrowserCookieSite(site: "localhost", count: 12), BrowserCookieSite(site: "github.com", count: 8)] }, clear: { _, _ in })
        await model.load(scope)
        #expect(model.countText == "2 sites · 20 cookies")
        model.filter = "GITHUB"
        #expect(model.visible.map(\.site) == ["github.com"])
        model.filter = "not-present"
        #expect(model.visible.isEmpty)
    }

    @Test func clearingRequiresConfirmationAndUsesThePinnedViewerLocalScope() async {
        let scope = ProjectCookieScope(projectID: SpaceID(), hostID: UUID())
        var sites = [BrowserCookieSite(site: "one.test", count: 2), BrowserCookieSite(site: "two.test", count: 1)]
        var calls: [(ProjectCookieScope, String?)] = []
        let model = ProjectCookiesModel(read: { _ in sites }, clear: { scope, site in
            calls.append((scope, site)); sites.removeAll { site == nil || $0.site == site }
        })
        await model.load(scope)
        model.ask(.site("one.test"))
        #expect(calls.isEmpty)
        model.pending = nil
        #expect(calls.isEmpty)
        model.ask(.site("one.test")); await model.confirm(scope)
        #expect(calls.count == 1 && calls[0].0 == scope && calls[0].1 == "one.test")
        #expect(model.sites.map(\.site) == ["two.test"])
        model.ask(.all); await model.confirm(scope)
        #expect(calls.count == 2 && calls[1].1 == nil)
        #expect(model.sites.isEmpty)
    }

    @Test func changingScopeDuringClearLoadsTheNewProjectWithoutShowingTheOldNotice() async {
        let first = ProjectCookieScope(projectID: SpaceID())
        let second = ProjectCookieScope(projectID: SpaceID(), hostID: UUID())
        let started = AsyncStream.makeStream(of: Void.self)
        var finish: CheckedContinuation<Void, Never>?
        let model = ProjectCookiesModel(read: { scope in
            scope == first ? [BrowserCookieSite(site: "old.test", count: 1)] : [BrowserCookieSite(site: "new.test", count: 2)]
        }, clear: { _, _ in
            await withCheckedContinuation { finish = $0; started.continuation.yield() }
        })
        await model.load(first); model.ask(.all)
        let clearing = Task { await model.confirm(first) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        await model.load(second)
        #expect(model.scope == second && model.visible.isEmpty && model.countText == "Loading…")
        finish?.resume()
        await clearing.value
        #expect(!model.clearing && model.scope == second && model.total == 2)
        #expect(model.visible.first?.site == "new.test" && model.notice == nil)
    }

    @Test func readFailureAfterDeletionDoesNotReportDeletionAsFailed() async {
        let scope = ProjectCookieScope(projectID: SpaceID())
        var deleted = false
        let model = ProjectCookiesModel(read: { _ in
            if deleted { throw CookieReadFailure() }
            return [BrowserCookieSite(site: "site.test", count: 1)]
        }, clear: { _, _ in deleted = true })
        await model.load(scope); model.ask(.all); await model.confirm(scope)
        #expect(deleted && model.error?.hasPrefix("Cookies cleared") == true)
        #expect(model.countText == "Unavailable" && model.sites.isEmpty && model.visible.isEmpty)
    }

    @Test func switchingProjectsDropsTheOldCountAndCannotClearItsCookies() async {
        let first = ProjectCookieScope(projectID: SpaceID()), second = ProjectCookieScope(projectID: SpaceID())
        var deletes = 0
        let model = ProjectCookiesModel(read: { _ in [BrowserCookieSite(site: "one.test", count: 1)] }, clear: { _, _ in deletes += 1 })
        await model.load(first); model.ask(.all)
        await model.confirm(second)
        #expect(deletes == 0 && model.pending == nil)
        await model.load(nil)
        #expect(model.sites.isEmpty && model.scope == nil)
    }
}
