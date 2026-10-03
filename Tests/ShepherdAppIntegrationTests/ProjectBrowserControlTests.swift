import AppKit
import Foundation
import ShepherdCore
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
import WebKit
@testable import ShepherdApp

@MainActor
@Suite("Project Browser controls", .mainActorExclusive)
struct ProjectBrowserControlTests {
    @Test func staleWebKitReadbackStopsAfterTwentyRefreshAttempts() async {
        var reads = 0, clears = 0
        let scope = ProjectCookieScope(projectID: SpaceID(), hostID: nil)
        let model = ProjectCookiesModel(read: { _ in reads += 1; return [BrowserCookieSite(site: "stale.test", count: 1)] }, clear: { _, _ in clears += 1 })
        await model.load(scope); model.ask(.all)
        await model.confirm(scope)
        #expect(clears == 1 && reads == 21)
        #expect(!model.clearing && model.error == nil && model.notice?.contains("created new cookies") == true)
    }

    @Test func clearControlsDeleteOnlyTheConfirmedSiteInTheSelectedProject() async throws {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressControls() }
        }
    }

    private static func pressControls() async throws {
        try StubPi.installAsEngine()
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let project = Space(name: "payments", path: app.dir.appendingPathComponent("payments").path)
        let other = Space(name: "unrelated", path: app.dir.appendingPathComponent("unrelated").path)
        for space in [project, other] { try FileManager.default.createDirectory(atPath: space.path, withIntermediateDirectories: true) }
        try await app.server.addSpace(project, first: false)
        try await app.server.addSpace(other, first: false)
        let mine = Agent(name: "mine", spaceID: project.id, tabID: TabID())
        let sibling = Agent(name: "sibling", spaceID: project.id, tabID: TabID())
        let unrelated = Agent(name: "other", spaceID: other.id, tabID: TabID())
        var state = vm.state; state.agents += [mine, sibling, unrelated]
        vm.browsers.prune(state: state)
        for agent in [mine, sibling, unrelated] { vm.browsers.session(for: agent.id).load(URL(string: "about:blank")!) }
        let store = try #require(vm.browsers.existing(mine.id)?.webView?.configuration.websiteDataStore)
        let otherStore = try #require(vm.browsers.existing(unrelated.id)?.webView?.configuration.websiteDataStore)
        let one = try #require(HTTPCookie(properties: [.domain: "one.test", .path: "/", .name: "private-name", .value: "private-value"]))
        let two = try #require(HTTPCookie(properties: [.domain: "two.test", .path: "/", .name: "secret-name", .value: "secret-value"]))
        await store.httpCookieStore.setCookie(one); await store.httpCookieStore.setCookie(two)
        await otherStore.httpCookieStore.setCookie(one)
        await vm.projects.load(vm.projectsSources)
        let row = try #require(vm.projects.rows.first { $0.project.directory == project.path })
        await vm.projects.open(row)
        await vm.projects.navigate(.browser)
        let scope = try #require(vm.cookieScope(for: row))
        await vm.projectCookies.load(scope)
        vm.showSettings = true; vm.settingsSection = .projects
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 900), dark: true, SettingsView(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("cookie controls") { window.layout(); return AccessibilityNode.all(under: window.host).contains { $0.label == "Clear cookies for one.test" } }
        let nodes = AccessibilityNode.all(under: window.host)
        let siteFilter = try #require(nodes.first { $0.label == "Filter sites" && $0.role == "AXTextField" })
        let setter = NSSelectorFromString("setAccessibilityValue:")
        #expect(siteFilter.object.responds(to: setter))
        _ = siteFilter.object.perform(setter, with: "one.test")
        func nativeInput(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "Filter sites" || field.stringValue == "one.test" { return field }
            return view.subviews.lazy.compactMap(nativeInput).first
        }
        if let field = nativeInput(window.host) {
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        try await eventuallyOnMain("native cookie filter") { vm.projectCookies.filter == "one.test" && vm.projectCookies.visible.count == 1 }
        #expect(vm.projectCookies.total == 2)
        window.layout()
        try ControlPress.press("Clear search", under: window.host)
        try await eventuallyOnMain("all cookie sites") { vm.projectCookies.visible.count == 2 }
        window.layout()
        let clear = try ControlPress.press("Clear cookies for one.test", under: window.host)
        #expect(ControlPress.undersized([clear], minimum: .desktop).isEmpty)
        #expect(await store.httpCookieStore.allCookies().count == 2)
        window.layout()
        let confirmationNodes = AccessibilityNode.all(under: window.host)
        #expect(!confirmationNodes.contains { $0.label == "Back to Shepherd" || $0.label == "Project category Instructions" || $0.label == "Clear cookies for two.test" })
        let labels = confirmationNodes.compactMap(\.label).joined(separator: " ")
        #expect(!["private-name", "private-value", "secret-name", "secret-value"].contains { labels.contains($0) })
        try ControlPress.press("Cancel", under: window.host)
        #expect(await store.httpCookieStore.allCookies().count == 2)
        window.layout()
        try ControlPress.press("Clear cookies for one.test", under: window.host)
        window.layout()
        try ControlPress.press("Clear cookies", under: window.host)
        try await eventuallyOnMain("one site cleared") { !vm.projectCookies.clearing && vm.projectCookies.total == 1 }
        #expect(await store.httpCookieStore.allCookies().map(\.domain) == ["two.test"])
        #expect(await otherStore.httpCookieStore.allCookies().count == 1)
        #expect(vm.browsers.existing(sibling.id)?.webView?.configuration.websiteDataStore === store)
        window.layout()
        let all = try ControlPress.press("Clear all cookies", under: window.host)
        #expect(ControlPress.undersized([all], minimum: .desktop).isEmpty)
        #expect(await store.httpCookieStore.allCookies().count == 1)
        window.layout()
        try ControlPress.press("Clear cookies", under: window.host)
        try await eventuallyOnMain("all project cookies cleared") { !vm.projectCookies.clearing && vm.projectCookies.total == 0 }
        #expect(await store.httpCookieStore.allCookies().isEmpty)
        #expect(await otherStore.httpCookieStore.allCookies().count == 1)
    }
}
