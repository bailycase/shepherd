import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Fleet's sync engine end to end between real scratch hosts: what one Mac saves, another
/// materializes through its own writers; what a Mac missed it takes when it is back, from any Mac
/// that has it; two writes to one unit resolve by the later and keep the other in history; and pi's
/// own rewrite of `settings.json` is imported, never overwritten. Each `Mac` has its own pi home.
@Suite("Fleet sync", .integrationTimeLimit)
struct FleetSyncTests {
    /// A scratch host in a fleet, with its own pi home and a stand-in for the app's settings.
    final class Mac: @unchecked Sendable {
        let host: ScratchServer
        let port: UInt16
        let name: String
        let local: RemoteHostClient
        let sharedToken: String
        /// The host settings the app would hold, as the app reports and applies them.
        let settings = Locked(HostSettings())
        var server: SessionServer { host.server }
        var piSettings: URL { server.pi.files.settings }

        /// `enable: false` leaves Fleet off so a test can set this Mac's files first.
        init(_ name: String, dir: URL? = nil, port: UInt16 = 0, enable: Bool = true) async throws {
            self.name = name
            let scratch = try dir ?? makeScratchDirectory("sync")
            let pi = PiSetup(engine: PiSetup.app.engine, home: scratch.appendingPathComponent("pi"), userHome: scratch.path)
            // A real host has made its pi home by the time anything syncs.
            try FileManager.default.createDirectory(at: pi.home, withIntermediateDirectories: true)
            let host = try ScratchServer(dir: scratch, pi: pi)
            let server = host.server
            server.configureFleet(name: name, advertises: false)
            let tokenURL = host.dir.appendingPathComponent("remote-token")
            let socket = host.dir.appendingPathComponent("h.sock").path
            let port = try server.startRemoteListener(port: port, tokenURL: tokenURL)
            let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            try server.startLocalListener(path: socket, tokenURL: tokenURL)
            let local = RemoteHostClient(localSocket: socket)
            _ = try await local.connect(host: "", port: 0, token: token, clientName: "Shepherd")
            (self.host, self.port, self.sharedToken, self.local) = (host, port, token, local)
            let settings = settings
            server.setFleetHostSettings { [weak server] change in
                let now = settings.withValue { $0.apply(change); return $0 }
                server?.fleetHostSettingsChanged(now)
            }
            server.fleetHostSettingsChanged(settings.current)
            if enable { server.setFleetEnabled(true) }
        }

        func enable() { server.setFleetEnabled(true) }

        func stop(keepFiles: Bool = false) {
            local.disconnect()
            host.stop(keepFiles: keepFiles)
        }

        func read() async throws -> FleetSnapshot { try await local.fleetRead().snapshot }

        @discardableResult
        func pair(with other: Mac) async throws -> FleetPeerStatus {
            let code = try #require(try await other.local.fleetAction(.startJoin).join).code
            return try #require(try await local.fleetAction(.pair(host: "127.0.0.1", port: other.port, code: code)).paired)
        }

        func waitForLink(to other: Mac) async throws {
            try await eventually("\(name) to hold a link to \(other.name)") {
                try await self.read().peers.contains { $0.name == other.name && $0.link == .connected }
            }
        }

        // What a person does here.
        func save(_ file: InstructionFile, _ text: String) async throws {
            _ = try await local.instructions(.save(file: file, content: text, origin: "", sync: false))
        }

        func text(_ file: InstructionFile) -> String { server.instructions.content(file) }

        func waitForText(_ file: InstructionFile, _ text: String) async throws {
            try await eventually("\(name)'s \(file.fileName) to read \(text.prefix(24))") { self.text(file) == text }
        }

        func change(_ change: HostSettingChange) {
            let now = settings.withValue { $0.apply(change); return $0 }
            server.fleetHostSettingsChanged(now)
        }

        func piJSON() throws -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: piSettings)) as? [String: Any]) ?? [:]
        }

        func syncStatus() async throws -> FleetSyncStatus { try #require(try await read().sync) }
    }

    static let agents = FleetUnit.instruction(.agents)

    /// Two paired Macs with links both ways.
    static func pair() async throws -> (Mac, Mac) {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini")
        try await a.pair(with: b)
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)
        return (a, b)
    }

    // MARK: Edit on one Mac, the other has it

    @Test func anEditOnOneMacMaterializesOnTheOtherThroughItsOwnWriter() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try await a.save(.agents, "# How I work\n- Small commits.\n")
        try await b.waitForText(.agents, "# How I work\n- Small commits.\n")

        // B's own Settings history shows where it came from, like any sync.
        let history = try await b.local.instructions(.fetch).history.filter { $0.file == .agents }
        #expect(history.first?.summary == "Synced from MacBook Pro" && history.count == 1)

        // And back: an edit on B reaches A, and the file on A is the real one the instructions extension reads.
        try await b.save(.appendSystem, "Never force-push.")
        try await a.waitForText(.appendSystem, "Never force-push.")
        let onDisk = try String(contentsOf: a.server.instructions.directory.appendingPathComponent("APPEND_SYSTEM.md"), encoding: .utf8)
        #expect(onDisk == "Never force-push.")

        // Neither echoed the other's write back as an op: one op each way, no more.
        try await eventually("both Macs to settle") {
            try await [a.syncStatus(), b.syncStatus()].allSatisfy { $0.peers.allSatisfy { $0.state == .inSync } }
        }
        #expect(a.server.fleetSyncWinner(Self.agents) == b.server.fleetSyncWinner(Self.agents), "both Macs agree on what decides the unit")
        #expect(a.server.fleetSyncHistory(Self.agents).isEmpty && b.server.fleetSyncHistory(Self.agents).isEmpty, "nothing was superseded")
    }

    /// The Mac's own Settings page (and any client showing the files) hears of a synced write, as it does of any save.
    @Test func aSyncedWriteIsAnnouncedLikeAnySave() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let heard = Locked<[String]>([])
        b.server.onInstructionsChanged = { snapshot in heard.withValue { $0.append(snapshot.agents) } }
        try await a.save(.agents, "from the MacBook Pro")
        try await eventually("B's Settings to hear of it") { heard.current.contains("from the MacBook Pro") }
    }

    @Test func aLargeFileTravelsAsABlobInChunks() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let big = String(repeating: "A line of the agent's instructions that is not short.\n", count: 12_000)
        #expect(big.utf8.count > 2 * FleetSyncProtocol.blobChunkBytes)
        try await a.save(.agents, big)
        try await b.waitForText(.agents, big)
        let winner = try #require(b.server.fleetSyncWinner(Self.agents))
        #expect(winner.blobHash == FleetSyncProtocol.hash(Data(big.utf8)), "content addressed: the hash is the text's")
    }

    // MARK: A Mac that was away

    @Test func anEditWhileAMacIsOfflineCatchesUpWhenItIsBack() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop() }
        let (dir, port) = (b.host.dir, b.port)
        b.stop(keepFiles: true)
        try await eventually("A to see B go") { try await a.read().peers.first?.link != .connected }
        #expect(try await a.syncStatus().peers.first?.state == .offline, "the sync line says it is asleep and catches up")

        try await a.save(.agents, "written while the mini was away")
        let back = try await Mac("Mac mini", dir: dir, port: port)
        defer { back.stop() }
        try await back.waitForText(.agents, "written while the mini was away")
        try await a.waitForLink(to: back)
        try await eventually("A to see the mini in sync") { try await a.syncStatus().peers.first?.state == .inSync }
    }

    /// A to B to C with A gone: ops are relayed verbatim by whichever Mac holds them.
    @Test func aMacCatchesUpFromAnotherMacWhenTheWriterIsGone() async throws {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini"), c = try await Mac("Mac Studio")
        var back: Mac?
        defer { b.stop(); back?.stop() }
        try await a.pair(with: b)
        try await a.pair(with: c)
        for (one, other) in [(a, b), (b, a), (a, c), (c, a), (b, c), (c, b)] { try await one.waitForLink(to: other) }

        let (cDir, cPort) = (c.host.dir, c.port)
        c.stop(keepFiles: true)
        try await a.save(.agents, "from the MacBook Pro")
        try await b.waitForText(.agents, "from the MacBook Pro")
        a.stop()
        try await eventually("B to see A gone") { try await b.read().peers.first { $0.name == "MacBook Pro" }?.link != .connected }

        let studio = try await Mac("Mac Studio", dir: cDir, port: cPort)
        back = studio
        try await studio.waitForText(.agents, "from the MacBook Pro")
        #expect(studio.server.fleetSyncWinner(Self.agents)?.macName == "MacBook Pro", "the op is the MacBook Pro's, relayed untouched")
    }

    // MARK: Two writes to one unit

    @Test func concurrentEditsResolveByTheLaterAndTheLoserIsKeptInHistory() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop() }
        try await a.save(.agents, "base")
        try await b.waitForText(.agents, "base")
        let (dir, port) = (b.host.dir, b.port)
        b.stop(keepFiles: true)
        try await eventually("A to see B go") { try await a.read().peers.first?.link != .connected }

        // Both change the file while apart: A through its Settings, B by hand on its disk.
        try await a.save(.agents, "A's edit")
        try Data("B's edit".utf8).write(to: dir.appendingPathComponent("instructions/AGENTS.md"))
        let back = try await Mac("Mac mini", dir: dir, port: port)
        defer { back.stop() }
        try await a.waitForLink(to: back)

        // B's was noticed when it came back, after A's: the later write wins on both Macs.
        try await a.waitForText(.agents, "B's edit")
        try await back.waitForText(.agents, "B's edit")
        let kept = { (mac: Mac) in
            mac.server.fleetSyncHistory(Self.agents).compactMap { entry -> Data? in
                if case .blob(let hash, _) = entry.change { return try? Data(contentsOf: mac.server.fleetStoreDirectory!.appendingPathComponent("blobs/\(hash)")) }
                return nil
            }.map { String(decoding: $0, as: UTF8.self) }
        }
        try await eventually("the loser in both Macs' history") { kept(a).contains("A's edit") && kept(back).contains("A's edit") }
        #expect(a.server.fleetSyncWinner(Self.agents) == back.server.fleetSyncWinner(Self.agents))
    }

    // MARK: pi writes settings.json too

    @Test func aPiSettingIsImportedAndAppliedWithoutTouchingTheKeysShepherdOwns() async throws {
        let a = try await Mac("MacBook Pro", enable: false), b = try await Mac("Mac mini", enable: false)
        defer { a.stop(); b.stop() }
        // Each Mac's pi home has Shepherd's own keys, which differ and are never synced.
        _ = try PiSettingsFile(url: a.piSettings).update { $0["shellCommandPrefix"] = "source A/restore-env.sh"; return [] }
        _ = try PiSettingsFile(url: b.piSettings).update { $0["shellCommandPrefix"] = "source B/restore-env.sh"; $0["theme"] = "light"; return [] }
        a.enable()
        b.enable()
        try await a.pair(with: b)
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)

        // pi on A rewrites its settings.json (the TUI's /settings), as pi does: the whole file, by rename.
        var object = try a.piJSON()
        object["theme"] = "dark"
        object["hideThinkingBlock"] = true
        let rewritten = a.piSettings.deletingLastPathComponent().appendingPathComponent(".settings.json.pi")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: rewritten)
        #expect(rename(rewritten.path, a.piSettings.path) == 0)

        try await eventually("pi's change to reach B") {
            let json = try b.piJSON()
            return json["theme"] as? String == "dark" && json["hideThinkingBlock"] as? Bool == true
        }
        let atB = try b.piJSON()
        #expect(atB["shellCommandPrefix"] as? String == "source B/restore-env.sh", "Shepherd's own keys on B are left exactly as they were")
        #expect(try a.piJSON()["shellCommandPrefix"] as? String == "source A/restore-env.sh")

        // And pi on B writing a different key is imported by B, not clobbered by A's value.
        _ = try PiSettingsFile(url: b.piSettings).update { $0["steeringMode"] = "all"; return [] }
        try await eventually("B's own pi write to reach A") { try a.piJSON()["steeringMode"] as? String == "all" }
        #expect(try b.piJSON()["theme"] as? String == "dark", "and nothing else was reverted")
    }

    @Test func aKeyShepherdManagesIsNeverSyncedEvenIfAPeerSendsIt() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        _ = try PiSettingsFile(url: b.piSettings).update { $0["shellCommandPrefix"] = "source B/restore-env.sh"; return [] }

        // A peer with a valid token sends an op for a key that isn't in the allowlist, and one with a bad name.
        let token = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: a.host.dir.appendingPathComponent("fleet/peers.json"))) as? [String: Any])
        let peers = try #require(token["peers"] as? [[String: Any]])
        let aToken = try #require(peers.first?["myToken"] as? String)
        let peer = RemoteHostClient()
        _ = try await peer.connect(host: "127.0.0.1", port: b.port, token: aToken, clientName: "MacBook Pro", capabilities: [], fetchesState: false)
        defer { peer.disconnect() }
        let aID = try #require(try await a.read().hostID)
        let start = try await peer.fleetSyncState(.hello(vector: FleetVersionVector()))
        let next = start[aID] + 1
        let managed = FleetOp(mac: aID, seq: next, hlc: FleetHLC(wallMs: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000),
                              unit: "setting:pi.shellCommandPrefix", change: .value("\"rm -rf ~\""), macName: "MacBook Pro")
        var escape = managed
        escape.seq = next + 1
        escape.unit = "instruction:../../../etc/hosts"
        let vector = try await peer.fleetSyncState(.ops([managed, escape]))
        #expect(vector[aID] == next, "the op with a bad name was refused, the other only stored")
        #expect(try b.piJSON()["shellCommandPrefix"] as? String == "source B/restore-env.sh", "stored, never executed")
    }

    // MARK: Host settings

    @Test func aHostSettingChangedOnOneMacIsAppliedOnTheOtherThroughTheAppsOwnSetter() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        a.change(.defaultThinking(.high))
        a.change(.defaultModel("acme/model-1"))
        try await eventually("B to apply both settings") {
            let now = b.settings.current
            return now.defaultThinking == .high && now.defaultModel == "acme/model-1"
        }
        b.change(.defaultModel(nil))
        try await eventually("A to follow B's later change") { a.settings.current.defaultModel == nil && a.settings.current.defaultThinking == .high }
        // Per Mac settings never travel.
        a.change(.missionsEnabled(true))
        a.change(.fleetEnabled(true))
        try await eventually("A to report them") { a.settings.current.missionsEnabled }
        #expect(!b.settings.current.missionsEnabled && !b.settings.current.fleetEnabled)
    }

    @Test func aMacThatNeverChoseASettingDoesNotOutvoteOneThatDid() async throws {
        let a = try await Mac("MacBook Pro", enable: false), b = try await Mac("Mac mini", enable: false)
        defer { a.stop(); b.stop() }
        a.settings.withValue { $0.queueDelivery = .oneAtATime }
        a.server.fleetHostSettingsChanged(a.settings.current)
        a.enable()
        b.enable()
        try await a.pair(with: b)
        try await a.waitForLink(to: b)
        try await eventually("B to take A's choice") { b.settings.current.queueDelivery == .oneAtATime }
        #expect(a.settings.current.queueDelivery == .oneAtATime, "B's default seeded nothing, so it could not undo A's choice")
        #expect(b.server.fleetSyncWinner(FleetHostSetting.defaultThinking.unit) == nil, "a default is never an op")
    }

    // MARK: First sync

    @Test func theMacWhereFleetWasFirstOnIsTheReferenceAndTheOthersCopyIsKeptInHistory() async throws {
        let a = try await Mac("MacBook Pro", enable: false), b = try await Mac("Mac mini", enable: false)
        defer { a.stop(); b.stop() }
        try a.server.instructions.save(.agents, content: "# MacBook Pro's instructions")
        try b.server.instructions.save(.agents, content: "# Mac mini's own, different")
        try b.server.instructions.save(.appendSystem, content: "Only the mini has this.")
        a.enable()
        try await eventually("A to seed the fleet") { a.server.fleetSyncWinner(Self.agents) != nil }
        // B's seed must be a later clock reading than A's, whatever the millisecond.
        let before = Int(Date().timeIntervalSince1970 * 1000)
        try await eventually("the clock to move on") { Int(Date().timeIntervalSince1970 * 1000) > before }
        b.enable()
        try await a.pair(with: b)
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)

        try await b.waitForText(.agents, "# MacBook Pro's instructions")
        #expect(a.text(.agents) == "# MacBook Pro's instructions", "the reference keeps its own")
        // A file only the mini had is not lost: nothing on A competed with it.
        try await a.waitForText(.appendSystem, "Only the mini has this.")

        // The mini's replaced copy is in its history, and the sync line says so.
        let kept = try await b.local.instructions(.fetch).history.filter { $0.file == .agents }
        #expect(kept.contains { $0.summary == "Synced from MacBook Pro" } && kept.count >= 2, "the mini's own save is still in its Settings history beside the synced one")
        try await eventually("the notice on the mini's sync line") {
            try await b.syncStatus().notice == "Replaced AGENTS.md with MacBook Pro's. The old copy is in its history."
        }
        #expect(try await a.syncStatus().notice == nil, "the reference replaced nothing")
        let replaced = b.server.fleetSyncHistory(Self.agents)
        #expect(!replaced.isEmpty, "the mini's own text is also in the fleet store's history")
    }

    // MARK: Safety

    @Test func onlyAFleetMemberSyncsAndEveryoneElseIsRefused() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        // A phone or a legacy Mac holds the shared token, which is no fleet membership.
        let phone = RemoteHostClient()
        _ = try await phone.connect(host: "127.0.0.1", port: b.port, token: b.sharedToken, clientName: "iPhone")
        defer { phone.disconnect() }
        await #expect(throws: RemoteHostClientError.self) { _ = try await phone.fleetSyncState(.hello(vector: FleetVersionVector())) }
        await #expect(throws: RemoteHostClientError.self) { _ = try await phone.fleetBlob(hash: String(repeating: "0", count: 64), size: 1) }
        await #expect(throws: RemoteHostClientError.self) { _ = try await phone.fleetSyncState(.ops([])) }
    }

    /// A phone's own token makes it a client of the host, not a member: it is offered no sync capability and
    /// its sync requests are refused, so it can neither read the fleet's store nor write into it.
    @Test func aDeviceWithATokenOfItsOwnCannotSync() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try await a.save(.agents, "kept on the Macs")
        try await b.waitForText(.agents, "kept on the Macs")

        let token = FleetProtocol.makeToken()
        let intro = FleetDeviceIntroduction(deviceID: UUID(), name: "iPhone", kind: .iphone, tokenHash: FleetProtocol.hash(token))
        let code = try #require(try await a.local.fleetAction(.startDeviceCode).deviceCode).code
        _ = try await RemoteHostClient.fleetPairDevice(host: "127.0.0.1", port: a.port, code: code, device: intro)
        let phone = RemoteHostClient()
        defer { phone.disconnect() }
        _ = try await phone.connect(host: "127.0.0.1", port: a.port, token: token, clientName: "iPhone")

        #expect(!phone.capabilities.contains(RemoteProtocol.fleetSyncCapability), "a device is offered no sync")
        for attempt: () async throws -> Void in [
            { _ = try await phone.fleetSyncState(.hello(vector: FleetVersionVector())) },
            { _ = try await phone.fleetSyncState(.ops([])) },
            { _ = try await phone.fleetBlob(hash: String(repeating: "0", count: 64), size: 1) },
        ] {
            do { try await attempt(); Issue.record("a device synced") }
            catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.forbidden) }
        }
        #expect(a.text(.agents) == "kept on the Macs")
    }

    /// Fleet off is membership off: the engine stops (nothing watched, nothing served), a member that asks is told
    /// Fleet is off, and turning it on again picks up what changed meanwhile.
    @Test func syncRunsOnlyWhileFleetIsOn() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try await a.save(.agents, "before")
        try await b.waitForText(.agents, "before")

        b.server.setFleetEnabled(false)
        try await eventually("B's fleet to be off") { (try? await b.read().enabled) == false }
        let snapshot = try await b.read()
        #expect(snapshot.sync == nil && snapshot.peers.isEmpty)
        try await a.save(.agents, "while B is out")
        try await b.save(.agents, "B's own edit while out")
        try await Task.sleep(for: .milliseconds(300))
        #expect(b.text(.agents) == "B's own edit while out", "an off Mac applies nothing")
        #expect(a.text(.agents) == "while B is out", "and sends nothing")

        b.server.setFleetEnabled(true)
        try await eventually("both Macs to settle on one text") { a.text(.agents) == b.text(.agents) }
        #expect(["B's own edit while out", "while B is out"].contains(a.text(.agents)), "the later edit won, the other is in history")
    }

    @Test func withFleetOffNothingIsKeptAndNoSavesAreWatched() async throws {
        let a = try await Mac("MacBook Pro", enable: false)
        defer { a.stop() }
        try await a.save(.agents, "plain, as today")
        a.change(.defaultThinking(.low))
        #expect(a.text(.agents) == "plain, as today")
        #expect(!FileManager.default.fileExists(atPath: a.host.dir.appendingPathComponent("fleet/store").path), "no store until Fleet is on")
        let snapshot = try await a.read()
        #expect(!snapshot.enabled && snapshot.sync == nil)
    }

    @Test func theStoresFilesArePrivate() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try await a.save(.agents, "keys live in files like this one")
        try await b.waitForText(.agents, "keys live in files like this one")
        try await b.save(.appendSystem, "and this one")
        try await a.waitForText(.appendSystem, "and this one")
        let store = try #require(b.server.fleetStoreDirectory)
        let files = try FileManager.default.contentsOfDirectory(atPath: store.path).filter { $0.hasPrefix("ops-") }
        #expect(files.count == 2, "one op log per Mac that wrote")
        for file in files + ["observed.json"] {
            var info = stat()
            #expect(stat(store.appendingPathComponent(file).path, &info) == 0 && info.st_mode & 0o777 == 0o600, "\(file)")
        }
    }

    @Test func theSyncLineKnowsWhoIsInSyncAndWhoIsAsleep() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop() }
        try await eventually("A to say the mini is in sync") { try await a.syncStatus().peers.map(\.state) == [.inSync] }
        b.stop()
        try await eventually("A to say the mini is asleep") { try await a.syncStatus().peers.map(\.state) == [.offline] }
    }
}
