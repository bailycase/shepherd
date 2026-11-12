import Foundation
import Testing
import ShepherdProtocol
import ShepherdTestKit
@testable import ShepherdRemote

/// A host's skills in memory, answering as a host's store does.
final class FakeSkillsClient: SkillsClient, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: SkillsSnapshot
    private var removed: [String: InstalledSkill] = [:]
    private var log: [String] = []
    var repo: RepoSkills?
    var refusesInstalls = false
    var beforeRequest: (@Sendable (RemoteSkillsRequest) async throws -> Void)?
    var afterRequest: (@Sendable (RemoteSkillsRequest) async throws -> Void)?

    init(_ skills: [InstalledSkill] = [], pi: PiSkills? = nil) {
        snapshot = SkillsSnapshot(directory: "~/.agents/skills", skills: skills, pi: pi)
    }

    var requests: [String] { lock.withLock { log } }
    var skills: SkillsSnapshot { lock.withLock { snapshot } }

    func skills(_ request: RemoteSkillsRequest) async throws -> RemoteSkillsResult {
        try await beforeRequest?(request)
        let result: RemoteSkillsResult = try lock.withLock {
            log.append(String(describing: request).prefix { $0 != "(" }.description)
            func index(_ name: String) throws -> Int {
                guard let index = snapshot.skills.firstIndex(where: { $0.name == name }) else {
                    throw RemoteHostClientError.rejected(code: "no_such_skill", message: "There's no skill named \(name) here.")
                }
                return index
            }
            switch request {
            case .fetch:
                break
            case .lookUp:
                guard let repo else { throw RemoteHostClientError.rejected(code: "no_skills", message: "No skills.") }
                return .repo(repo)
            case .install(let repo, let paths, let commit, let invocation):
                if refusesInstalls { throw RemoteHostClientError.rejected(code: "git_failed", message: "Couldn't fetch \(repo): denied") }
                for path in paths {
                    let name = path.split(separator: "/").last.map(String.init) ?? "skill"
                    let existing = snapshot.skills.first { $0.name == name }
                    snapshot.skills.removeAll { $0.name == name }
                    snapshot.skills.append(InstalledSkill(
                        name: name, summary: existing?.summary ?? "", isOn: existing?.isOn ?? true,
                        invocation: invocation ?? existing?.invocation ?? .automatic,
                        source: SkillSource(repo: repo, path: path, commit: commit ?? "tip"), updatedAt: 1))
                }
                snapshot.skills.sort { $0.name < $1.name }
            case .installFiles(let name, _, let invocation):
                snapshot.skills.append(InstalledSkill(name: name, summary: "", invocation: invocation, updatedAt: 1))
            case .setOn(let name, let on):
                snapshot.skills[try index(name)].isOn = on
            case .setInvocation(let name, let invocation):
                snapshot.skills[try index(name)].invocation = invocation
            case .remove(let name):
                removed[name] = snapshot.skills.remove(at: try index(name))
            case .restore(let name):
                guard let skill = removed.removeValue(forKey: name) else {
                    throw RemoteHostClientError.rejected(code: "no_such_skill", message: "Nothing to restore.")
                }
                snapshot.skills.append(skill)
                snapshot.skills.sort { $0.name < $1.name }
            case .checkUpdates:
                snapshot.checkedAt = 1_000
            case .configure(let autoUpdate):
                snapshot.autoUpdate = autoUpdate
            }
            return .skills(snapshot)
        }
        try await afterRequest?(request)
        return result
    }
}

/// Settings ▸ Skills' model: the page edits one copy, the first connected host's, shows a change at
/// once and sends it there; the fleet carries it to the other Macs, so nothing here knows about them.
@MainActor
@Suite("Client skills")
struct ClientSkillsTests {
    static let anthropic = SkillSource(repo: "anthropics/skills", path: "skills/pdf", commit: "old", committedAt: 1_000)

    static func skill(_ name: String, summary: String = "", on: Bool = true, source: SkillSource? = nil,
                      update: SkillUpdate? = nil) -> InstalledSkill {
        InstalledSkill(name: name, summary: summary, isOn: on, source: source, updatedAt: 1, update: update)
    }

    static func host(_ name: String, _ client: FakeSkillsClient?, id: UUID = UUID()) -> SkillsHost {
        SkillsHost(id: id, name: name, client: client, serves: true)
    }

    @Test func theListHoldsTheFirstConnectedHostsSkillsAndReadsNoOther() async {
        let away = FakeSkillsClient([Self.skill("lost")])
        let first = FakeSkillsClient([Self.skill("pdf", summary: "first"), Self.skill("docx")])
        let second = FakeSkillsClient([Self.skill("pdf", summary: "second"), Self.skill("changelog")])
        let hosts = [Self.host("horizon", nil), Self.host("This Mac", first), Self.host("build-01", second)]
        let model = ClientSkills()
        await model.refresh(hosts)
        #expect(model.edited(in: hosts)?.name == "This Mac")
        #expect(model.rows(in: hosts).map(\.name) == ["docx", "pdf"])
        #expect(model.row("pdf", in: hosts)?.skill.summary == "first")
        #expect(second.requests.isEmpty && away.requests.isEmpty, "the fleet carries the rest")
    }

    @Test func aSwitchShowsAtOnceAndGoesToTheHostThePageEdits() async {
        let first = FakeSkillsClient([Self.skill("pdf")])
        let second = FakeSkillsClient([Self.skill("pdf")])
        let hosts = [Self.host("This Mac", first), Self.host("build-01", second)]
        let model = ClientSkills()
        await model.refresh(hosts)
        let sent = model.setOn("pdf", false, in: hosts)
        // Before the host answers.
        #expect(model.row("pdf", in: hosts)?.skill.isOn == false)
        await sent.value
        #expect(first.skills.skill("pdf")?.isOn == false)
        #expect(!second.requests.contains("setOn"), "no fan out: sync carries it")
        await model.setInvocation("pdf", .slashOnly, in: hosts).value
        #expect(first.skills.skill("pdf")?.invocation == .slashOnly)
    }

    @Test func aChangeTheHostRefusesPutsTheHostsOwnStateBack() async {
        let first = FakeSkillsClient([Self.skill("pdf")])
        let hosts = [Self.host("This Mac", first)]
        let model = ClientSkills()
        await model.refresh(hosts)
        await model.setOn("nothing", false, in: hosts).value
        #expect(model.problem == "There's no skill named nothing here.")
        #expect(model.row("pdf", in: hosts)?.skill.isOn == true)
        model.dismissProblem()
        #expect(model.problem == nil)
    }

    @Test func aHostThatConnectsLaterIsOnlyReadNeverOwedAnything() async {
        let later = FakeSkillsClient([Self.skill("pdf")])
        let id = UUID()
        let model = ClientSkills()
        let hosts = [Self.host("horizon", nil, id: id)]
        await model.refresh(hosts)
        #expect(model.edited(in: hosts) == nil && model.rows(in: hosts).isEmpty)
        let back = [Self.host("horizon", later, id: id)]
        await model.hostConnected(back[0])
        #expect(later.requests == ["fetch"])
        #expect(model.rows(in: back).map(\.name) == ["pdf"])
    }

    @Test func removeTakesASkillOffTheFleetAndUndoPutsItBack() async throws {
        let first = FakeSkillsClient([Self.skill("pdf"), Self.skill("docx")])
        let hosts = [Self.host("This Mac", first)]
        let model = ClientSkills()
        await model.refresh(hosts)
        let removing = model.remove("pdf", in: hosts)
        #expect(model.rows(in: hosts).map(\.name) == ["docx"])
        let removal = try #require(model.removal)
        #expect(SkillsPresentation.removed(removal) == "Removed pdf")
        await removing.value
        #expect(first.skills.skill("pdf") == nil && first.skills.skill("docx") != nil)
        await model.undoRemoval(in: hosts)?.value
        #expect(model.removal == nil)
        #expect(model.rows(in: hosts).map(\.name) == ["docx", "pdf"])
        #expect(first.skills.skill("pdf") != nil)
    }

    @Test func updateInstallsTheNewerCommit() async {
        let newer = SkillUpdate(commit: "new", committedAt: 2_000, filesChanged: 3)
        let first = FakeSkillsClient([Self.skill("pdf", source: Self.anthropic, update: newer)])
        let hosts = [Self.host("This Mac", first)]
        let model = ClientSkills()
        await model.refresh(hosts)
        #expect(model.count(.updates, in: hosts) == 1)
        await model.updateAll(in: hosts)
        #expect(first.skills.skill("pdf")?.source?.commit == "new")
        #expect(model.count(.updates, in: hosts) == 0)
        #expect(model.row("pdf", in: hosts)?.isUpdating == false)
    }

    /// A skill from skills.sh installs from its repository: the host looks the repository up to
    /// find the skill's folder, then installs it.
    @Test func aSkillFromTheDirectoryInstallsFromItsRepository() async throws {
        let first = FakeSkillsClient()
        first.repo = RepoSkills(repo: "anthropics/skills", branch: "main", commit: "c0ffee",
                                skills: [RepoSkill(path: "skills/pdf", name: "pdf", summary: "PDFs")])
        let hosts = [Self.host("This Mac", first), Self.host("build-01", FakeSkillsClient())]
        let model = ClientSkills()
        await model.refresh(hosts)
        await model.install("anthropics/skills/pdf", source: "anthropics/skills", skill: "pdf", invocation: .slashOnly, in: hosts)
        #expect(first.requests == ["fetch", "lookUp", "install"])
        #expect(first.skills.skill("pdf")?.source?.commit == "c0ffee")
        #expect(first.skills.skill("pdf")?.invocation == .slashOnly)
        let install = try #require(model.installs["anthropics/skills/pdf"])
        #expect(install.state == .installed && SkillsPresentation.installLine(install) == "Installed")
    }

    @Test(arguments: [false, true])
    func aReplacedOrDismissedDirectoryLookupCannotStartAnInstall(replace: Bool) async {
        let client = FakeSkillsClient()
        client.repo = RepoSkills(repo: "acme/skills", branch: "main", commit: "old",
                                 skills: [RepoSkill(path: "skills/pdf", name: "pdf", summary: "PDF")])
        let hosts = [Self.host("here", client)]
        let model = ClientSkills()
        let gate = SettingsRequestGate()
        client.beforeRequest = { request in
            if case .lookUp = request { await gate.hold() }
        }
        let lookingUp = Task { await model.install("same-key", source: "acme/skills", skill: "pdf", invocation: nil, in: hosts) }
        await gate.waitUntilHeld()
        model.dismissInstall("same-key")
        if replace {
            await model.install("same-key", repo: "acme/skills", paths: ["skills/pdf"], commit: "new", invocation: nil, in: hosts)
        }
        await gate.release()
        await lookingUp.value
        #expect(client.requests.filter { $0 == "install" }.count == (replace ? 1 : 0))
        if replace {
            #expect(client.skills.skill("pdf")?.source?.commit == "new")
        } else {
            #expect(model.installs["same-key"] == nil)
        }
    }

    /// A skill on skills.sh reads as the host has it: Install, Installed, or Update while a newer
    /// commit waits.
    @Test func aDirectorySkillSaysWhereItStands() async {
        let first = FakeSkillsClient([Self.skill("docx", source: Self.anthropic),
                                      Self.skill("pdf", source: Self.anthropic, update: SkillUpdate(commit: "new", filesChanged: 1))])
        let hosts = [Self.host("This Mac", first)]
        let model = ClientSkills()
        await model.refresh(hosts)
        func state(_ slug: String) -> SkillResultState {
            SkillResultState(DirectorySkill(slug: slug, name: slug, source: "anthropics/skills", installs: 1), model: model, hosts: hosts)
        }
        #expect(state("pdf") == .update)
        #expect(state("docx") == .installed)
        #expect(state("xlsx") == .install)
    }

    @Test func aHostThatRefusesAnInstallSaysWhy() async throws {
        let first = FakeSkillsClient()
        first.refusesInstalls = true
        let hosts = [Self.host("This Mac", first)]
        let model = ClientSkills()
        await model.refresh(hosts)
        await model.install("k", repo: "acme/private", paths: ["x"], commit: nil, invocation: nil, in: hosts)
        let install = try #require(model.installs["k"])
        #expect(install.failure == "Couldn't fetch acme/private: denied")
        #expect(SkillsPresentation.installLine(install) == "Couldn't fetch acme/private: denied")
    }

    @Test func filtersAndSearchKeepTheirRows() async {
        let first = FakeSkillsClient([
            Self.skill("changelog", summary: "Drafts a CHANGELOG entry.", on: false),
            Self.skill("pdf", summary: "Read and fill PDFs.", source: Self.anthropic,
                       update: SkillUpdate(commit: "new", filesChanged: 1)),
            Self.skill("sqlc-queries", summary: "Migrations first."),
        ])
        let hosts = [Self.host("This Mac", first)]
        let model = ClientSkills()
        await model.refresh(hosts)
        #expect(model.count(.all, in: hosts) == 3)
        #expect(model.count(.on, in: hosts) == 2)
        #expect(model.rows(in: hosts, filter: .updates).map(\.name) == ["pdf"])
        #expect(model.rows(in: hosts, filter: .all, query: "migrations").map(\.name) == ["sqlc-queries"])
        #expect(model.rows(in: hosts, filter: .on, query: "CHANGELOG").isEmpty)
        #expect(SkillsPresentation.settingsValue(model.rows(in: hosts)) == "3 · 1 update")
    }

    @Test func autoUpdateAndChecksGoToTheEditedHost() async {
        let first = FakeSkillsClient([Self.skill("pdf")])
        let hosts = [Self.host("This Mac", first)]
        let model = ClientSkills()
        await model.refresh(hosts)
        await model.setAutoUpdate(true, in: hosts).value
        #expect(model.autoUpdate(in: hosts) && first.skills.autoUpdate)
        await model.checkUpdates(in: hosts)
        #expect(model.checkedAt(in: hosts) == 1_000)
        #expect(first.requests.last == "checkUpdates")
    }
}

/// Settings ▸ Skills' words.
@Suite("Skills presentation")
struct SkillsPresentationTests {
    @Test(arguments: [
        (nil, "Not checked yet"), (99_970.0, "Checked just now"), (99_000.0, "Checked 16m ago"),
        (92_800.0, "Checked 2h ago"), (0.0, "Checked 1d ago"),
    ] as [(Double?, String)])
    func checksSayHowLongAgo(checkedAt: Double?, line: String) {
        #expect(SkillsPresentation.checkedLine(checkedAt, now: Date(timeIntervalSince1970: 100_000)) == line)
    }

    @Test func theDetailSaysWhatANewerCommitChanges() {
        let newer = SkillsPresentation.newer(SkillUpdate(commit: "8c04e1d0a", committedAt: nil, filesChanged: 3))
        #expect(newer.commit == "8c04e1d" && newer.detail == "3 files changed")
        #expect(SkillsPresentation.use(.slashOnly) == "/skill only")
        #expect(SkillsPresentation.invocationTitle(.automatic) == "Automatically")
        #expect(SkillsPresentation.invocationTitle(.slashOnly) == "Only with /skill")
        #expect(SkillsPresentation.slashOption("pdf") == "Only when I type /skill:pdf")
        #expect(SkillsPresentation.mobileSummary(InstalledSkill(name: "go", summary: "House style.", invocation: .slashOnly, updatedAt: 0))
            == "/skill only · House style.")
    }

    @Test func thePhoneSaysWhatASearchFound() {
        #expect(SkillsPresentation.results(1, for: " pdf ") == "1 skill for “pdf”")
        #expect(SkillsPresentation.results(12, for: "react") == "12 skills for “react”")
        #expect(SkillsPresentation.resultMeta(DirectorySkill(slug: "pdf", name: "pdf", source: "anthropics/skills", installs: 71_000))
            == "anthropics/skills · 71K installs")
    }

    @Test func installsSayWhereTheyStand() {
        #expect(SkillsPresentation.installLine(SkillInstall(state: .installing)) == "Installing")
        #expect(SkillsPresentation.installTitle(1) == "Install 1 skill")
        #expect(SkillsPresentation.selection(3, new: 13) == "3 of 13 new skills")
        #expect(SkillsPresentation.repoLine(RepoSkills(repo: "anthropics/skills", branch: "main", commit: "8c04e1d0a",
                                                       skills: [RepoSkill(path: "a", name: "a", summary: "")]))
            == "1 skill · main @ 8c04e1d")
    }

    @Test(arguments: [
        ([], "No scripts. Instructions and references only."),
        (["SKILL.md", "references/a.md"], "No scripts. Instructions and references only."),
        (["scripts/init_skill.py", "scripts/package_skill.py", "scripts/quick_validate.py"],
         "3 scripts the agent can run: init_skill.py, package_skill.py, quick_validate.py"),
        (["scripts/a.py", "scripts/b.py", "scripts/c.py", "scripts/d.sh"], "4 scripts the agent can run, in Python."),
        (["scripts/a.py", "scripts/b.sh", "scripts/c.js", "scripts/d.rb"], "4 scripts the agent can run."),
    ] as [([String], String)])
    func scriptsAreNamedOrCounted(paths: [String], note: String) {
        #expect(SkillsPresentation.scriptsNote(paths: paths) == note)
    }

    @Test func aFolderTopLevelCountsItsScripts() {
        #expect(SkillsPresentation.scriptsNote(entries: [SkillFileEntry(name: "SKILL.md"),
                                                         SkillFileEntry(name: "scripts", isDirectory: true, fileCount: 4)])
            == "4 scripts the agent can run.")
        #expect(SkillsPresentation.chip(SkillFileEntry(name: "scripts", isDirectory: true, fileCount: 8)) == "scripts/")
        #expect(SkillsPresentation.automaticCount([InstalledSkill(name: "a", summary: "", updatedAt: 0),
                                                   InstalledSkill(name: "b", summary: "", isOn: false, updatedAt: 0)])
            == "1 automatic skill. Full files load only when used.")
    }
}
