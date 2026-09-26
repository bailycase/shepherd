import Foundation
import Testing
import ShepherdProtocol
import ShepherdTestKit
@testable import ShepherdRemote

/// Settings ▸ Skills' read-only groups: the skills the first host's pi loads from its own setup
/// and its packages, beside the installed ones, in the filter, the search, the counts and what
/// every prompt costs.
@MainActor
@Suite("Client skills: pi's own")
struct ClientPiSkillsTests {
    static let pi = PiSkills(agentDirectory: "~/.pi/agent", skills: [
        PiSkill(name: "beta", summary: "pi's beta.", path: "~/.pi/agent/skills/beta/SKILL.md", origin: .agentDirectory),
        PiSkill(name: "gamma", summary: "From settings.", path: "~/code/skills/gamma/SKILL.md", origin: .settingsPath,
                invocation: .slashOnly),
        PiSkill(name: "delta", summary: "Package delta.", path: "~/.pi/agent/npm/node_modules/@acme/skills/delta/SKILL.md",
                origin: .package, package: "@acme/skills"),
        PiSkill(name: "pdf", summary: "Package pdf.", path: "~/.pi/agent/npm/node_modules/@acme/skills/pdf/SKILL.md",
                origin: .package, package: "@acme/skills", shadowedBy: "~/.agents/skills/pdf/SKILL.md"),
    ], shadowedInstalled: ["docx": "~/.pi/agent/skills/docx/SKILL.md"])

    static func hosts(pi: PiSkills? = Self.pi) -> ([SkillsHost], ClientSkills) {
        let client = FakeSkillsClient([ClientSkillsTests.skill("docx", summary: "Word files."), ClientSkillsTests.skill("pdf", summary: "PDFs.")],
                                      pi: pi)
        return ([ClientSkillsTests.host("This Mac", client)], ClientSkills(defaults: ScratchDefaults()))
    }

    @Test func piSkillsAreGroupedBySetupThenPackages() async {
        let (hosts, model) = Self.hosts()
        await model.refresh(hosts)
        let groups = model.piGroups(in: hosts)
        #expect(groups.map(\.kind) == [.setup, .packages])
        #expect(groups[0].rows.map(\.name) == ["beta", "gamma"])
        #expect(groups[1].rows.map(\.name) == ["delta", "pdf"])
        #expect(model.pi(in: hosts)?.host.name == "This Mac")
    }

    /// An installed skill pi passes over for one of its own says which it uses instead.
    @Test func anInstalledSkillPiPassesOverIsMarked() async {
        let (hosts, model) = Self.hosts()
        await model.refresh(hosts)
        #expect(model.row("docx", in: hosts)?.shadowedBy == "~/.pi/agent/skills/docx/SKILL.md")
        #expect(model.row("pdf", in: hosts)?.shadowedBy == nil)
    }

    @Test(arguments: [
        (ClientSkills.Filter.all, "", ["beta", "gamma", "delta", "pdf"]),
        (.on, "", ["beta", "gamma", "delta"]),
        (.updates, "", []),
        (.all, "acme", ["delta", "pdf"]),
        (.all, "settings", ["gamma"]),
        (.all, "nothing", []),
    ] as [(ClientSkills.Filter, String, [String])])
    func theFilterAndTheSearchNarrowPisSkills(filter: ClientSkills.Filter, query: String, names: [String]) async {
        let (hosts, model) = Self.hosts()
        await model.refresh(hosts)
        #expect(model.piGroups(in: hosts, filter: filter, query: query).flatMap(\.rows).map(\.name) == names)
    }

    @Test func theCountsIncludePisSkills() async {
        let (hosts, model) = Self.hosts()
        await model.refresh(hosts)
        #expect(model.count(.all, in: hosts) == 6)
        #expect(model.count(.on, in: hosts) == 5)
        #expect(model.count(.updates, in: hosts) == 0)
    }

    /// Every prompt carries each automatic skill the agent loads: the installed ones pi uses and
    /// pi's own, never one a same-named skill shadows, never a /skill one.
    @Test func everyPromptCountsEverySkillTheAgentLoads() async {
        let (hosts, model) = Self.hosts()
        await model.refresh(hosts)
        #expect(model.loadedSkills(in: hosts).map(\.name) == ["pdf", "beta", "gamma", "delta"])
        let expected = SkillsText.promptTokens([
            ("pdf", "PDFs.", "~/.agents/skills/pdf/SKILL.md"),
            ("beta", "pi's beta.", "~/.pi/agent/skills/beta/SKILL.md"),
            ("delta", "Package delta.", "~/.pi/agent/npm/node_modules/@acme/skills/delta/SKILL.md"),
        ])
        #expect(model.promptTokens(in: hosts) == expected)
        let (plain, bare) = Self.hosts(pi: nil)
        await bare.refresh(plain)
        #expect(bare.promptTokens(in: plain) < expected)
    }

    /// A host that predates reporting pi's skills shows none, and says so through `pi(in:)`.
    @Test func aHostThatReportsNoneShowsNoGroups() async {
        let (hosts, model) = Self.hosts(pi: nil)
        await model.refresh(hosts)
        #expect(model.pi(in: hosts) == nil)
        #expect(model.piGroups(in: hosts).isEmpty)
        #expect(model.count(.all, in: hosts) == 2)
    }

    @Test func piSkillsInWords() {
        #expect(SkillsPresentation.groupTitle(.setup) == "From your pi setup")
        #expect(SkillsPresentation.groupTitle(.packages) == "From pi packages")
        #expect(SkillsPresentation.source(Self.pi.skills[0]) == "~/.pi/agent/skills")
        #expect(SkillsPresentation.source(Self.pi.skills[2]) == "@acme/skills")
        #expect(SkillsPresentation.folder(of: "~/.pi/agent/skills/notes.md") == "~/.pi/agent/skills")
        #expect(SkillsPresentation.shadowNote("~/.agents/skills/pdf/SKILL.md") == "Not used: pi uses the one in ~/.agents/skills.")
        #expect(SkillsPresentation.automaticCount(3) == "3 automatic skills. Full files load only when used.")
        #expect(SkillsPresentation.mobileSummary(Self.pi.skills[1]) == "/skill only · From settings.")
        #expect(SkillsPresentation.mobileSummary(Self.pi.skills[3]) == "Not used: pi uses the one in ~/.agents/skills.")
        #expect(SkillsPresentation.piFootnote(host: "studio").hasPrefix("Read-only: from studio’s own pi"))
    }

    @Test(arguments: ["pi_not_found", "node_not_found", "pi_unsupported", "timed_out", "failed", "something_new"])
    func everyProblemHasWords(problem: String) {
        #expect(!SkillsPresentation.piProblem(problem).isEmpty)
    }
}
