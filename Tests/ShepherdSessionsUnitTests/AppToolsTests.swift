import Foundation
import ShepherdCore
import Testing
@testable import ShepherdSessions

/// What an agent's app tools see (`AppTools.visible`): its space's apps, and only the This Mac
/// apps that let agents start them.
@Suite("App tools")
struct AppToolsTests {
    @Test func anAgentSeesItsSpacesAppsAndOnlyTheMacAppsThatLetAgentsIn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let space = root.appendingPathComponent("payments"), home = root.appendingPathComponent("home")
        try AppsFile.save([AppDefinition(name: "Web app", command: "npm run dev")], to: AppsFile.url(in: space.path))
        try AppsFile.save([AppDefinition(name: "Postgres", command: "postgres", agents: true),
                           AppDefinition(name: "Private", command: "secret-thing")], to: AppsFile.url(in: home.path))
        let id = SpaceID()
        let place = AppTools.Place(space: (id, "payments", space.path), cwd: nil, home: home.path, unattended: false)
        #expect(AppTools.visible(place).map(\.key) == [AppKey(scope: .space(id), name: "Web app"), AppKey(scope: .mac, name: "Postgres")])
        let hidden = AppTools.Place(space: nil, cwd: nil, home: home.path, unattended: true)
        #expect(AppTools.visible(hidden).map(\.key.name) == ["Postgres"], "a hidden space has no apps of its own")
    }

    @Test func anUnattendedRunCannotStartAnApp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try AppsFile.save([AppDefinition(name: "Web app", command: "npm run dev", agents: true)], to: AppsFile.url(in: root.path))
        let place = AppTools.Place(space: (SpaceID(), "payments", root.path), cwd: nil, home: root.appendingPathComponent("home").path, unattended: true)
        let result = await AppTools.serve(.run, name: "Web app", lines: nil, place: place, apps: AppProcesses())
        #expect(result == .failure(AppTools.Refusal(code: "not_allowed", message: "An automation's run can't start or stop apps.")))
    }
}
