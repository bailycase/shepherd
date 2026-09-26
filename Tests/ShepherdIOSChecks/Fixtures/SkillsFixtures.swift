import Foundation
import ShepherdCore
import ShepherdProtocol

// Settings ▸ Skills (MobileSkills): the skills every fixture host keeps, and a repository's.
extension FixtureData {
    /// The usual hosts, with Studio answering Add from repo's look-up of anthropics/skills.
    static func skillsRepoHosts() -> [FixtureHostData] {
        hosts().map { host in
            var host = host
            if host.id == studio { host.repoSkills = skillsRepo() }
            return host
        }
    }

    /// anthropics/skills as a host finds it: three of its skills already installed (one with an
    /// update), the rest new.
    static func skillsRepo() -> RepoSkills {
        func skill(_ name: String, _ summary: String, _ files: [SkillFileEntry] = [SkillFileEntry(name: "SKILL.md")]) -> RepoSkill {
            RepoSkill(path: "skills/\(name)", name: name, summary: summary, instructions: "---\nname: \(name)\ndescription: \(summary)\n---\n",
                      files: files)
        }
        return RepoSkills(repo: "anthropics/skills", branch: "main", commit: "8c04e1d5b2a9f06c", skills: [
            skill("docx", "Create and edit Word documents, with tracked changes and comments."),
            skill("frontend-design", "Production-grade UI that doesn’t look generic."),
            skill("mcp-builder", "Build MCP servers that give an agent new tools."),
            skill("pdf", "Read, fill, merge and split PDFs.",
                  [SkillFileEntry(name: "SKILL.md"), SkillFileEntry(name: "scripts", isDirectory: true, fileCount: 8)]),
            skill("pptx", "Build and edit slide decks."),
            skill("skill-creator", "Write a new skill, and check it before you share it."),
            skill("webapp-testing", "Tests local web apps with Playwright."),
            skill("xlsx", "Spreadsheets with formulas, formatting and charts."),
        ])
    }

    /// The board's eight skills: six from repositories (two with an update waiting), two copied in
    /// by hand and used only through /skill, one of them off.
    static func skills(checkedAgo: TimeInterval = 7_200) -> SkillsSnapshot {
        let anthropic = "anthropics/skills"
        return SkillsSnapshot(
            directory: "~/.agents/skills",
            skills: [
                InstalledSkill(name: "changelog", summary: "Drafts a CHANGELOG entry since the last tag.", isOn: false,
                               invocation: .slashOnly, updatedAt: 1_781_179_200, files: [SkillFileEntry(name: "SKILL.md")]),
                InstalledSkill(name: "find-skills", summary: "Finds a skill on skills.sh when none fits.",
                               source: SkillSource(repo: "vercel-labs/skills", path: "skills/find-skills", commit: "b71e0c2",
                                                   committedAt: 1_788_350_400),
                               updatedAt: 1_788_350_400, files: [SkillFileEntry(name: "SKILL.md")]),
                InstalledSkill(name: "frontend-design", summary: "Production-grade UI that doesn’t look generic.",
                               source: SkillSource(repo: anthropic, path: "skills/frontend-design", commit: "5d1a7f3",
                                                   committedAt: 1_789_732_800),
                               updatedAt: 1_789_732_800, files: [SkillFileEntry(name: "SKILL.md"), SkillFileEntry(name: "LICENSE.txt")]),
                InstalledSkill(name: "go-table-tests", summary: "House style for table-driven Go tests.", invocation: .slashOnly,
                               updatedAt: 1_789_905_600, files: [SkillFileEntry(name: "SKILL.md")]),
                InstalledSkill(name: "pdf", summary: "Read, fill, merge and split PDFs.",
                               source: SkillSource(repo: anthropic, path: "skills/pdf", commit: "3f2a91c", committedAt: 1_788_091_200),
                               updatedAt: 1_788_091_200,
                               files: [SkillFileEntry(name: "SKILL.md"), SkillFileEntry(name: "reference.md"), SkillFileEntry(name: "forms.md"),
                                       SkillFileEntry(name: "scripts", isDirectory: true, fileCount: 8)],
                               update: SkillUpdate(commit: "8c04e1d", committedAt: 1_790_078_400, filesChanged: 3)),
                InstalledSkill(name: "sqlc-queries", summary: "Our sqlc conventions, migrations first.",
                               source: SkillSource(repo: "acme/platform-skills", path: "sqlc-queries", commit: "a90d3e4",
                                                   committedAt: 1_788_350_400),
                               updatedAt: 1_788_350_400, files: [SkillFileEntry(name: "SKILL.md")],
                               update: SkillUpdate(commit: "c2f8b61", committedAt: 1_789_819_200, filesChanged: 1)),
                InstalledSkill(name: "vercel-react-best-practices", summary: "React and Next.js performance rules.",
                               source: SkillSource(repo: "vercel-labs/agent-skills", path: "skills/react-best-practices", commit: "e40c9aa",
                                                   committedAt: 1_789_214_400),
                               updatedAt: 1_789_214_400, files: [SkillFileEntry(name: "SKILL.md"),
                                                                SkillFileEntry(name: "rules", isDirectory: true, fileCount: 12)]),
                InstalledSkill(name: "webapp-testing", summary: "Tests local web apps with Playwright.",
                               source: SkillSource(repo: anthropic, path: "skills/webapp-testing", commit: "3f2a91c",
                                                   committedAt: 1_788_091_200),
                               updatedAt: 1_788_091_200, files: [SkillFileEntry(name: "SKILL.md"),
                                                                SkillFileEntry(name: "scripts", isDirectory: true, fileCount: 2)]),
            ],
            checkedAt: Date().timeIntervalSince1970 - checkedAgo,
            pi: PiSkills(agentDirectory: "~/.pi/agent", skills: [
                PiSkill(name: "review-pr", summary: "Reviews a pull request the way the team does.",
                        path: "~/.pi/agent/skills/review-pr/SKILL.md", origin: .agentDirectory),
                PiSkill(name: "release-notes", summary: "Drafts release notes from the merged pull requests.",
                        path: "~/.pi/agent/skills/release-notes/SKILL.md", origin: .agentDirectory, invocation: .slashOnly),
                PiSkill(name: "postgres", summary: "Query plans, indexes and locks for Postgres.",
                        path: "~/.pi/agent/npm/node_modules/@acme/pi-db-skills/skills/postgres/SKILL.md", origin: .package,
                        package: "@acme/pi-db-skills"),
            ]))
    }
}
