import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Settings ▸ Skills' text rules: a SKILL.md's frontmatter read the way pi reads it, the one line
/// Only with /skill changes, folder names, what skills cost in every prompt, and the repositories
/// people type.
@Suite("Skills text")
struct SkillsTextTests {
    @Test(arguments: [
        ("---\nname: pdf\ndescription: Read, fill, merge and split PDFs.\n---\n# PDF\n",
         "pdf", "Read, fill, merge and split PDFs.", false),
        // A folded description, and the flag as a YAML boolean.
        ("---\nname: pdf-tools\ndescription: >\n  Extract text and tables.\n  Use when reading PDFs.\ndisable-model-invocation: true\n---\n",
         "pdf-tools", "Extract text and tables. Use when reading PDFs.", true),
        // Quoted values, a doubled single quote inside one.
        ("---\nname: \"docx\"\ndescription: 'It''s for Word: .docx files'\n---\n", "docx", "It's for Word: .docx files", false),
        // A plain description on two lines; a nested map after it is not a field of its own.
        ("---\ndescription: Postgres performance and security.\n  Use when writing queries.\nname: pg\nmetadata:\n  author: x\n---\n",
         "pg", "Postgres performance and security. Use when writing queries.", false),
        // pi takes only a boolean: a quoted "true" leaves the skill automatic.
        ("---\ndisable-model-invocation: \"true\"\n---\n", nil, nil, false),
        ("\u{FEFF}---\r\nname: x\r\ndescription: y\r\n---\r\n", "x", "y", false),
        ("# Just markdown\n", nil, nil, false),
        ("---\ndescription: |\n  Line one\n  Line two\n---\n", nil, "Line one\nLine two", false),
        ("---\nname: a # the name\ndescription: \"Say \\\"hi\\\" first\"\n---\n", "a", "Say \"hi\" first", false),
    ] as [(String, String?, String?, Bool)])
    func frontmatterReadsNameDescriptionAndHowItIsUsed(text: String, name: String?, description: String?, slashOnly: Bool) {
        let frontmatter = SkillsText.frontmatter(text)
        #expect(frontmatter.name == name)
        #expect(frontmatter.description == description)
        #expect(frontmatter.invocation == (slashOnly ? .slashOnly : .automatic))
    }

    @Test func onlyWithSlashAddsTheFlagAndAutomaticallyTakesItOut() {
        let original = "---\nname: pdf\ndescription: d\n---\nbody\n"
        let slashOnly = SkillsText.setting(.slashOnly, in: original)
        #expect(slashOnly == "---\nname: pdf\ndescription: d\ndisable-model-invocation: true\n---\nbody\n")
        #expect(SkillsText.invocation(slashOnly) == .slashOnly)
        #expect(SkillsText.setting(.automatic, in: slashOnly) == original)
        // Already automatic: the file is left exactly as it was.
        #expect(SkillsText.setting(.automatic, in: original) == original)
    }

    @Test(arguments: [
        // A `false` already there becomes `true` where it stands.
        ("---\ndisable-model-invocation: false\nname: a\n---\n", "---\ndisable-model-invocation: true\nname: a\n---\n"),
        // No frontmatter: one is added.
        ("# x\n", "---\ndisable-model-invocation: true\n---\n# x\n"),
        ("", "---\ndisable-model-invocation: true\n---\n"),
        // Line endings are kept.
        ("---\r\nname: a\r\n---\r\n", "---\r\nname: a\r\ndisable-model-invocation: true\r\n---\r\n"),
    ])
    func onlyWithSlashKeepsTheRestOfTheFile(original: String, expected: String) {
        #expect(SkillsText.setting(.slashOnly, in: original) == expected)
    }

    @Test(arguments: [
        ("pdf", true), ("pdf-tools", true), ("a1", true), ("PDF", false), ("-pdf", false), ("pdf-", false),
        ("pdf--x", false), ("", false), ("pdf tools", false), (String(repeating: "a", count: 65), false),
    ])
    func namesFollowTheSpec(name: String, valid: Bool) {
        #expect(SkillsText.isValidName(name) == valid)
    }

    @Test(arguments: [("PDF Tools", "pdf-tools"), ("my_skill!", "my-skill"), ("  ", ""), ("Émoji ✨ skill", "moji-skill")])
    func slugsKeepLettersDigitsAndHyphens(text: String, slug: String) {
        #expect(SkillsText.slug(text) == slug)
    }

    /// A skill installs into a folder named after its frontmatter `name`, else its folder in the
    /// repository, else the repository.
    @Test(arguments: [
        (SkillFrontmatter(name: "vercel-react-best-practices"), "skills/react-best-practices", "vercel-labs/agent-skills",
         "vercel-react-best-practices"),
        (SkillFrontmatter(name: "PDF Tools"), "skills/pdf", "anthropics/skills", "pdf-tools"),
        (SkillFrontmatter(), "skills/react-best-practices", "vercel-labs/agent-skills", "react-best-practices"),
        (SkillFrontmatter(), "", "acme/Solo_Skill", "solo-skill"),
        (SkillFrontmatter(name: "✨"), "", "", "skill"),
    ] as [(SkillFrontmatter, String, String, String)])
    func aSkillsFolderIsNamedAfterItsName(frontmatter: SkillFrontmatter, path: String, repo: String, folder: String) {
        #expect(SkillsText.folderName(for: frontmatter, path: path, repo: repo) == folder)
    }

    /// Only automatic skills that are on sit in every prompt, after pi's few lines about them.
    @Test func onlyAutomaticSkillsThatAreOnCostTokensInEveryPrompt() {
        let pdf = InstalledSkill(name: "pdf", summary: "Read, fill, merge and split PDFs.", updatedAt: 0)
        let off = InstalledSkill(name: "changelog", summary: "Drafts a CHANGELOG entry.", isOn: false, updatedAt: 0)
        let slash = InstalledSkill(name: "go-table-tests", summary: "House style.", invocation: .slashOnly, updatedAt: 0)
        #expect(SkillsText.promptTokens(name: "pdf", summary: "Read, fill, merge and split PDFs.") == 44)
        #expect(SkillsText.promptPreambleTokens == 88)
        #expect(SkillsText.promptTokens([pdf, off, slash]) == 88 + 44)
        #expect(SkillsText.promptTokens([off, slash]) == 0)
        #expect(SkillsText.promptTokens(name: "pdf", summary: String(repeating: "x", count: 400))
            > SkillsText.promptTokens(name: "pdf", summary: "Read, fill, merge and split PDFs."))
    }

    @Test(arguments: [(0, "none"), (1, "~1 token"), (42, "~42 tokens"), (614, "~610 tokens"), (615, "~620 tokens"),
                      (1_874, "~1,900 tokens"), (1_950, "~2,000 tokens")])
    func tokenCountsAreRoundedAsThePageSaysThem(tokens: Int, note: String) {
        #expect(SkillsText.tokenNote(tokens) == note)
    }

    @Test(arguments: [
        ("anthropics/skills", "anthropics/skills", "https://github.com/anthropics/skills.git", nil, nil),
        ("https://github.com/anthropics/skills.git", "anthropics/skills", "https://github.com/anthropics/skills.git", nil, nil),
        ("github.com/anthropics/skills/", "anthropics/skills", "https://github.com/anthropics/skills.git", nil, nil),
        ("https://github.com/anthropics/skills/tree/main/skills/pdf", "anthropics/skills", "https://github.com/anthropics/skills.git",
         "skills/pdf", nil),
        ("git@github.com:acme/platform-skills.git", "acme/platform-skills", "https://github.com/acme/platform-skills.git", nil, nil),
        ("https://skills.sh/vercel-labs/skills/find-skills", "vercel-labs/skills", "https://github.com/vercel-labs/skills.git",
         nil, "find-skills"),
        ("https://gitlab.com/acme/skills", "https://gitlab.com/acme/skills", "https://gitlab.com/acme/skills", nil, nil),
        ("file:///tmp/skills-repo", "file:///tmp/skills-repo", "file:///tmp/skills-repo", nil, nil),
    ] as [(String, String, String, String?, String?)])
    func aRepositoryIsReadFromWhatSomeoneTyped(input: String, repo: String, cloneURL: String, path: String?, skill: String?) throws {
        let reference = try #require(SkillsText.reference(input))
        #expect(reference == SkillRepoReference(repo: repo, cloneURL: cloneURL, path: path, skill: skill))
    }

    @Test(arguments: ["", "~/Developer/skills", "/Users/me/skills", "find me a pdf skill", "pdf"])
    func aFolderOrWordsAreNoRepository(input: String) {
        #expect(SkillsText.reference(input) == nil)
    }

    /// A skill's files as its chips show them: SKILL.md first, then files by name, then folders
    /// with how many files each holds; hidden ones left out.
    @Test func aSkillsEntriesPutSkillMDFirstThenFilesThenFolders() {
        let entries = SkillsText.entries(paths: ["scripts/fill.py", "reference.md", "SKILL.md", "scripts/lib/merge.py", ".git/HEAD",
                                                 "assets/logo.png", "forms.md"])
        #expect(entries.map(\.name) == ["SKILL.md", "forms.md", "reference.md", "assets", "scripts"])
        #expect(entries.map(\.isDirectory) == [false, false, false, true, true])
        #expect(entries.map(\.fileCount) == [1, 1, 1, 1, 2])
    }

    @Test func whatChangedOpensGitHubsComparison() {
        #expect(SkillsText.compareURL(repo: "anthropics/skills", from: "3f2a91c", to: "8c04e1d")?.absoluteString
            == "https://github.com/anthropics/skills/compare/3f2a91c...8c04e1d")
        #expect(SkillsText.compareURL(repo: "https://gitlab.com/acme/skills", from: "a", to: "b") == nil)
        #expect(SkillsText.reference("anthropics/skills")?.gitHub == "anthropics/skills")
        #expect(SkillsText.reference("https://gitlab.com/acme/skills")?.gitHub == nil)
        #expect(SkillsText.shortCommit("8c04e1d0a2b3") == "8c04e1d")
    }
}
