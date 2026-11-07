import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// A remote thread header's Run control says what the Mac's does: quick actions only, the running
/// one on the button, and each row's next step.
@Suite("Remote quick apps")
struct RemoteQuickAppsTests {
    static let web = AppDefinition(name: "Web app", command: "npm run dev", opens: .browser, address: "http://localhost:3000", quickAction: true)
    static let storybook = AppDefinition(name: "Storybook", command: "npm run storybook", opens: .browser, quickAction: true)
    static let docs = AppDefinition(name: "Docs", command: "make docs")

    @Test func onlyQuickActionsShowAndTheRunningOneLeads() throws {
        #expect(RemoteQuickApps(RemoteAppsResult(space: "acme-web", apps: [RemoteApp(app: Self.docs, mac: true)])) == nil)
        let idle = try #require(RemoteQuickApps(RemoteAppsResult(space: "acme-web", apps: [
            RemoteApp(app: Self.web, mac: false), RemoteApp(app: Self.docs, mac: true), RemoteApp(app: Self.storybook, mac: false)])))
        #expect(idle.items.map(\.app.name) == ["Web app", "Storybook"])
        #expect(idle.primary.app.name == "Web app")
        let running = try #require(RemoteQuickApps(RemoteAppsResult(space: "acme-web", apps: [
            RemoteApp(app: Self.web, mac: false, run: RemoteAppRun(status: .exited(code: 0))),
            RemoteApp(app: Self.storybook, mac: false, run: RemoteAppRun(status: .running, port: 6006))])))
        #expect(running.primary.app.name == "Storybook")
    }

    @Test(arguments: [
        (RemoteAppRun?.none, "Browser tab", RemoteQuickApps.Action.run),
        (RemoteAppRun(status: .starting), "Starting… · Stop", .stop),
        (RemoteAppRun(status: .running, port: 3000), "Running · :3000 · Stop", .stop),
        (RemoteAppRun(status: .running), "Running · Stop", .stop),
        (RemoteAppRun(status: .exited(code: 1)), "Exited (code 1) · Restart", .restart),
        (RemoteAppRun(status: .failed("Its folder doesn’t exist.")), "Browser tab", .run),
    ])
    func eachRowSaysWhatItDoesNext(run: RemoteAppRun?, detail: String, action: RemoteQuickApps.Action) {
        let app = RemoteApp(app: Self.web, mac: false, run: run)
        #expect(RemoteQuickApps.detail(app) == detail)
        #expect(RemoteQuickApps.action(app) == action)
    }
}
