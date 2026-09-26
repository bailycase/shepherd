import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Settings ▸ Skills' outside skills on a host: the loader runs `shepherd-pi-skills.mjs` on node
/// against fixture folders (a scratch home and pi agent directory) and a stand-in pi package that
/// answers the loader API the script calls, so it never reads this machine's pi. The real pi's
/// answers are checked by `Tests/Extensions/pi-skills.test.mjs`.
@Suite("pi's own skills", .integrationTimeLimit)
struct PiSkillsLoaderTests {
    /// A pi package with the three calls the script makes: settings from its storage, a package
    /// manager's resolved skills (settings paths, the agent directory's skills, ~/.agents/skills,
    /// then each package's), and a loader that keeps the first skill of each name. Each import
    /// adds a line to runs.log beside it.
    static let standInPi = #"""
        import { appendFileSync, existsSync, readdirSync, readFileSync, statSync } from "node:fs";
        import { homedir } from "node:os";
        import { join, resolve } from "node:path";

        appendFileSync(new URL("../runs.log", import.meta.url), "run\n");
        if (process.env.STAND_IN_PI_HANG) await new Promise(() => setInterval(() => {}, 1000));

        export class SettingsManager {
          static fromStorage(storage) {
            const manager = new SettingsManager();
            storage.withLock("global", (current) => { manager.global = current ? JSON.parse(current) : {}; });
            return manager;
          }
          getGlobalSettings() { return this.global; }
        }

        const skillFolders = (root) => existsSync(root)
          ? readdirSync(root).map((name) => join(root, name)).filter((path) => existsSync(join(path, "SKILL.md"))) : [];

        export class DefaultPackageManager {
          constructor({ agentDir, settingsManager }) { this.agentDir = agentDir; this.settings = settingsManager.getGlobalSettings(); }
          async resolve() {
            const user = (source, origin, baseDir) => ({ source, scope: "user", origin, baseDir });
            const skills = [];
            for (const path of this.settings.skills ?? []) skills.push({ path: resolve(this.agentDir, path), enabled: true, metadata: user("local", "top-level") });
            for (const path of skillFolders(join(this.agentDir, "skills"))) skills.push({ path, enabled: true, metadata: user("auto", "top-level", this.agentDir) });
            const agents = join(homedir(), ".agents");
            for (const path of skillFolders(join(agents, "skills"))) skills.push({ path, enabled: true, metadata: user("auto", "top-level", agents) });
            for (const pkg of this.settings.packages ?? []) {
              for (const path of skillFolders(join(pkg, "skills"))) skills.push({ path, enabled: true, metadata: user(pkg, "package", pkg) });
            }
            return { skills, extensions: [], prompts: [], themes: [] };
          }
        }

        function read(file) {
          const text = readFileSync(file, "utf8");
          const field = (key) => text.match(new RegExp(`^${key}:\\s*(.*)$`, "m"))?.[1]?.trim();
          return { name: field("name"), description: field("description") ?? "", filePath: file,
                   disableModelInvocation: field("disable-model-invocation") === "true" };
        }

        export function loadSkills({ skillPaths }) {
          const skills = [], diagnostics = [], byName = new Map();
          for (const path of skillPaths) {
            const files = statSync(path).isDirectory() ? skillFolders(path).map((folder) => join(folder, "SKILL.md")) : [path];
            for (const file of files) {
              const skill = read(file);
              const winner = byName.get(skill.name);
              if (winner) {
                diagnostics.push({ type: "collision", collision: { resourceType: "skill", name: skill.name, winnerPath: winner.filePath, loserPath: file } });
              } else {
                byName.set(skill.name, skill);
                skills.push(skill);
              }
            }
          }
          return { skills, diagnostics };
        }

        """#

    struct Fixture {
        let root: URL
        let home: URL
        let agent: URL
        let package: URL
        var installed: URL { home.appendingPathComponent(".agents/skills", isDirectory: true) }

        init() throws {
            root = try makeScratchDirectory("pis")
            home = root.appendingPathComponent("home", isDirectory: true)
            agent = root.appendingPathComponent("agent", isDirectory: true)
            package = root.appendingPathComponent("pi", isDirectory: true)
            try write("pi/package.json", #"{"name":"@earendil-works/pi-coding-agent","version":"0.0.1","main":"dist/index.js"}"#)
            try write("pi/dist/index.js", PiSkillsLoaderTests.standInPi)
            try skill("home/.agents/skills/alpha", "alpha", "Installed alpha.")
            try skill("home/.agents/skills/delta", "delta", "Installed delta.")
            try skill("agent/skills/alpha", "alpha", "pi's alpha.")
            try skill("agent/skills/beta", "beta", "pi's beta.", slashOnly: true)
            try skill("extra/gamma", "gamma", "From pi's settings.")
            try skill("vendor/team/skills/delta", "delta", "The package's delta.")
            try skill("vendor/team/skills/epsilon", "epsilon", "The package's epsilon.")
            try write("vendor/team/package.json", #"{"name":"@acme/team-skills"}"#)
            try write("agent/settings.json", #"{"skills":["\#(root.path)/extra"],"packages":["\#(root.path)/vendor/team"]}"#)
        }

        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        func skill(_ folder: String, _ name: String, _ description: String, slashOnly: Bool = false) throws {
            let extra = slashOnly ? "disable-model-invocation: true\n" : ""
            try write("\(folder)/SKILL.md", "---\nname: \(name)\ndescription: \(description)\n\(extra)---\n# \(name)\n")
        }

        func loader(timeout: TimeInterval = PiSkillsLoader.timeout, package: URL? = nil, hang: Bool = false) throws -> PiSkillsLoader {
            var environment = ["HOME": home.path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
            if hang { environment["STAND_IN_PI_HANG"] = "1" }
            return PiSkillsLoader(agentDirectory: agent, launch: .node(try PiSkillsLoaderTests.node(), package: package ?? self.package),
                                  environment: environment, timeout: timeout)
        }

        var runs: Int {
            ((try? String(contentsOf: package.appendingPathComponent("runs.log"), encoding: .utf8)) ?? "").split(separator: "\n").count
        }
    }

    /// The node pi would run on: the first on PATH, else a usual place.
    static func node() throws -> URL {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let places = path + ["/opt/homebrew/bin", "/usr/local/bin", "/run/current-system/sw/bin", NSHomeDirectory() + "/.nix-profile/bin"]
        let found = places.map { $0 + "/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        return URL(fileURLWithPath: try #require(found, "these tests run the loader on node"))
    }

    @Test func theLoaderListsWhatPiLoadsOutsideShepherdsFolder() throws {
        let fixture = try Fixture()
        let pi = try fixture.loader().read(installedDirectory: fixture.installed)
        #expect(pi.problem == nil)
        #expect(pi.agentDirectory == "~/../agent" || pi.agentDirectory.hasSuffix("/agent"))
        let used = pi.skills.filter(\.isUsed)
        #expect(used.map(\.name) == ["alpha", "beta", "gamma", "epsilon"])
        #expect(used.map(\.origin) == [.agentDirectory, .agentDirectory, .settingsPath, .package])
        #expect(used.first { $0.name == "beta" }?.invocation == .slashOnly)
        #expect(used.first { $0.name == "epsilon" }?.package == "@acme/team-skills")
        // Shepherd's own alpha loses to pi's; the package's delta loses to Shepherd's.
        #expect(pi.shadowedInstalled.keys.sorted() == ["alpha"])
        #expect(pi.shadowedInstalled["alpha"]?.hasSuffix("agent/skills/alpha/SKILL.md") == true)
        let passedOver = pi.skills.filter { !$0.isUsed }
        #expect(passedOver.map(\.name) == ["delta"])
        #expect(passedOver.first?.shadowedBy == "~/.agents/skills/delta/SKILL.md")
    }

    /// A read is kept until a folder it came from changes; a new skill in pi's folder shows on
    /// the next read.
    @Test func aReadIsKeptUntilAFolderItCameFromChanges() throws {
        let fixture = try Fixture()
        let loader = try fixture.loader()
        let first = loader.read(installedDirectory: fixture.installed)
        #expect(loader.read(installedDirectory: fixture.installed) == first)
        #expect(fixture.runs == 1)
        try fixture.skill("agent/skills/zeta", "zeta", "Added by hand.")
        let second = loader.read(installedDirectory: fixture.installed)
        #expect(fixture.runs == 2)
        #expect(second.skills.contains { $0.name == "zeta" })
    }

    @Test func withoutPiThePageSaysWhy() throws {
        let fixture = try Fixture()
        let pi = try fixture.loader(package: fixture.root.appendingPathComponent("nowhere")).read(installedDirectory: fixture.installed)
        #expect(pi.problem == PiSkills.Problem.piNotFound.rawValue)
        #expect(pi.skills.isEmpty)
    }

    @Test func aPiThatNeverAnswersIsStopped() throws {
        let fixture = try Fixture()
        let pi = try fixture.loader(timeout: 1, hang: true).read(installedDirectory: fixture.installed)
        #expect(pi.problem == PiSkills.Problem.timedOut.rawValue)
    }

    /// Every answer a host's store gives carries pi's skills, and the page's model groups them:
    /// pi's setup, then its packages; the installed skill pi passes over is marked.
    @MainActor
    @Test func aHostsSkillsCarryPisAndThePageGroupsThem() async throws {
        let fixture = try Fixture()
        let loader = try fixture.loader()
        let store = SkillsStore(directory: fixture.installed, stateDirectory: fixture.root.appendingPathComponent("state"),
                                piSkills: { loader.read(installedDirectory: $0) })
        guard case .skills(let snapshot) = try store.perform(.fetch) else { Issue.record("no skills"); return }
        #expect(snapshot.skills.map(\.name) == ["alpha", "delta"])
        #expect(snapshot.pi?.skills.count == 5)
        guard case .skills(let changed) = try store.perform(.setOn(name: "alpha", on: false)) else { Issue.record("no skills"); return }
        // Off, Shepherd's alpha is out of pi's sight, so nothing passes it over.
        #expect(changed.pi?.shadowedInstalled.isEmpty == true)
        guard case .skills(let back) = try store.perform(.setOn(name: "alpha", on: true)) else { Issue.record("no skills"); return }
        #expect(back.pi?.shadowedInstalled.keys.sorted() == ["alpha"])

        let hosts = [SkillsHost(id: UUID(), name: "This Mac", client: StoreClient(store: store), serves: true)]
        let model = ClientSkills(defaults: ScratchDefaults())
        await model.refresh(hosts)
        let groups = model.piGroups(in: hosts)
        #expect(groups.map(\.kind) == [.setup, .packages])
        #expect(groups[0].rows.map(\.name) == ["alpha", "beta", "gamma"])
        #expect(groups[1].rows.map(\.name) == ["delta", "epsilon"])
        #expect(model.row("alpha", in: hosts)?.shadowedBy != nil)
        #expect(model.row("delta", in: hosts)?.shadowedBy == nil)
    }
}

/// A host's store answering as its Settings page reaches it.
private final class StoreClient: SkillsClient, @unchecked Sendable {
    let store: SkillsStore
    init(store: SkillsStore) { self.store = store }
    func skills(_ request: RemoteSkillsRequest) async throws -> RemoteSkillsResult { try store.perform(request) }
}
