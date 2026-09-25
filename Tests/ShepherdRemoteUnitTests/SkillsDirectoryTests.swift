import Foundation
import Testing
@testable import ShepherdRemote

/// skills.sh's answers as Browse reads them: search (no key), the ranked lists (`/api/v1`), and a
/// skill's files; and install counts as the directory writes them.
@Suite("Skills directory")
struct SkillsDirectoryTests {
    @Test func searchResultsNameTheirRepositoryMostInstalledFirst() throws {
        let json = #"""
        {"skills":[
          {"id":"pg-query-tuning","name":"pg-query-tuning","source":"dbkit/skills","installs":24000},
          {"id":"supabase-postgres-best-practices","name":"supabase-postgres-best-practices","source":"supabase/agent-skills","installs":71000},
          {"id":"orphan","name":"orphan","installs":5}
        ]}
        """#
        let skills = try SkillsDirectory.decodeSearch(Data(json.utf8))
        #expect(skills.map(\.slug) == ["supabase-postgres-best-practices", "pg-query-tuning"])
        #expect(skills.first?.id == "supabase/agent-skills/supabase-postgres-best-practices")
        #expect(skills.first?.official == false)
    }

    @Test func rankedListsReadSlugOrId() throws {
        let json = #"""
        {"data":[
          {"id":"a1","slug":"find-skills","name":"find-skills","source":"vercel-labs/skills","installs":3600000,"sourceType":"github"},
          {"id":"skill-creator","source":"anthropics/skills","installs":131000}
        ],"pagination":{"page":1,"perPage":50,"total":2,"hasMore":false}}
        """#
        let skills = try SkillsDirectory.decodeRanked(Data(json.utf8))
        #expect(skills.map(\.slug) == ["find-skills", "skill-creator"])
        #expect(skills.map(\.name) == ["find-skills", "skill-creator"])
    }

    @Test func aSkillsFilesKeepTheirPathsInItsFolder() throws {
        let json = #"{"files":[{"path":"SKILL.md","contents":"---\nname: pdf\n---\n"},{"path":"scripts/fill.py"}],"hash":"abc"}"#
        let files = try SkillsDirectory.decodeFiles(Data(json.utf8))
        #expect(files == [DirectoryFile(path: "SKILL.md", contents: "---\nname: pdf\n---\n"), DirectoryFile(path: "scripts/fill.py", contents: "")])
    }

    @Test func theRankingsNeedAKey() async {
        await #expect(throws: SkillsDirectoryError.needsKey) {
            try await SkillsDirectory(key: "  ").ranked(.trending)
        }
    }

    @Test(arguments: [(980, "980"), (1_000, "1K"), (1_200, "1.2K"), (8_400, "8.4K"), (71_000, "71K"), (312_000, "312K"),
                      (3_600_000, "3.6M")])
    func installsReadAsTheDirectoryWritesThem(count: Int, text: String) {
        #expect(DirectoryPresentation.installs(count) == text)
    }

    @Test func aSearchLightsEveryMatchInAName() {
        let name = "postgres-rls-postgres"
        let ranges = DirectoryPresentation.matches(of: "Postgres", in: name)
        #expect(ranges.map { String(name[$0]) } == ["postgres", "postgres"])
        #expect(DirectoryPresentation.matches(of: " ", in: name).isEmpty)
    }

    @Test func aSkillsPageIsItsRepositoryAndName() {
        let skill = DirectorySkill(slug: "pdf", name: "pdf", source: "anthropics/skills", installs: 1)
        #expect(SkillsDirectory.page(of: skill).absoluteString == "https://skills.sh/anthropics/skills/pdf")
    }
}
