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

    init(_ skills: [InstalledSkill] = []) {
        snapshot = SkillsSnapshot(directory: "~/.agents/skills", skills: skills)
    }

    var requests: [String] { lock.withLock { log } }
    var skills: SkillsSnapshot { lock.withLock { snapshot } }

    func skills(_ request: RemoteSkillsRequest) async throws -> RemoteSkillsResult {
        try lock.withLock {
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
    }
}

/// Settings ▸ Skills' model: every host's skills in one list, changes shown at once and sent to
/// every host, an offline host owed them, and installs one host at a time.
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

    @Test func theListHoldsEveryHostsSkillsAsTheFirstHostHasThem() async {
        let first = FakeSkillsClient([Self.skill("pdf", summary: "first"), Self.skill("docx")])
        let second = FakeSkillsClient([Self.skill("pdf", summary: "second"), Self.skill("changelog")])
        let hosts = [Self.host("This Mac", first), Self.host("build-01", second)]
        let model = ClientSkills(defaults: ScratchDefaults())
        await model.refresh(hosts)
        #expect(model.rows(in: hosts).map(\.name) == ["changelog", "docx", "pdf"])
        #expect(model.row("pdf", in: hosts)?.skill.summary == "first")
        #expect(model.copies(of: "docx", in: hosts).map(\.state) == [.installed, .missing])
    }

    @Test func aSwitchShowsAtOnceAndGoesToEveryHostThatHasTheSkill() async {
        let first = FakeSkillsClient([Self.skill("pdf")])
        let second = FakeSkillsClient([Self.skill("pdf")])
        let third = FakeSkillsClient([])
        let hosts = [Self.host("This Mac", first), Self.host("build-01", second), Self.host("studio", third)]
        let model = ClientSkills(defaults: ScratchDefaults())
        await model.refresh(hosts)
        let sent = model.setOn("pdf", false, in: hosts)
        // Before any host answers.
        #expect(model.row("pdf", in: hosts)?.skill.isOn == false)
        await sent.value
        #expect(first.skills.skill("pdf")?.isOn == false)
        #expect(second.skills.skill("pdf")?.isOn == false)
        #expect(!third.requests.contains("setOn"))
    }

    @Test func anOfflineHostIsOwedTheChangeAndTakesItWhenItIsBack() async {
        let first = FakeSkillsClient([Self.skill("pdf")])
        let later = FakeSkillsClient([Self.skill("pdf")])
        let id = UUID()
        let defaults = ScratchDefaults()
        var hosts = [Self.host("This Mac", first), Self.host("horizon", nil, id: id)]
        let model = ClientSkills(defaults: defaults)
        await model.refresh(hosts)
        await model.setOn("pdf", false, in: hosts).value
        #expect(model.owes(id))
        #expect(model.copies(of: "pdf", in: hosts).map(\.state) == [.installed, .owed])
        // What is owed outlives the model.
        #expect(ClientSkills(defaults: defaults).owes(id))

        hosts[1] = Self.host("horizon", later, id: id)
        await model.hostConnected(hosts[1])
        #expect(later.requests == ["setOn", "fetch"])
        #expect(later.skills.skill("pdf")?.isOn == false)
        #expect(!model.owes(id))
    }

    /// An offline host is owed the last of each change, and a removal undone before it's back
    /// is no change at all.
    @Test func whatAnOfflineHostIsOwedKeepsOnlyTheLatest() async {
        let first = FakeSkillsClient([Self.skill("pdf")])
        let later = FakeSkillsClient([Self.skill("pdf")])
        let id = UUID()
        var hosts = [Self.host("This Mac", first), Self.host("horizon", nil, id: id)]
        let model = ClientSkills(defaults: ScratchDefaults())
        await model.refresh(hosts)
        await model.setOn("pdf", false, in: hosts).value
        await model.setOn("pdf", true, in: hosts).value
        await model.remove("pdf", in: hosts).value
        await model.undoRemoval(in: hosts)?.value
        // Off, on, removed, restored: nothing is left to send.
        #expect(!model.owes(id))
        hosts[1] = Self.host("horizon", later, id: id)
        await model.hostConnected(hosts[1])
        #expect(later.requests == ["fetch"])
        #expect(later.skills.skill("pdf")?.isOn == true)
    }

    @Test func perHostAChangeGoesToTheFirstHostAlone() async {
        let first = FakeSkillsClient([Self.skill("pdf")])
        let second = FakeSkillsClient([Self.skill("pdf")])
        let hosts = [Self.host("This Mac", first), Self.host("build-01", second)]
        let defaults = ScratchDefaults()
        let model = ClientSkills(defaults: defaults)
        model.sameEverywhere = false
        #expect(!ClientSkills(defaults: defaults).sameEverywhere)
        await model.refresh(hosts)
        await model.setInvocation("pdf", .slashOnly, in: hosts).value
        #expect(first.skills.skill("pdf")?.invocation == .slashOnly)
        #expect(second.skills.skill("pdf")?.invocation == .automatic)
    }

    @Test func removeTakesASkillOffEveryHostAndUndoPutsItBack() async throws {
        let first = FakeSkillsClient([Self.skill("pdf"), Self.skill("docx")])
        let second = FakeSkillsClient([Self.skill("pdf")])
        let hosts = [Self.host("This Mac", first), Self.host("build-01", second)]
        let model = ClientSkills(defaults: ScratchDefaults())
        await model.refresh(hosts)
        let removing = model.remove("pdf", in: hosts)
        #expect(model.rows(in: hosts).map(\.name) == ["docx"])
        let removal = try #require(model.removal)
        #expect(SkillsPresentation.removed(removal) == "Removed pdf from every host")
        await removing.value
        await model.undoRemoval(in: hosts)?.value
        #expect(model.removal == nil)
        #expect(model.rows(in: hosts).map(\.name) == ["docx", "pdf"])
        #expect(second.skills.skill("pdf") != nil)
    }

    @Test func updateInstallsTheNewerCommitOnEveryHost() async {
        let newer = SkillUpdate(commit: "new", committedAt: 2_000, filesChanged: 3)
        let first = FakeSkillsClient([Self.skill("pdf", source: Self.anthropic, update: newer)])
        let second = FakeSkillsClient([Self.skill("pdf", source: Self.anthropic, update: newer)])
        let hosts = [Self.host("This Mac", first), Self.host("build-01", second)]
        let model = ClientSkills(defaults: ScratchDefaults())
        await model.refresh(hosts)
        #expect(model.count(.updates, in: hosts) == 1)
        await model.updateAll(in: hosts)
        #expect(first.skills.skill("pdf")?.source?.commit == "new")
        #expect(second.skills.skill("pdf")?.source?.commit == "new")
        #expect(model.count(.updates, in: hosts) == 0)
        #expect(model.row("pdf", in: hosts)?.isUpdating == false)
    }

    /// A skill from skills.sh installs from its repository: a host looks the repository up to
    /// find the skill's folder, then every host installs it, one at a time.
    @Test func aSkillFromTheDirectoryInstallsFromItsRepository() async throws {
        let first = FakeSkillsClient()
        first.repo = RepoSkills(repo: "anthropics/skills", branch: "main", commit: "c0ffee",
                                skills: [RepoSkill(path: "skills/pdf", name: "pdf", summary: "PDFs")])
        let second = FakeSkillsClient()
        let hosts = [Self.host("This Mac", first), Self.host("build-01", second), Self.host("horizon", nil)]
        let model = ClientSkills(defaults: ScratchDefaults())
        await model.refresh(hosts)
        await model.install("anthropics/skills/pdf", source: "anthropics/skills", skill: "pdf", invocation: .slashOnly, in: hosts)
        #expect(first.requests == ["fetch", "lookUp", "install"])
        #expect(second.skills.skill("pdf")?.source?.commit == "c0ffee")
        #expect(second.skills.skill("pdf")?.invocation == .slashOnly)
        let install = try #require(model.installs["anthropics/skills/pdf"])
        #expect(install.steps.map(\.state) == [.installed, .installed, .owed])
        #expect(SkillsPresentation.installLine(install) == "Installed · horizon when it's back")
        #expect(model.owes(hosts[2].id))
    }

    /// A skill on skills.sh reads as the hosts have it: Install, Installed, or Update while a
    /// newer commit waits.
    @Test func aDirectorySkillSaysWhereItStands() async {
        let first = FakeSkillsClient([Self.skill("docx", source: Self.anthropic),
                                      Self.skill("pdf", source: Self.anthropic, update: SkillUpdate(commit: "new", filesChanged: 1))])
        let hosts = [Self.host("This Mac", first)]
        let model = ClientSkills(defaults: ScratchDefaults())
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
        let model = ClientSkills(defaults: ScratchDefaults())
        await model.refresh(hosts)
        await model.install("k", repo: "acme/private", paths: ["x"], commit: nil, invocation: nil, in: hosts)
        let install = try #require(model.installs["k"])
        #expect(install.failure == "Couldn't fetch acme/private: denied")
        #expect(SkillsPresentation.installLine(install) == "Couldn't fetch acme/private: denied")
    }

    @Test func cancellingAnInstallDropsWhatAnOfflineHostIsOwed() async throws {
        let first = FakeSkillsClient()
        let id = UUID()
        let hosts = [Self.host("This Mac", first), Self.host("horizon", nil, id: id)]
        let model = ClientSkills(defaults: ScratchDefaults())
        await model.refresh(hosts)
        await model.install("k", repo: "anthropics/skills", paths: ["skills/pdf"], commit: nil, invocation: nil, in: hosts)
        #expect(model.owes(id))
        model.cancelInstall("k")
        #expect(!model.owes(id))
        #expect(try #require(model.installs["k"]).steps.map(\.state) == [.installed, .failed("Cancelled")])
    }

    @Test func filtersAndSearchKeepTheirRows() async {
        let first = FakeSkillsClient([
            Self.skill("changelog", summary: "Drafts a CHANGELOG entry.", on: false),
            Self.skill("pdf", summary: "Read and fill PDFs.", source: Self.anthropic,
                       update: SkillUpdate(commit: "new", filesChanged: 1)),
            Self.skill("sqlc-queries", summary: "Migrations first."),
        ])
        let hosts = [Self.host("This Mac", first)]
        let model = ClientSkills(defaults: ScratchDefaults())
        await model.refresh(hosts)
        #expect(model.count(.all, in: hosts) == 3)
        #expect(model.count(.on, in: hosts) == 2)
        #expect(model.rows(in: hosts, filter: .updates).map(\.name) == ["pdf"])
        #expect(model.rows(in: hosts, filter: .all, query: "migrations").map(\.name) == ["sqlc-queries"])
        #expect(model.rows(in: hosts, filter: .on, query: "CHANGELOG").isEmpty)
        #expect(SkillsPresentation.settingsValue(model.rows(in: hosts)) == "3 · 1 update")
    }

    @Test func autoUpdateAndChecksGoToEveryHost() async {
        let first = FakeSkillsClient([Self.skill("pdf")])
        let second = FakeSkillsClient([Self.skill("pdf")])
        let hosts = [Self.host("This Mac", first), Self.host("build-01", second), Self.host("horizon", nil)]
        let model = ClientSkills(defaults: ScratchDefaults())
        await model.refresh(hosts)
        await model.setAutoUpdate(true, in: hosts).value
        #expect(model.autoUpdate(in: hosts))
        #expect(second.skills.autoUpdate)
        #expect(model.owes(hosts[2].id))
        await model.checkUpdates(in: hosts)
        #expect(model.checkedAt(in: hosts) == 1_000)
        #expect(second.requests.last == "checkUpdates")
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

    @Test func theDetailSaysWhatEachHostHasAndWhatANewerCommitChanges() {
        #expect(SkillsPresentation.copy(.owed) == "offline · updates later")
        #expect(SkillsPresentation.copy(.installed) == "installed")
        #expect(SkillsPresentation.host(.offline, owed: false) == "offline")
        #expect(SkillsPresentation.host(.loaded(SkillsSnapshot(directory: "~/s")), owed: false) == "up to date")
        let newer = SkillsPresentation.newer(SkillUpdate(commit: "8c04e1d0a", committedAt: nil, filesChanged: 3))
        #expect(newer.commit == "8c04e1d" && newer.detail == "3 files changed")
        #expect(SkillsPresentation.use(.slashOnly) == "/skill only")
        #expect(SkillsPresentation.invocationTitle(.automatic) == "Automatically")
        #expect(SkillsPresentation.invocationTitle(.slashOnly) == "Only with /skill")
        #expect(SkillsPresentation.slashOption("pdf") == "Only when I type /skill:pdf")
        #expect(SkillsPresentation.mobileSummary(InstalledSkill(name: "go", summary: "House style.", invocation: .slashOnly, updatedAt: 0))
            == "/skill only · House style.")
    }

    @Test func thePhoneSaysWhichHostsAreAwayAndWhatASearchFound() {
        let studio = SkillsHost(id: UUID(), name: "Studio", client: FakeSkillsClient(), serves: true)
        let horizon = SkillsHost(id: UUID(), name: "horizon", client: nil, serves: true)
        let laptop = SkillsHost(id: UUID(), name: "MacBook Air", client: nil, serves: true)
        #expect(SkillsPresentation.offlineNote([studio]) == nil)
        #expect(SkillsPresentation.offlineNote([studio, horizon]) == "horizon is offline. It gets changes when it’s back.")
        #expect(SkillsPresentation.offlineNote([horizon, laptop]) == "horizon, MacBook Air are offline. They get changes when they’re back.")
        #expect(SkillsPresentation.results(1, for: " pdf ") == "1 skill for “pdf”")
        #expect(SkillsPresentation.results(12, for: "react") == "12 skills for “react”")
        #expect(SkillsPresentation.resultMeta(DirectorySkill(slug: "pdf", name: "pdf", source: "anthropics/skills", installs: 71_000))
            == "anthropics/skills · 71K installs")
    }

    @Test func installsSayWhereTheyGo() {
        let hosts = [SkillsHost(id: UUID(), name: "This Mac", client: FakeSkillsClient(), serves: true),
                     SkillsHost(id: UUID(), name: "build-01", client: FakeSkillsClient(), serves: true),
                     SkillsHost(id: UUID(), name: "horizon", client: nil, serves: true)]
        #expect(SkillsPresentation.destinations(hosts) == "This Mac, build-01 now · horizon when it's back")
        let running = SkillInstall(steps: [.init(id: UUID(), name: "This Mac", state: .installed),
                                           .init(id: UUID(), name: "build-01", state: .copying),
                                           .init(id: UUID(), name: "horizon", state: .owed)])
        #expect(SkillsPresentation.installLine(running) == "Installing · 1 of 3 hosts")
        #expect(SkillsPresentation.step(.copying) == "copying files")
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
