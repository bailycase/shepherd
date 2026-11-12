import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Fleet's skills and extensions between real scratch hosts: a skill installed, switched or removed
/// on one Mac is the same on the others through `SkillsStore`; an extension someone copied from a
/// path (or works on in a folder) is content under `your-extensions/` on every Mac, loaded from
/// there; and what a device may not read stays unread. Each `Mac` has its own skills folders and pi home.
@Suite("Fleet content sync", .integrationTimeLimit)
struct FleetContentSyncTests {
    typealias Mac = FleetSyncTests.Mac

    static let pdf = "---\nname: pdf\ndescription: Read, fill, merge and split PDFs.\n---\n# PDF\n\nRun scripts/run.sh.\n"

    /// A repository with one skill (a script in it), and a way to install it on a Mac as its Settings does.
    struct Repo {
        let directory: URL
        var url: String { "file://" + directory.path }

        init() throws {
            directory = try makeScratchRepo(files: ["skills/pdf/SKILL.md": FleetContentSyncTests.pdf, "skills/pdf/scripts/run.sh": "#!/bin/sh\necho pdf\n"])
        }

        func install(on mac: Mac) async throws {
            try await mac.local.skills(.install(repo: url, paths: ["skills/pdf"], commit: nil, invocation: nil))
        }
    }

    static func skills(_ mac: Mac) -> [InstalledSkill] { mac.server.skills.snapshot().skills }
    static func skill(_ name: String, on mac: Mac) -> InstalledSkill? { skills(mac).first { $0.name == name } }
    static func folder(_ mac: Mac, _ name: String, off: Bool = false) -> URL {
        let base = off ? mac.server.skills.stateDirectory.appendingPathComponent("off", isDirectory: true) : mac.server.skills.directory
        return base.appendingPathComponent(name, isDirectory: true)
    }
    static func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    func waitForSkill(_ name: String, on mac: Mac, isOn: Bool = true) async throws {
        try await eventually("\(mac.name) to have the skill \(name) \(isOn ? "on" : "off")") { Self.skill(name, on: mac)?.isOn == isOn }
    }

    // MARK: Skills

    @Test func aSkillInstalledOnOneMacAppearsOnTheOtherWithItsFilesAndSource() async throws {
        let (a, b) = try await FleetSyncTests.pair()
        defer { a.stop(); b.stop() }
        let repo = try Repo()
        try await repo.install(on: a)
        try await waitForSkill("pdf", on: b)

        try await eventually("B to know where it came from") { Self.skill("pdf", on: b)?.source != nil }
        let there = try #require(Self.skill("pdf", on: b))
        #expect(there.source?.repo == repo.url && there.source == Self.skill("pdf", on: a)?.source, "it came from the same repository at the same commit")
        #expect(there.summary == "Read, fill, merge and split PDFs.")
        #expect(Self.text(Self.folder(b, "pdf").appendingPathComponent("SKILL.md")) == Self.pdf)
        let script = Self.folder(b, "pdf").appendingPathComponent("scripts/run.sh")
        #expect(Self.text(script) == "#!/bin/sh\necho pdf\n")
        #expect(FileManager.default.isExecutableFile(atPath: script.path), "a script that starts with #! stays runnable")

        // Nobody echoed anything back: the ops are A's alone and nothing was superseded.
        try await eventually("both Macs to settle") { try await [a.syncStatus(), b.syncStatus()].allSatisfy { $0.peers.allSatisfy { $0.state == .inSync } } }
        #expect(b.server.fleetSyncWinner(FleetUnit.skill("pdf"))?.macName == "MacBook Pro")
        #expect(a.server.fleetSyncHistory(FleetUnit.skill("pdf")).isEmpty && b.server.fleetSyncHistory(FleetUnit.skill("pdf")).isEmpty)
        #expect(a.server.fleetSyncWinner(FleetUnit.skillFile("pdf", "scripts/run.sh"))?.blobHash == FleetSyncProtocol.hash(Data("#!/bin/sh\necho pdf\n".utf8)))
    }

    @Test func turningASkillOffOrChangingHowItIsUsedOnOneMacAppliesOnTheOther() async throws {
        let (a, b) = try await Self.pairWithPdf()
        defer { a.stop(); b.stop() }

        try await a.local.skills(.setOn(name: "pdf", on: false))
        try await waitForSkill("pdf", on: b, isOn: false)
        #expect(FileManager.default.fileExists(atPath: Self.folder(b, "pdf", off: true).appendingPathComponent("SKILL.md").path), "off means out of the folder pi reads")
        #expect(!FileManager.default.fileExists(atPath: Self.folder(b, "pdf").path))

        // And back, from the other side, with a different use: the later change wins on both.
        try await b.local.skills(.setOn(name: "pdf", on: true))
        try await waitForSkill("pdf", on: a)
        try await b.local.skills(.setInvocation(name: "pdf", invocation: .slashOnly))
        try await eventually("A to use it only with /skill") { Self.skill("pdf", on: a)?.invocation == .slashOnly }
        #expect(Self.skill("pdf", on: a)?.isOn == true && Self.skill("pdf", on: b)?.invocation == .slashOnly)
    }

    @Test func removingASkillRemovesItEverywhereAndUndoBringsItBack() async throws {
        let (a, b) = try await Self.pairWithPdf()
        defer { a.stop(); b.stop() }

        try await a.local.skills(.remove(name: "pdf"))
        try await eventually("B to lose the skill") { Self.skill("pdf", on: b) == nil }
        #expect(!FileManager.default.fileExists(atPath: Self.folder(b, "pdf").path))
        #expect(b.server.skills.snapshot().skills.isEmpty)

        try await a.local.skills(.restore(name: "pdf"))
        try await waitForSkill("pdf", on: b)
        #expect(Self.text(Self.folder(b, "pdf").appendingPathComponent("scripts/run.sh")) == "#!/bin/sh\necho pdf\n")
    }

    @Test func updateAutomaticallyIsTheSameOnEveryMac() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try await a.local.skills(.configure(autoUpdate: true))
        try await eventually("B to update automatically") { b.server.skills.snapshot().autoUpdate }
        try await b.local.skills(.configure(autoUpdate: false))
        try await eventually("A to follow B") { !a.server.skills.snapshot().autoUpdate }
    }

    @Test func aSkillAMacHadBeforeFleetIsSharedAndOnesOnBothAreNotMixedUp() async throws {
        let a = try await Mac("MacBook Pro", enable: false), b = try await Mac("Mac mini", enable: false)
        defer { a.stop(); b.stop() }
        // Hand copied folders (Local skills): one only the mini has, and one both have, differently.
        try Self.makeLocal("notes", in: b, skill: "---\nname: notes\ndescription: The mini's notes.\n---\n")
        try Self.makeLocal("changelog", in: a, skill: "---\nname: changelog\ndescription: The MacBook Pro's.\n---\n")
        a.enable()
        try await eventually("A to seed the fleet") { a.server.fleetSyncWinner(FleetUnit.skill("changelog")) != nil }
        // The mini's seeds must be later readings than A's, whatever the millisecond.
        let before = Int(Date().timeIntervalSince1970 * 1000)
        try await eventually("the clock to move on") { Int(Date().timeIntervalSince1970 * 1000) > before }
        try Self.makeLocal("changelog", in: b, skill: "---\nname: changelog\ndescription: The mini's own.\n---\n")
        b.enable()
        try await a.pair(with: b)
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)

        try await waitForSkill("notes", on: a)
        #expect(Self.skill("changelog", on: a)?.summary == "The MacBook Pro's.", "the Mac where Fleet was first on is the reference")
        try await eventually("the mini to take the reference's changelog") { Self.skill("changelog", on: b)?.summary == "The MacBook Pro's." }
        #expect(!b.server.fleetSyncHistory(FleetUnit.skillFile("changelog", "SKILL.md")).isEmpty, "the mini's own copy is kept in the fleet's history")
    }

    @Test func aMacAwayCatchesUpOnSkillsFromAnotherMacWhenTheInstallerIsGone() async throws {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini"), c = try await Mac("Mac Studio")
        var back: Mac?
        defer { b.stop(); back?.stop() }
        try await a.pair(with: b)
        try await a.pair(with: c)
        for (one, other) in [(a, b), (b, a), (a, c), (c, a), (b, c), (c, b)] { try await one.waitForLink(to: other) }

        let (cDir, cPort) = (c.host.dir, c.port)
        c.stop(keepFiles: true)
        try await Repo().install(on: a)
        try await waitForSkill("pdf", on: b)
        a.stop()
        try await eventually("B to see A gone") { try await b.read().peers.first { $0.name == "MacBook Pro" }?.link != .connected }

        let studio = try await Mac("Mac Studio", dir: cDir, port: cPort)
        back = studio
        try await waitForSkill("pdf", on: studio)
        #expect(Self.text(Self.folder(studio, "pdf").appendingPathComponent("SKILL.md")) == Self.pdf, "the files came from the mini, the ops are the MacBook Pro's")
    }

    @Test func skillsThePiLoadsFromElsewhereAndOnesFleetIsOffForNeverTravel() async throws {
        let a = try await Mac("MacBook Pro", enable: false)
        defer { a.stop() }
        try Self.makeLocal("kept-home", in: a, skill: "---\nname: kept-home\ndescription: Not yet shared.\n---\n")
        #expect(!FileManager.default.fileExists(atPath: a.host.dir.appendingPathComponent("fleet/store").path), "with Fleet off nothing is read or kept")
        a.enable()
        try await eventually("the skill to be seeded once Fleet is on") { a.server.fleetSyncWinner(FleetUnit.skill("kept-home")) != nil }
        // A name that would leave the skill's folder is refused, never written.
        #expect(!FleetUnit.isValid("skill:pdf/../../x") && FleetFileTree.isSafe("scripts/run.sh") && !FleetFileTree.isSafe("../x") && !FleetFileTree.isSafe("/etc/hosts"))
    }

    @Test func aPeerCannotWriteASkillFileOutsideTheSkillsFolder() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let peer = try await Self.connectAsPeer(a, to: b)
        defer { peer.client.disconnect() }
        let start = try await peer.client.fleetSyncState(.hello(vector: FleetVersionVector()))
        let hlc = FleetHLC(wallMs: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000)
        let payload = Data("pwned".utf8)
        let hash = FleetSyncProtocol.hash(payload)
        // A skill file whose path climbs out, one whose skill name is a path, and an extension file that does.
        let ops = [
            FleetOp(mac: peer.id, seq: start[peer.id] + 1, hlc: hlc, unit: "skill:pdf/x/y", change: .blob(hash: hash, size: payload.count), macName: "MacBook Pro"),
            FleetOp(mac: peer.id, seq: start[peer.id] + 2, hlc: hlc, unit: "extension:/etc/shepherd-test", change: .blob(hash: hash, size: payload.count), macName: "MacBook Pro"),
            FleetOp(mac: peer.id, seq: start[peer.id] + 3, hlc: hlc, unit: "extension:files/../../escape", change: .blob(hash: hash, size: payload.count), macName: "MacBook Pro"),
        ]
        let vector = try await peer.client.fleetSyncState(.ops(ops))
        #expect(vector[peer.id] == start[peer.id] + 2, "the one with `..` in its name is refused at the door; the others are only stored")
        // The blob follows (it is fetched on demand), but nothing is written outside the folders.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: "/etc/shepherd-test"))
        #expect(!FileManager.default.fileExists(atPath: b.server.pi.home.deletingLastPathComponent().appendingPathComponent("escape").path))
    }

    // MARK: Extensions

    /// The user's own pi, with an extension folder of theirs on this Mac that its settings.json lists by absolute path.
    struct YourPiFixture {
        let userHome: URL
        let agent: URL
        let dev: URL

        init() throws {
            userHome = try makeScratchDirectory("yourpi")
            agent = userHome.appendingPathComponent("agent", isDirectory: true)
            dev = userHome.appendingPathComponent("dev/acme-tool", isDirectory: true)
            try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dev.appendingPathComponent("lib"), withIntermediateDirectories: true)
            try "export default function acme() {}\n".write(to: dev.appendingPathComponent("index.ts"), atomically: true, encoding: .utf8)
            try "export const helper = 1\n".write(to: dev.appendingPathComponent("lib/helper.ts"), atomically: true, encoding: .utf8)
            let settings = ["extensions": [dev.path]]
            try JSONSerialization.data(withJSONObject: settings).write(to: agent.appendingPathComponent("settings.json"))
        }

        /// What Settings ▸ Pi ▸ From your pi does: copy the extensions, then switch this one on.
        func importAndSwitchOn(on mac: Mac) throws -> String {
            let imports = YourPiImport(home: mac.server.pi.files, yourPi: YourPi(agentDirectory: agent), userHome: userHome.path, log: { _ in })
            _ = try imports.reimport(.files(.extensions))
            let copy = try #require(imports.state()?.copies(.extensions).first { $0.name == "acme-tool" })
            try imports.setExtension(copy.destination, on: true)
            return copy.destination
        }
    }

    static func extensionFile(_ mac: Mac, _ relative: String) -> URL {
        mac.server.pi.home.appendingPathComponent("your-extensions/\(relative)")
    }

    @Test func anAbsoluteExtensionPathIsImportedAsContentAndTheOtherMacLoadsItFromItsOwnFolder() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let theirs = try YourPiFixture()
        let destination = try theirs.importAndSwitchOn(on: a)
        #expect(destination == "your-extensions/paths/acme-tool")

        let copied = Self.extensionFile(b, "paths/acme-tool/index.ts")
        let entry = copied.standardizedFileURL.path
        let wholeFiles = ["index.ts": "export default function acme() {}\n", "lib/helper.ts": "export const helper = 1\n"]
        // Files arrive in any order, but pi is only ever told about the extension once they are all there.
        try await eventually("B's settings.json to list the extension") {
            let listed = ((try b.piJSON())["extensions"] as? [String])?.contains(entry) == true
            if listed {
                for (path, text) in wholeFiles {
                    #expect(Self.text(Self.extensionFile(b, "paths/acme-tool/" + path)) == text, "listed with \(path) missing or partial")
                }
            }
            return listed
        }
        for (path, text) in wholeFiles { #expect(Self.text(Self.extensionFile(b, "paths/acme-tool/" + path)) == text) }

        // B loads it by its own absolute path, not A's or the folder on A.
        let listed = (try b.piJSON()["extensions"] as? [String]) ?? []
        #expect(!listed.contains { $0.contains(theirs.dev.path) || $0.contains(a.server.pi.home.path) }, "the store holds no machine path")
        // The state is saved just after the settings it wrote.
        try await eventually("B to record the copy") { b.server.pi.importedState().state()?.copies(.extensions).isEmpty == false }
        let state = try #require(b.server.pi.importedState().state())
        #expect(state.extensionsOn == [destination] && state.copies(.extensions).first?.name == "acme-tool", "the extension is on, as it is on A")
        #expect(state.copies(.extensions).first?.source == "", "nothing says where it came from on another Mac")
    }

    @Test func everySaveInALinkedExtensionFolderReachesTheOtherMacWithoutAPushStep() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let theirs = try YourPiFixture()
        _ = try theirs.importAndSwitchOn(on: a)
        try await eventually("B to hold the first version") { Self.text(Self.extensionFile(b, "paths/acme-tool/index.ts")) == "export default function acme() {}\n" }

        // A person saves in the folder on A: no command, no button.
        let started = ContinuousClock.now
        try "export default function acme() { return 2 }\n".write(to: theirs.dev.appendingPathComponent("index.ts"), atomically: true, encoding: .utf8)
        try await eventually("B to hold the saved file") { Self.text(Self.extensionFile(b, "paths/acme-tool/index.ts")) == "export default function acme() { return 2 }\n" }
        #expect(ContinuousClock.now - started < .seconds(10), "within the watcher's latency, not a poll of minutes")
        #expect(Self.text(Self.extensionFile(a, "paths/acme-tool/index.ts")) == "export default function acme() { return 2 }\n", "A's own copy follows its folder")

        // A new file and a deleted one travel too, and the folder itself is never touched.
        try "export const more = 3\n".write(to: theirs.dev.appendingPathComponent("lib/more.ts"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: theirs.dev.appendingPathComponent("lib/helper.ts"))
        try await eventually("B to add and drop a file") {
            Self.text(Self.extensionFile(b, "paths/acme-tool/lib/more.ts")) == "export const more = 3\n"
                && !FileManager.default.fileExists(atPath: Self.extensionFile(b, "paths/acme-tool/lib/helper.ts").path)
        }
        #expect(Self.text(theirs.dev.appendingPathComponent("index.ts")) == "export default function acme() { return 2 }\n")
        try await eventually("both Macs to settle") { try await [a.syncStatus(), b.syncStatus()].allSatisfy { $0.peers.allSatisfy { $0.state == .inSync } } }
    }

    @Test func switchingAnExtensionOffOnOneMacSwitchesItOffOnTheOther() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let theirs = try YourPiFixture()
        let destination = try theirs.importAndSwitchOn(on: a)
        let entry = Self.extensionFile(b, "paths/acme-tool/index.ts").standardizedFileURL.path
        try await eventually("B to load it") { ((try b.piJSON())["extensions"] as? [String])?.contains(entry) == true }

        try a.server.pi.importedState().setExtension(destination, on: false)
        try await eventually("B to stop loading it") {
            ((try b.piJSON())["extensions"] as? [String])?.contains(entry) != true && b.server.pi.importedState().state()?.extensionsOn.isEmpty == true
        }
        #expect(FileManager.default.fileExists(atPath: entry), "its files stay")
    }

    // MARK: Who may read it

    @Test func aDeviceWithATokenOfItsOwnCannotFetchASkillOrExtensionUnit() async throws {
        let (a, b) = try await Self.pairWithPdf()
        defer { a.stop(); b.stop() }
        let theirs = try YourPiFixture()
        _ = try theirs.importAndSwitchOn(on: a)
        try await eventually("B to hold the extension") { Self.text(Self.extensionFile(b, "paths/acme-tool/index.ts")) != nil }

        let token = FleetProtocol.makeToken()
        let intro = FleetDeviceIntroduction(deviceID: UUID(), name: "iPhone", kind: .iphone, tokenHash: FleetProtocol.hash(token))
        let code = try #require(try await a.local.fleetAction(.startDeviceCode).deviceCode).code
        _ = try await RemoteHostClient.fleetPairDevice(host: "127.0.0.1", port: a.port, code: code, device: intro)
        let phone = RemoteHostClient()
        defer { phone.disconnect() }
        _ = try await phone.connect(host: "127.0.0.1", port: a.port, token: token, clientName: "iPhone")

        let script = FleetSyncProtocol.hash(Data("#!/bin/sh\necho pdf\n".utf8))
        let extensionFile = FleetSyncProtocol.hash(Data("export default function acme() {}\n".utf8))
        for hash in [script, extensionFile] {
            do { _ = try await phone.fleetBlob(hash: hash, size: 1); Issue.record("a device read a unit") }
            catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.forbidden) }
        }
        do { _ = try await phone.fleetSyncState(.hello(vector: FleetVersionVector())); Issue.record("a device synced") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.forbidden) }
        // It does still read the skills the way a client always did: its own list, from the host.
        let listed = try await phone.skills(.fetch)
        if case .skills(let snapshot) = listed { #expect(snapshot.skills.map(\.name) == ["pdf"]) } else { Issue.record("no skills answer") }
    }

    /// Fleet off is membership off: nothing of the skills or extensions is watched, kept or applied.
    @Test func withFleetOffSkillsAndExtensionsAreAsTheyWereBefore() async throws {
        let a = try await Mac("MacBook Pro", enable: false)
        defer { a.stop() }
        let repo = try Repo()
        try await repo.install(on: a)
        try await a.local.skills(.setOn(name: "pdf", on: false))
        try await a.local.skills(.setOn(name: "pdf", on: true))
        #expect(Self.skill("pdf", on: a)?.isOn == true)
        _ = try YourPiFixture().importAndSwitchOn(on: a)
        #expect(!FileManager.default.fileExists(atPath: a.host.dir.appendingPathComponent("fleet/store").path), "no store until Fleet is on")
        #expect(!(try await a.read()).enabled)
    }

    // MARK: Helpers

    static func pair() async throws -> (Mac, Mac) { try await FleetSyncTests.pair() }

    static func pairWithPdf() async throws -> (Mac, Mac) {
        let (a, b) = try await pair()
        do {
            try await Repo().install(on: a)
            try await FleetContentSyncTests().waitForSkill("pdf", on: b)
        } catch {
            a.stop(); b.stop()
            throw error
        }
        return (a, b)
    }

    static func makeLocal(_ name: String, in mac: Mac, skill: String) throws {
        let folder = folder(mac, name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try skill.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    /// A client holding `from`'s peer token, as another Mac's host would connect to `to`.
    static func connectAsPeer(_ from: Mac, to: Mac) async throws -> (client: RemoteHostClient, id: UUID) {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: from.host.dir.appendingPathComponent("fleet/peers.json"))) as? [String: Any])
        let token = try #require((json["peers"] as? [[String: Any]])?.first?["myToken"] as? String)
        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: to.port, token: token, clientName: from.name, capabilities: [], fetchesState: false)
        return (client, try #require(try await from.read().hostID))
    }
}
