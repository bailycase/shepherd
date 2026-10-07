import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdSessions

/// Subprojects on a real host (Settings ▸ Projects, parents and subprojects): the listing names each
/// project's parent by folder and the MCP servers it shares and inherits, and an agent starting in a
/// subproject is told its parent's folder.
@Suite("Subproject listing", .integrationTimeLimit)
struct SubprojectListingTests {
    @Test func aFolderInsideAnotherProjectIsItsSubprojectAndInheritsItsMCPServers() async throws {
        let directory = try makeScratchDirectory("sub")
        let pi = PiSetup(engine: PiSetup.app.engine, home: directory.appendingPathComponent("pi"))
        let scratch = try ScratchServer(dir: directory, pi: pi)
        defer { scratch.stop() }
        let fm = FileManager.default
        let acme = scratch.dir.appendingPathComponent("acme").resolvingSymlinksInPath()
        let web = acme.appendingPathComponent("apps/web"), admin = acme.appendingPathComponent("apps/web/admin")
        let landing = scratch.dir.appendingPathComponent("acme-landing").resolvingSymlinksInPath()
        for folder in [web, admin, landing] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        func mcp(_ folder: URL, _ names: [String]) throws {
            try fm.createDirectory(at: folder.appendingPathComponent(".pi"), withIntermediateDirectories: true)
            let servers = Dictionary(uniqueKeysWithValues: names.map { ($0, ["command": "true"]) })
            try JSONSerialization.data(withJSONObject: ["mcpServers": servers]).write(to: folder.appendingPathComponent(".pi/mcp.json"))
        }
        try mcp(acme, ["docs", "shared"])
        try mcp(web, ["docs", "local"])
        let state = ShepherdState(spaces: [Space(name: "acme", path: acme.path), Space(name: "web", path: web.path),
                                           Space(name: "admin", path: admin.path), Space(name: "acme-landing", path: landing.path)])
        try await scratch.server.putState(state)
        let store = scratch.server.projects
        guard case .listing(let listing) = try await store.request(.list(), state: state) else { Issue.record("Expected projects"); return }
        let byName = Dictionary(uniqueKeysWithValues: listing.projects.map { ($0.name, $0) })
        #expect(byName["acme"]?.parent == nil && byName["acme"]?.mcpServers == ["docs", "shared"])
        #expect(byName["web"]?.parent == acme.path)
        #expect(byName["web"]?.inheritedMCP == ["shared"], "its own docs overrides the parent's")
        #expect(byName["admin"]?.parent == acme.path, "one level: the outermost project is the parent")
        #expect(byName["admin"]?.inheritedMCP == ["docs", "shared"])
        #expect(byName["acme-landing"]?.parent == nil, "a sibling with a shared prefix is not inside it")

        #expect(await store.parentProject(of: web.path, state: state) == acme.path)
        #expect(await store.parentProject(of: web.appendingPathComponent("src").path, state: state) == acme.path)
        #expect(await store.parentProject(of: acme.path, state: state) == nil)
        #expect(await store.parentProject(of: landing.path, state: state) == nil)
    }
}
