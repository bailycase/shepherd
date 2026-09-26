import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Settings ▸ Skills on a host, against real git: a repository's skills are looked up and
/// installed into the folder pi reads, turned off and on by moving them out of it and back, used
/// only through /skill by a line in SKILL.md, removed with undo, and updated when their folder in
/// the repository changes.
@Suite("Skills store", .integrationTimeLimit)
struct SkillsStoreTests {
    static let pdf = "---\nname: pdf\ndescription: Read, fill, merge and split PDFs.\n---\n# PDF\n\nRun scripts/run.sh.\n"
    static let docx = "---\nname: docx\ndescription: Create and edit Word documents.\n---\n# Word\n"
    static let react = "---\nname: vercel-react\ndescription: React performance rules.\n---\n# React\n"

    struct Fixture {
        let store: SkillsStore
        let directory: URL
        let state: URL
        let repo: URL
        var url: String { "file://" + repo.path }

        init(files: [String: String] = ["README.md": "# skills\n", "skills/pdf/SKILL.md": SkillsStoreTests.pdf,
                                         "skills/pdf/scripts/run.sh": "#!/bin/sh\necho pdf\n",
                                         "skills/docx/SKILL.md": SkillsStoreTests.docx]) throws {
            repo = try makeScratchRepo(files: files)
            if files["skills/pdf/scripts/run.sh"] != nil {
                // Executable on disk too, so a later `git add` keeps the mode.
                let script = repo.appendingPathComponent("skills/pdf/scripts/run.sh").path
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
                try git(["add", "--", "skills/pdf/scripts/run.sh"], in: repo)
                try git(["commit", "-qm", "executable"], in: repo)
            }
            let root = try makeScratchDirectory("skills")
            directory = root.appendingPathComponent("agents-skills", isDirectory: true)
            state = root.appendingPathComponent("support-skills", isDirectory: true)
            store = SkillsStore(directory: directory, stateDirectory: state)
        }

        func head() throws -> String {
            try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Changes one file in the repository and commits it alone.
        func commit(_ path: String, _ contents: String) throws {
            try contents.write(to: repo.appendingPathComponent(path), atomically: true, encoding: .utf8)
            try git(["add", "--", path], in: repo)
            try git(["commit", "-qm", "change \(path)"], in: repo)
        }

        func skillFile(_ name: String, off: Bool = false) throws -> String {
            let base = off ? state.appendingPathComponent("off", isDirectory: true) : directory
            return try String(contentsOf: base.appendingPathComponent("\(name)/SKILL.md"), encoding: .utf8)
        }
    }

    @Test func lookingUpARepositoryListsItsSkills() throws {
        let fixture = try Fixture()
        let found = try fixture.store.lookUp(fixture.url)
        let head = try fixture.head()
        #expect(found.repo == fixture.url)
        #expect(found.branch == "main")
        #expect(found.commit == head)
        #expect(found.skills.map(\.name) == ["docx", "pdf"])
        let pdf = try #require(found.skills.last)
        #expect(pdf.path == "skills/pdf")
        #expect(pdf.summary == "Read, fill, merge and split PDFs.")
        #expect(pdf.instructions == Self.pdf)
        #expect(pdf.files == [SkillFileEntry(name: "SKILL.md"), SkillFileEntry(name: "scripts", isDirectory: true, fileCount: 1)])
    }

    @Test func installingPutsTheSkillWherePiReadsIt() throws {
        let fixture = try Fixture()
        let snapshot = try fixture.store.install(repo: fixture.url, paths: ["skills/pdf"], commit: nil, invocation: nil)
        let head = try fixture.head()
        #expect(try fixture.skillFile("pdf") == Self.pdf)
        let script = fixture.directory.appendingPathComponent("pdf/scripts/run.sh").path
        let permissions = try FileManager.default.attributesOfItem(atPath: script)[.posixPermissions] as? Int
        #expect(permissions == 0o755)
        let pdf = try #require(snapshot.skill("pdf"))
        #expect(snapshot.skills.map(\.name) == ["pdf"])
        #expect(pdf.isOn && pdf.invocation == .automatic && pdf.update == nil)
        #expect(pdf.source?.repo == fixture.url)
        #expect(pdf.source?.path == "skills/pdf")
        #expect(pdf.source?.commit == head)
        #expect(pdf.summary == "Read, fill, merge and split PDFs.")
        #expect(pdf.files.map(\.name) == ["SKILL.md", "scripts"])
        #expect(fixture.store.snapshot() == snapshot)
    }

    /// A skill installs into a folder named after its frontmatter `name`, which is what pi calls it.
    @Test func aSkillsFolderIsNamedAfterItsName() throws {
        let fixture = try Fixture(files: ["react/SKILL.md": Self.react])
        let snapshot = try fixture.store.install(repo: fixture.url, paths: ["react"], commit: nil, invocation: .slashOnly)
        #expect(snapshot.skills.map(\.name) == ["vercel-react"])
        #expect(snapshot.skill("vercel-react")?.invocation == .slashOnly)
        #expect(try fixture.skillFile("vercel-react").contains("disable-model-invocation: true"))
    }

    @Test func offMovesASkillOutOfPisFolderAndOnPutsItBack() throws {
        let fixture = try Fixture()
        try fixture.store.install(repo: fixture.url, paths: ["skills/pdf", "skills/docx"], commit: nil, invocation: nil)
        let off = try fixture.store.setOn("pdf", on: false)
        #expect(off.skill("pdf")?.isOn == false)
        #expect(off.skill("docx")?.isOn == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("pdf").path))
        #expect(try fixture.skillFile("pdf", off: true) == Self.pdf)
        // Turning it off again changes nothing.
        #expect(try fixture.store.setOn("pdf", on: false) == off)
        let on = try fixture.store.setOn("pdf", on: true)
        #expect(on.skill("pdf")?.isOn == true)
        #expect(on.skill("pdf")?.source?.path == "skills/pdf")
        #expect(throws: SkillsStore.StoreError.noSuchSkill("nothing")) { try fixture.store.setOn("nothing", on: false) }
    }

    @Test func onlyWithSlashRewritesSKILLmdAndAnUpdateKeepsTheChoice() throws {
        let fixture = try Fixture()
        try fixture.store.install(repo: fixture.url, paths: ["skills/pdf"], commit: nil, invocation: nil)
        let slashOnly = try fixture.store.setInvocation("pdf", .slashOnly)
        #expect(slashOnly.skill("pdf")?.invocation == .slashOnly)
        #expect(try fixture.skillFile("pdf").contains("disable-model-invocation: true"))

        try fixture.commit("skills/pdf/SKILL.md", Self.pdf + "\nFill forms with scripts/fill.py.\n")
        let checked = try fixture.store.checkUpdates()
        let update = try #require(checked.skill("pdf")?.update)
        let head = try fixture.head()
        #expect(update.commit == head)
        #expect(update.filesChanged == 1)
        #expect(checked.checkedAt != nil)

        let updated = try fixture.store.install(repo: fixture.url, paths: ["skills/pdf"], commit: update.commit, invocation: nil)
        #expect(updated.skill("pdf")?.update == nil)
        #expect(updated.skill("pdf")?.source?.commit == update.commit)
        #expect(updated.skill("pdf")?.invocation == .slashOnly)
        let text = try fixture.skillFile("pdf")
        #expect(text.contains("Fill forms with scripts/fill.py."))
        #expect(text.contains("disable-model-invocation: true"))

        // Back to automatic: the line comes out again.
        #expect(try fixture.store.setInvocation("pdf", .automatic).skill("pdf")?.invocation == .automatic)
        let automatic = try fixture.skillFile("pdf")
        #expect(!automatic.contains("disable-model-invocation"))
    }

    /// A commit that doesn't touch a skill's folder is no update for it.
    @Test func aCommitElsewhereInTheRepositoryIsNoUpdate() throws {
        let fixture = try Fixture()
        try fixture.store.install(repo: fixture.url, paths: ["skills/pdf"], commit: nil, invocation: nil)
        try fixture.commit("README.md", "# skills, now with docs\n")
        #expect(try fixture.store.checkUpdates().skill("pdf")?.update == nil)
    }

    @Test func updateAutomaticallyInstallsWhatACheckFinds() throws {
        let fixture = try Fixture()
        try fixture.store.install(repo: fixture.url, paths: ["skills/pdf"], commit: nil, invocation: nil)
        #expect(try fixture.store.configure(autoUpdate: true).autoUpdate)
        try fixture.commit("skills/pdf/SKILL.md", Self.pdf + "\nNew rule.\n")
        let checked = try fixture.store.checkUpdates()
        let head = try fixture.head()
        #expect(checked.skill("pdf")?.update == nil)
        #expect(checked.skill("pdf")?.source?.commit == head)
        #expect(try fixture.skillFile("pdf").contains("New rule."))
    }

    @Test func removeTakesASkillOffAndRestorePutsItBackWhereItWas() throws {
        let fixture = try Fixture()
        try fixture.store.install(repo: fixture.url, paths: ["skills/pdf"], commit: nil, invocation: nil)
        try fixture.store.setOn("pdf", on: false)
        let removed = try fixture.store.remove("pdf")
        #expect(removed.skills.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("off/pdf").path))
        let restored = try fixture.store.restore("pdf")
        #expect(restored.skill("pdf")?.isOn == false)
        #expect(restored.skill("pdf")?.source?.path == "skills/pdf")
        #expect(throws: SkillsStore.StoreError.noSuchSkill("pdf")) { try fixture.store.restore("pdf") }
    }

    /// A folder copied in by hand is Local: it has no source, and never updates.
    @Test func aFolderCopiedInByHandIsLocal() throws {
        let fixture = try Fixture()
        let folder = fixture.directory.appendingPathComponent("changelog", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nname: changelog\ndescription: Drafts a CHANGELOG entry.\ndisable-model-invocation: true\n---\n"
            .write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        // Hidden folders and folders without a SKILL.md aren't skills.
        try FileManager.default.createDirectory(at: fixture.directory.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.directory.appendingPathComponent("notes"), withIntermediateDirectories: true)
        let snapshot = fixture.store.snapshot()
        #expect(snapshot.skills.map(\.name) == ["changelog"])
        let changelog = try #require(snapshot.skill("changelog"))
        #expect(changelog.source == nil && changelog.invocation == .slashOnly && changelog.summary == "Drafts a CHANGELOG entry.")
        #expect(try fixture.store.checkUpdates().skill("changelog")?.update == nil)
    }

    @Test func aFolderFromAnotherMacInstallsAsLocal() throws {
        let fixture = try Fixture()
        let files = [SkillFile(path: "SKILL.md", contents: Data("---\nname: go-table-tests\ndescription: House style.\n---\n".utf8)),
                     SkillFile(path: "scripts/run.sh", contents: Data("#!/bin/sh\n".utf8), executable: true)]
        let snapshot = try fixture.store.installFiles(name: "go-table-tests", files: files, invocation: .slashOnly)
        let skill = try #require(snapshot.skill("go-table-tests"))
        #expect(skill.source == nil && skill.invocation == .slashOnly)
        let script = fixture.directory.appendingPathComponent("go-table-tests/scripts/run.sh").path
        let permissions = try FileManager.default.attributesOfItem(atPath: script)[.posixPermissions] as? Int
        #expect(permissions == 0o755)
        #expect(throws: SkillsStore.StoreError.self) {
            try fixture.store.installFiles(name: "escape", files: [SkillFile(path: "SKILL.md", contents: Data()),
                                                                   SkillFile(path: "../outside", contents: Data())],
                                           invocation: .automatic)
        }
        #expect(throws: SkillsStore.StoreError.self) {
            try fixture.store.installFiles(name: "empty", files: [SkillFile(path: "notes.md", contents: Data())], invocation: .automatic)
        }
        #expect(throws: SkillsStore.StoreError.self) {
            try fixture.store.installFiles(name: "../escape", files: files, invocation: .automatic)
        }
        #expect(fixture.store.snapshot().skills.map(\.name) == ["go-table-tests"])
    }

    @Test func aRepositoryWithoutSkillsOrThatCantBeFetchedIsRefused() throws {
        let fixture = try Fixture(files: ["README.md": "# nothing here\n"])
        #expect(throws: SkillsStore.StoreError.noSkills(fixture.url)) { try fixture.store.lookUp(fixture.url) }
        #expect(throws: SkillsStore.StoreError.notARepository("not a repo")) { try fixture.store.lookUp("not a repo") }
        do {
            _ = try fixture.store.lookUp("file://" + fixture.repo.appendingPathComponent("missing").path)
            Issue.record("a missing repository was looked up")
        } catch let SkillsStore.StoreError.git(message) {
            #expect(message.hasPrefix("Couldn't fetch"))
        }
        #expect(throws: SkillsStore.StoreError.noSuchPath("skills/nothing")) {
            try Fixture().store.install(repo: fixture.url, paths: ["skills/nothing"], commit: nil, invocation: nil)
        }
    }
}
