import Foundation
import ShepherdCore
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
import WebKit
@testable import ShepherdApp

@MainActor
@Suite("Project Browser previews", .mainActorExclusive, .enabled(if: Preview.enabled))
struct ProjectBrowserPreviewTests {
    @Test(arguments: ["populated", "empty", "filtered", "long", "confirm-one", "confirm-all", "cleared", "unsupported", "narrow"])
    func browserSettings(state: String) async throws {
        let world = try await ProjectsPreviewWorld(detail: true)
        defer { world.stop() }
        let vm = world.vm
        let row = try #require(vm.projects.rows.first { $0.host.id == "local" && $0.project.name == "payments" })
        let space = try #require(vm.state.spaces.first { $0.path == row.project.directory })
        let agent = Agent(name: "Cookie preview", spaceID: space.id, tabID: TabID())
        var stateWithAgent = vm.state
        stateWithAgent.agents.append(agent)
        vm.browsers.prune(state: stateWithAgent)
        let session = vm.browsers.session(for: agent.id)
        session.load(URL(string: "about:blank")!)
        let store = try #require(session.webView?.configuration.websiteDataStore)
        if state != "empty" {
            let sites = state == "long"
                ? [("team-" + String(repeating: "a", count: 40) + ".accounts." + String(repeating: "b", count: 30) + ".example.com", 26)]
                : [("localhost", 12), ("github.com", 8), ("accounts.google.com", 6)]
            for (domain, count) in sites {
                for index in 0..<count {
                    let cookie = try #require(HTTPCookie(properties: [.domain: domain, .path: "/", .name: "cookie-\(index)", .value: "private-value-not-displayed"]))
                    await store.httpCookieStore.setCookie(cookie)
                }
            }
        }
        await vm.projects.open(row)
        await vm.projects.navigate(.browser)
        let scope = try #require(vm.cookieScope(for: row))
        await vm.projectCookies.load(scope)
        if state == "filtered" { vm.projectCookies.filter = "absent.invalid" }
        if state == "unsupported" { vm.state.spaces.removeAll { $0.id == space.id } }
        let originalScale = ThemeStore.shared.textScale
        defer { ThemeStore.shared.textScale = originalScale }
        for scale in [CGFloat(1), 1.3] {
            ThemeStore.shared.textScale = scale
            await vm.projectCookies.load(nil, force: true)
            let name = "project-browser-\(state)" + (scale == 1 ? "" : "-x1.3")
            try await Preview.render(name, size: CGSize(width: state == "narrow" ? 1050 : 1440, height: 900), ready: {
                !vm.projectCookies.loading && (state == "unsupported" || vm.projectCookies.scope == scope)
            }, afterReady: {
                if state == "confirm-one" { vm.projectCookies.ask(.site("github.com")) }
                if state == "confirm-all" { vm.projectCookies.ask(.all) }
                if state == "cleared" {
                    vm.projectCookies.ask(.site("github.com"))
                    Task { await vm.projectCookies.confirm(scope) }
                }
            }, untilGone: state == "cleared" ? "Clearing…" : nil,
               showing: state == "cleared" ? "Cleared cookies for github.com" : nil) { SettingsView(vm: vm) }
            if state == "cleared" { #expect(vm.projectCookies.notice?.contains("github.com") == true) }
        }
    }
}
