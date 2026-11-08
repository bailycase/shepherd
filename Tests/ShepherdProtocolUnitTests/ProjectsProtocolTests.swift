import Foundation
import Testing
import ShepherdProtocol

@Suite("Project settings protocol")
struct ProjectsProtocolTests {
    @Test(arguments: [RemoteProjectsRequest.mcp(directory: "/host/repo", file: ".shepherd/mcp.json", action: .credentials),
                      .mcp(directory: "/host/repo", file: ".shepherd/mcp.json", action: .approveProject),
                      .mcp(directory: "/host/repo", file: ".shepherd/mcp.json", action: .login(server: "issues")),
                      .mcp(directory: "/host/repo", file: ".mcp.json", action: .logout(server: "issues")),
                      .mcp(directory: "/host/repo", file: ".shepherd/mcp.json", action: .poll(id: UUID())),
                      .mcp(directory: "/host/repo", file: ".shepherd/mcp.json", action: .cancel(id: UUID())),
                      .mcp(directory: "/host/repo", file: ".shepherd/mcp.json", action: .complete(id: UUID(), redirectURL: "http://127.0.0.1:1234/callback?code=test&state=test")),
                      RemoteProjectsRequest.list(), .list(offset: 64), .files(directory: "/host/repo"),
                      .context(directory: "/host/repo"), .open(directory: "/host/repo", file: "AGENTS.md"),
                      .read(directory: "/host/repo", file: ".shepherd/settings.json"),
                      .save(directory: "/host/repo", file: "AGENTS.md", text: "new", expected: nil),
                      .save(directory: "/host/repo", file: "AGENTS.md", text: "new", expected: "old"),
                      .resources(directory: "/host/repo"), .delete(directory: "/host/repo", file: ".pi/prompts/review.md", expected: "old"),
                      .installSkills(directory: "/host/repo", repo: "acme/skills", paths: ["skills/pdf"], commit: nil),
                      .installSkills(directory: "/host/repo", repo: "https://example.invalid/skills.git", paths: [], commit: "main"),
                      .inheritance(directory: "/host/repo/web", excluded: SpaceInheritanceExclusions(mcp: ["docs"], skills: ["ledger-review"])),
                      .inheritance(directory: "/host/repo/web", excluded: SpaceInheritanceExclusions())])
    func eachRequestRoundTrips(_ request: RemoteProjectsRequest) throws {
        let value = RemoteRequest.projects(id: 7, request: request)
        #expect(try NDJSON.decode(RemoteRequest.self, from: NDJSON.encode(value)) == value)
    }

    @Test(arguments: [RemoteProjectsResult.mcp(.init(id: UUID(), phase: .waiting, authorizationURL: "https://example.test/auth")),
                      .mcp(.init(signedIn: ["issues"])), .mcp(.init(phase: .failed, message: "Cancelled.")),
                      RemoteProjectsResult.opened, .mcp(.init(projectTrusted: false)), .mcp(.init(projectTrusted: true)), .context(ProjectContext(files: [.init(path: "/a/AGENTS.md", displayPath: "~/a/AGENTS.md")], resources: 4, mcpServers: 1)), .context(ProjectContext(inheritsFrom: "/a", excluded: SpaceInheritanceExclusions(mcp: ["docs"]))), RemoteProjectsResult.listing(ProjectListing(projects: [], nextOffset: 64)),
                      .listing(ProjectListing(projects: [ProjectSummary(directory: "/a", name: "a", displayPath: "~/a", summary: "AGENTS.md only", minimal: true)])),
                      .files([ProjectFile(path: "AGENTS.md", category: .instructions, exists: false)]),
                      .text(ProjectFileText(file: ProjectFile(path: "AGENTS.md", category: .instructions, exists: false), text: nil)),
                      .text(ProjectFileText(file: ProjectFile(path: "AGENTS.md", category: .instructions, exists: true), text: "")),
                      .resources([ProjectResource(kind: .skill, name: "ledger-review", description: "Review ledgers.", path: ".pi/skills/ledger-review/SKILL.md"),
                                  ProjectResource(kind: .agent, name: "scout", path: "/support/pi/agents/scout.md", displayPath: "Shepherd/pi/agents/scout.md",
                                                  global: true, enabled: false, detail: "read · grep")])])
    func eachResultRoundTrips(_ result: RemoteProjectsResult) throws {
        let value = RemoteReply.projects(id: 9, result: result)
        #expect(try NDJSON.decode(RemoteReply.self, from: NDJSON.encode(value)) == value)
    }

    /// An older host's context has no inheritance fields, and a list without one of its keys turns nothing off.
    @Test func inheritanceFieldsDecodeEmptyFromOlderPeers() throws {
        let context = try JSONDecoder().decode(ProjectContext.self, from: Data(#"{"files":[],"resources":0,"mcpServers":0}"#.utf8))
        #expect(context.inheritsFrom == nil && context.excluded == nil)
        #expect(try JSONDecoder().decode(SpaceInheritanceExclusions.self, from: Data(#"{"mcp":["docs"]}"#.utf8)) == SpaceInheritanceExclusions(mcp: ["docs"]))
        #expect(!RemoteProjectsRequest.context(directory: "/a").requiresInheritance)
        #expect(RemoteProjectsRequest.inheritance(directory: "/a", excluded: .init()).requiresInheritance)
    }
}

/// The space Resources tab's toggles write pi's own resource patterns, as `pi config` does.
@Suite("Project resource patterns")
struct ProjectResourcePatternsTests {
    let base = "/code/payments/.pi"

    @Test func aSpaceResourceTurnsOffWithAnExactExclusionAndBackOnByRemovingIt() {
        let skill = "/code/payments/.pi/skills/pdf-tools/SKILL.md"
        #expect(ProjectResourcePatterns.isEnabled(skill, entries: [], base: base))
        let off = ProjectResourcePatterns.setting(false, path: skill, global: false, base: base, in: ["../shared/skills"])
        #expect(off == ["../shared/skills", "-skills/pdf-tools/SKILL.md"])
        #expect(!ProjectResourcePatterns.isEnabled(skill, entries: off, base: base))
        // pi also matches a skill by its folder, and a glob exclusion; turning it on clears both kinds of override.
        #expect(!ProjectResourcePatterns.isEnabled(skill, entries: ["-skills/pdf-tools"], base: base))
        #expect(!ProjectResourcePatterns.isEnabled(skill, entries: ["!pdf-*"], base: base))
        #expect(ProjectResourcePatterns.isEnabled(skill, entries: ["!pdf-*", "+skills/pdf-tools"], base: base))
        #expect(ProjectResourcePatterns.setting(true, path: skill, global: false, base: base, in: off + ["-skills/pdf-tools"]) == ["../shared/skills"])
    }

    @Test func aResourceInTheOtherFolderIsNamedRelativeToTheSettingsFile() {
        let prompt = "/code/payments/.shepherd/prompts/review.md"
        let off = ProjectResourcePatterns.setting(false, path: prompt, global: false, base: base, in: [])
        #expect(off == ["-../.shepherd/prompts/review.md"])
        #expect(!ProjectResourcePatterns.isEnabled(prompt, entries: off, base: base))
    }

    @Test func aGlobalResourceIsOverriddenByItsFullPathOnlyWhereTheSpaceDiffers() {
        let global = "/support/pi/extensions/workspace-shortcuts.ts"
        let off = ProjectResourcePatterns.setting(false, path: global, global: true, inherited: true, base: base, in: [])
        #expect(off == [global, "-" + global])
        #expect(!ProjectResourcePatterns.isEnabled(global, entries: off, base: base, otherwise: true))
        #expect(ProjectResourcePatterns.setting(true, path: global, global: true, inherited: true, base: base, in: off).isEmpty)
        let on = ProjectResourcePatterns.setting(true, path: global, global: true, inherited: false, base: base, in: [])
        #expect(ProjectResourcePatterns.isEnabled(global, entries: on, base: base, otherwise: false))
    }
}

/// Subprojects (Settings ▸ Projects, parents and subprojects): which project a folder sits inside,
/// and the listing's new fields across an older host.
@Suite("Project nesting")
struct ProjectNestingTests {
    @Test(arguments: [
        ("/code/acme/apps/web", "/code/acme"),
        ("/code/acme/apps/web/admin", "/code/acme"),
        ("/code/acme", nil),
        ("/code/acme-landing", nil),
        ("/code/payments", nil),
    ] as [(String, String?)])
    func aProjectsParentIsTheOutermostProjectThatHoldsIt(directory: String, parent: String?) {
        let projects = ["/code/acme", "/code/acme/apps/web", "/code/acme/apps/web/admin", "/code/acme-landing", "/code/payments", "/"]
        #expect(ProjectNesting.parent(of: directory, among: projects) == parent)
    }

    @Test func anOlderHostsListingDecodesWithNoParentAndNoServers() throws {
        let old = #"{"directory":"/a","name":"a","displayPath":"~/a","summary":"AGENTS.md only","minimal":true}"#
        let project = try JSONDecoder().decode(ProjectSummary.self, from: Data(old.utf8))
        #expect(project.parent == nil && project.mcpServers.isEmpty && project.inheritedMCP.isEmpty)
        let nested = ProjectSummary(directory: "/a/web", name: "web", displayPath: "~/a/web", summary: "1 MCP",
                                    parent: "/a", mcpServers: ["local"], inheritedMCP: ["docs", "shared"])
        #expect(try JSONDecoder().decode(ProjectSummary.self, from: JSONEncoder().encode(nested)) == nested)
    }
}
