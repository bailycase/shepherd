import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdSessions

/// Spaces on a paired Mac, over the remote listener: Add space and the space's Settings set a
/// parent there (`RemoteProjectsRequest.organize`), and a child space sees, turns off and
/// overrides its parent's slash commands and extensions.
@Suite("Remote space parents and inheritance", .integrationTimeLimit)
struct RemoteSpaceInheritanceTests {
    @Test func aRemoteSpaceGetsAParentAndNameAndOlderHostsRefuseBeforeSending() async throws {
        let pi = PiSetup(engine: PiSetup.app.engine, home: try makeScratchDirectory("rpp"))
        let r = try RemoteHost(pi: pi)
        defer { r.stop() }
        let fm = FileManager.default
        let acme = r.host.dir.appendingPathComponent("acme").resolvingSymlinksInPath()
        let landing = r.host.dir.appendingPathComponent("acme-landing").resolvingSymlinksInPath()
        for folder in [acme, landing] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let parent = Space(name: "acme", path: acme.path)
        try await r.server.addSpace(parent)
        let client = try await r.typed()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.projectParentCapability))

        // Add space with a parent, as AddSpaceModel does for another host: add, then organize.
        let added = try await client.addSpace(path: landing.path)
        guard case .listing(let listing) = try await client.projects(.organize(spaceID: added, name: "acme-landing-site", parentID: parent.id)) else {
            Issue.record("Expected the listing"); return
        }
        let space = try #require(r.server.state.spaces.first { $0.id == added })
        #expect(space.parentID == parent.id && space.parentIsExplicit && space.name == "acme-landing-site")
        #expect(listing.projects.first { $0.projectID == added }?.parent == acme.path, "the host's listing shows it under its parent")
        #expect(listing.projects.first { $0.projectID == added }?.inheritedFromName == nil, "a folder elsewhere is only listed under it")
        #expect(try fm.contentsOfDirectory(atPath: landing.path).isEmpty, "nothing is written into the folder")

        // The space's Settings: a cycle is refused, and None makes it a root space again.
        do {
            _ = try await client.projects(.organize(spaceID: parent.id, name: nil, parentID: added))
            Issue.record("A cycle was accepted")
        } catch RemoteHostClientError.rejected(let code, _) { #expect(code == "invalid_hierarchy") }
        _ = try await client.projects(.organize(spaceID: added, name: nil, parentID: nil))
        let root = try #require(r.server.state.spaces.first { $0.id == added })
        #expect(root.parentID == nil && root.parentIsExplicit && root.name == "acme-landing-site")

        let old = try RemoteHost()
        defer { old.stop() }
        old.server.advertisedCapabilities = RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.projectParentCapability && $0 != RemoteProtocol.projectInheritedResourcesCapability }
        let oldClient = try await old.typed()
        defer { oldClient.disconnect() }
        for request in [RemoteProjectsRequest.organize(spaceID: added, name: nil, parentID: nil),
                        .inheritance(directory: acme.path, excluded: SpaceInheritanceExclusions(prompts: ["ship"]))] {
            do {
                _ = try await oldClient.projects(request)
                Issue.record("An older host was sent \(request)")
            } catch RemoteHostClientError.rejected(let code, _) { #expect(code == "update_required") }
        }
    }

    /// ProjectChildSkills, for commands and extensions: the child lists the parent's, turns one of
    /// each off in the host's record, and its own file of the same name wins. At launch the
    /// parent's extensions load with `-e`, less those two.
    @Test func aChildSeesTurnsOffAndOverridesInheritedCommandsAndExtensions() async throws {
        let pi = PiSetup(engine: PiSetup.app.engine, home: try makeScratchDirectory("rpi"))
        let r = try RemoteHost(pi: pi)
        defer { r.stop() }
        let fm = FileManager.default
        let acme = r.host.dir.appendingPathComponent("acme").resolvingSymlinksInPath()
        let web = acme.appendingPathComponent("apps/web")
        func write(_ folder: URL, _ file: String, _ text: String) throws {
            let url = folder.appendingPathComponent(file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write(acme, ".pi/prompts/ship.md", "Ship it.\n")
        try write(acme, ".pi/prompts/triage.md", "Triage.\n")
        try write(acme, ".pi/extensions/ledger-guard.ts", "// Guards ledgers.\n")
        try write(acme, ".shepherd/extensions/audit.ts", "// Audits.\n")
        try write(acme, ".pi/extensions/lint.ts", "// Parent lint.\n")
        try write(web, ".pi/extensions/lint.ts", "// Web lint.\n")
        let state = ShepherdState(spaces: [Space(name: "acme", path: acme.path), Space(name: "web", path: web.path)])
        try await r.server.putState(state)
        let client = try await r.typed()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.projectInheritedResourcesCapability))

        guard case .resources(let parent) = try await client.projects(.resources(directory: acme.path)) else { Issue.record("Expected resources"); return }
        #expect(Set(parent.filter { !$0.global }.map(\.name)) == ["ship", "triage", "ledger-guard.ts", "audit.ts", "lint.ts"])

        let off = SpaceInheritanceExclusions(prompts: ["triage", "triage"], extensions: ["audit.ts"])
        guard case .context(let context) = try await client.projects(.inheritance(directory: web.path, excluded: off)) else { Issue.record("Expected context"); return }
        #expect(context.inheritsFrom == acme.path && context.excluded == SpaceInheritanceExclusions(prompts: ["triage"], extensions: ["audit.ts"]))

        let launch = try #require(await r.server.projects.inheritance(of: web.path, state: state))
        #expect(launch.excluded.prompts == ["triage"], "the extension leaves the turned-off command out")
        #expect(launch.extensions == [acme.path + "/.pi/extensions/ledger-guard.ts"],
                "audit.ts is off and the child's own lint.ts wins over the parent's")
        let env = MCPLaunch(extensions: [], environment: [:]).sharingParent(launch.parent, install: { "/ext/parent.ts" })
            .excluding(launch.excluded).loadingParentExtensions(launch.extensions)
        #expect(env.extensions == ["/ext/parent.ts", acme.path + "/.pi/extensions/ledger-guard.ts"])
        #expect(env.environment["SHEPHERD_PARENT_EXCLUDE"]?.contains("triage") == true)
        #expect(MCPLaunch(extensions: [], environment: [:]).loadingParentExtensions(launch.extensions).extensions.isEmpty, "only a launch that shares a parent")

        // Override here: the child's own copy, saved in its folder, wins by name at the next launch.
        _ = try await client.projects(.save(directory: web.path, file: ".pi/extensions/ledger-guard.ts", text: "// Web guard.\n", expected: nil))
        #expect(await r.server.projects.inheritance(of: web.path, state: state)?.extensions == [])
        #expect(try String(contentsOf: acme.appendingPathComponent(".pi/extensions/ledger-guard.ts"), encoding: .utf8) == "// Guards ledgers.\n",
                "the parent's file is never written")
    }
}
