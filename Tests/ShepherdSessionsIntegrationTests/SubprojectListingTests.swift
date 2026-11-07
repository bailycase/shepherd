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
            try fm.createDirectory(at: folder.appendingPathComponent(".shepherd"), withIntermediateDirectories: true)
            let servers = Dictionary(uniqueKeysWithValues: names.map { ($0, ["command": "true"]) })
            try JSONSerialization.data(withJSONObject: ["mcpServers": servers]).write(to: folder.appendingPathComponent(".shepherd/mcp.json"))
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

        #expect(await store.inheritance(of: web.path, state: state)?.parent == acme.path)
        #expect(await store.inheritance(of: web.appendingPathComponent("src").path, state: state)?.parent == acme.path)
        #expect(await store.inheritance(of: acme.path, state: state) == nil)
        #expect(await store.inheritance(of: landing.path, state: state) == nil)
    }

    /// A child space turns off a parent server and skill for itself (ProjectChildMCP, ProjectChildSkills):
    /// recorded by the host, kept across restarts, honored at launch, and never written to either folder.
    @Test func aChildSpaceTurnsOffInheritedServersAndSkillsForItselfOnly() async throws {
        let directory = try makeScratchDirectory("excl")
        let pi = PiSetup(engine: PiSetup.app.engine, home: directory.appendingPathComponent("pi"))
        let scratch = try ScratchServer(dir: directory, pi: pi)
        defer { scratch.stop() }
        let fm = FileManager.default
        let acme = scratch.dir.appendingPathComponent("acme").resolvingSymlinksInPath()
        let web = acme.appendingPathComponent("apps/web"), admin = web.appendingPathComponent("admin")
        try fm.createDirectory(at: admin, withIntermediateDirectories: true)
        try fm.createDirectory(at: acme.appendingPathComponent(".shepherd"), withIntermediateDirectories: true)
        let parentFile = acme.appendingPathComponent(".shepherd/mcp.json")
        try Data(#"{"mcpServers":{"docs":{"command":"true"},"shared":{"command":"true"}}}"#.utf8).write(to: parentFile)
        let state = ShepherdState(spaces: [Space(name: "acme", path: acme.path), Space(name: "web", path: web.path), Space(name: "admin", path: admin.path)])
        try await scratch.server.putState(state)
        let store = scratch.server.projects
        guard case .context(let before) = try await store.request(.context(directory: web.path), state: state) else { Issue.record("Expected context"); return }
        #expect(before.inheritsFrom == acme.path && before.excluded == SpaceInheritanceExclusions(), "nothing is off until the child says so")

        let off = SpaceInheritanceExclusions(mcp: ["docs", "docs"], skills: ["ledger-review"])
        guard case .context(let after) = try await store.request(.inheritance(directory: web.path, excluded: off), state: state) else { Issue.record("Expected context"); return }
        #expect(after.excluded == SpaceInheritanceExclusions(mcp: ["docs"], skills: ["ledger-review"]))
        guard case .listing(let listing) = try await store.request(.list(), state: state) else { Issue.record("Expected projects"); return }
        #expect(listing.projects.first { $0.name == "web" }?.inheritedMCP == ["shared"])
        #expect(listing.projects.first { $0.name == "admin" }?.inheritedMCP == ["docs", "shared"], "a nested space keeps its own choice")
        #expect(await store.inheritance(of: web.appendingPathComponent("src").path, state: state)?.excluded.mcp == ["docs"])
        #expect(await store.inheritance(of: admin.path, state: state)?.excluded == SpaceInheritanceExclusions())
        #expect(try String(contentsOf: parentFile, encoding: .utf8).contains("docs"), "the parent's file is untouched")
        #expect(!fm.fileExists(atPath: web.appendingPathComponent(".shepherd").path), "nothing is written to the child's folder")

        // A restarted host reads it back; Reset clears it.
        let reopened = ProjectSettingsStore(historyURL: scratch.dir.appendingPathComponent("projects.json"), home: scratch.dir, sessions: scratch.dir)
        #expect(await reopened.inheritance(of: web.path, state: state)?.excluded.skills == ["ledger-review"])
        _ = try await store.request(.inheritance(directory: web.path, excluded: SpaceInheritanceExclusions()), state: state)
        #expect(await store.inheritance(of: web.path, state: state)?.excluded == SpaceInheritanceExclusions())
        await #expect(throws: ProjectFileError.self) {
            _ = try await store.request(.inheritance(directory: scratch.dir.appendingPathComponent("elsewhere").path, excluded: off), state: state)
        }
    }
}
