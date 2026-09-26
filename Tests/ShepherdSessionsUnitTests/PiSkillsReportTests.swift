import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// What pi's loader reported, as Settings ▸ Skills lists it: the skills outside Shepherd's folder
/// grouped by where they come from, the ones a same-named skill shadows marked, and Shepherd's own
/// left to the Installed group. Paths are fictional, so nothing on disk is read.
@Suite("pi's own skills, as reported")
struct PiSkillsReportTests {
    typealias Entry = PiSkillsLoader.Output.Entry

    static let home = "/Users/ada"
    static let installed = "/Users/ada/.agents/skills"

    static func entry(_ name: String, _ path: String, source: String = "auto", origin: String = "top-level", scope: String = "user",
                      baseDir: String? = nil, packageName: String? = nil, slashOnly: Bool = false, winner: String? = nil) -> Entry {
        Entry(name: name, description: "\(name) does things.", path: path, source: source, origin: origin, scope: scope,
              baseDir: baseDir, packageName: packageName, slashOnly: slashOnly, winner: winner)
    }

    static func report(_ output: PiSkillsLoader.Output) -> PiSkills {
        PiSkillsLoader.report(output, installedDirectories: [installed], home: home, agentDirectory: "/Users/ada/.pi/agent")
    }

    @Test func eachSkillOutsideShepherdsFolderIsListedByWhereItComesFrom() {
        let output = PiSkillsLoader.Output(agentDir: "/Users/ada/.pi/agent", skills: [
            Self.entry("gamma", "/Users/ada/code/skills/gamma/SKILL.md", source: "local"),
            Self.entry("beta", "/Users/ada/.pi/agent/skills/beta/SKILL.md", baseDir: "/Users/ada/.pi/agent", slashOnly: true),
            Self.entry("pdf", "/Users/ada/.agents/skills/pdf/SKILL.md", baseDir: "/Users/ada/.agents"),
            Self.entry("delta", "/Users/ada/.pi/agent/npm/node_modules/@acme/skills/delta/SKILL.md", source: "npm:@acme/skills",
                       origin: "package", baseDir: "/Users/ada/.pi/agent/npm/node_modules/@acme/skills", packageName: "@acme/skills"),
        ])
        let pi = Self.report(output)
        #expect(pi.agentDirectory == "~/.pi/agent")
        #expect(pi.skills.map(\.name) == ["beta", "gamma", "delta"])
        #expect(pi.skills.map(\.origin) == [.agentDirectory, .settingsPath, .package])
        #expect(pi.skills[0].path == "~/.pi/agent/skills/beta/SKILL.md")
        #expect(pi.skills[0].invocation == .slashOnly && pi.skills[1].invocation == .automatic)
        #expect(pi.skills.map(\.package) == [nil, nil, "@acme/skills"])
        #expect(pi.skills.allSatisfy { $0.isUsed })
        #expect(pi.shadowedInstalled.isEmpty && pi.problem == nil)
    }

    /// pi keeps the first skill of a name. An installed one it passes over is marked on the
    /// Installed row; an outside one follows the one pi uses, marked.
    @Test func aSkillPiPassesOverIsMarkedWithTheOneItUses() {
        let output = PiSkillsLoader.Output(skills: [
            Self.entry("alpha", "/Users/ada/.pi/agent/skills/alpha/SKILL.md"),
            Self.entry("delta", "/Users/ada/.agents/skills/delta/SKILL.md"),
        ], shadowed: [
            Self.entry("alpha", "/Users/ada/.agents/skills/alpha/SKILL.md", winner: "/Users/ada/.pi/agent/skills/alpha/SKILL.md"),
            Self.entry("delta", "/opt/pkg/skills/delta/SKILL.md", source: "/opt/pkg", origin: "package", baseDir: "/opt/pkg",
                       winner: "/Users/ada/.agents/skills/delta/SKILL.md"),
            Self.entry("alpha", "/opt/pkg/skills/alpha/SKILL.md", source: "/opt/pkg", origin: "package", baseDir: "/opt/pkg",
                       winner: "/Users/ada/.pi/agent/skills/alpha/SKILL.md"),
        ])
        let pi = Self.report(output)
        #expect(pi.shadowedInstalled == ["alpha": "~/.pi/agent/skills/alpha/SKILL.md"])
        #expect(pi.skills.map(\.name) == ["alpha", "alpha", "delta"])
        #expect(pi.skills.map(\.isUsed) == [true, false, false])
        #expect(pi.skills[2].shadowedBy == "~/.agents/skills/delta/SKILL.md")
        #expect(pi.skills[2].package == "pkg")
    }

    /// A repository's skills (a trusted project) or a command line's never reach a global list.
    @Test func onlyTheUsersOwnScopeIsListed() {
        let output = PiSkillsLoader.Output(skills: [
            Self.entry("repo", "/Users/ada/code/app/.pi/skills/repo/SKILL.md", scope: "project"),
            Self.entry("cli", "/tmp/cli/SKILL.md", source: "cli", scope: "temporary"),
            Self.entry("mine", "/Users/ada/.pi/agent/skills/mine/SKILL.md"),
        ])
        #expect(Self.report(output).skills.map(\.name) == ["mine"])
    }

    @Test func whyPiCouldNotBeReadCarriesThrough() {
        let pi = Self.report(PiSkillsLoader.Output(problem: "pi_not_found"))
        #expect(pi.problem == "pi_not_found")
        #expect(pi.skills.isEmpty)
        #expect(pi.agentDirectory == "~/.pi/agent")
    }

    @Test(arguments: [
        (Entry(name: "x", path: "", source: "npm:@acme/pi-skills@1.2.0", origin: "package"), "@acme/pi-skills"),
        (Entry(name: "x", path: "", source: "npm:pi-tools", origin: "package"), "pi-tools"),
        (Entry(name: "x", path: "", source: "git:github.com/acme/skills@v1", origin: "package"), "acme/skills"),
        (Entry(name: "x", path: "", source: "https://github.com/acme/skills.git", origin: "package"), "acme/skills"),
        (Entry(name: "x", path: "", source: "git@github.com:acme/skills", origin: "package"), "acme/skills"),
        (Entry(name: "x", path: "", source: "./vendor/team-skills", origin: "package"), "team-skills"),
        (Entry(name: "x", path: "", source: "npm:whatever", origin: "package", packageName: "@acme/named"), "@acme/named"),
    ] as [(Entry, String)])
    func aPackageIsNamedAsPeopleKnowIt(entry: Entry, label: String) {
        #expect(PiSkillsLoader.packageLabel(entry) == label)
    }

    @Test(arguments: [
        ("/Users/ada/.pi/agent", "~/.pi/agent"),
        ("/Users/ada", "~"),
        ("/Users/adam/x", "/Users/adam/x"),
        ("/opt/skills", "/opt/skills"),
    ])
    func pathsReadWithTheHomeAsATilde(path: String, shown: String) {
        #expect(PiSkillsLoader.abbreviate(path, home: Self.home) == shown)
        #expect(PiSkillsLoader.abbreviate(path, home: Self.home + "/") == shown)
    }

    /// The script's answer decodes whatever it leaves out.
    @Test func theScriptsAnswerDecodesWithDefaults() throws {
        let json = #"{"agentDir":"/a","version":"0.87.1","skills":[{"name":"n","path":"/a/skills/n/SKILL.md"}]}"#
        let output = try JSONDecoder().decode(PiSkillsLoader.Output.self, from: Data(json.utf8))
        #expect(output.skills.map(\.name) == ["n"])
        #expect(output.shadowed.isEmpty && output.problem == nil)
        let pi = PiSkillsLoader.report(output, installedDirectories: [Self.installed], home: Self.home, agentDirectory: "/a")
        #expect(pi.skills.map(\.origin) == [.settingsPath])
        #expect(pi.skills[0].summary.isEmpty && pi.skills[0].invocation == .automatic)
    }

    /// What a result depends on, so the page reads pi again when one changes: each skill's file,
    /// its folder and the folder beside it, and its package.
    @Test func aResultWatchesTheFoldersItCameFrom() {
        let output = PiSkillsLoader.Output(skills: [
            Self.entry("beta", "/p/agent/skills/beta/SKILL.md", baseDir: "/p/agent"),
        ])
        #expect(PiSkillsLoader.watched(output) == ["/p/agent/skills/beta/SKILL.md", "/p/agent/skills/beta", "/p/agent/skills", "/p/agent"])
    }
}
