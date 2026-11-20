import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Runs `body` on the server queue and awaits it: the main actor never blocks on the queue (AGENTS.md, Server concurrency).
@MainActor
private func onQueue<T>(_ queue: DispatchQueue, _ body: @escaping () -> T) async -> T {
    nonisolated(unsafe) let work = body
    return await withCheckedContinuation { continuation in
        queue.async { continuation.resume(returning: work()) }
    }
}

/// C-MIGRATE for the Agents group (docs/plans/foundation-audit.md R3): the host keeps its copy of the
/// group in `host-preferences.json` and still writes the old UserDefaults keys, so the previous release,
/// reading only those keys, sees every change made through any path that setting has. Paths per setting
/// are the ones `settings-write-paths.json` records: (a) the Mac's own write, followed by the host,
/// (b) a client's `HostSettingChange`, (c) an incoming Fleet sync (no request, no reply).
@Suite("Host preferences migration: Agents", .mainActorExclusive)
@MainActor
struct HostPreferencesMigrationTests {
    typealias Agents = StoredHostPreferences.Agents

    /// What the previous release read for the group: its own parsing of the old keys, kept as it was.
    private static func previousRelease(_ d: UserDefaults) -> Agents {
        var a = Agents()
        a.defaultModel = d.string(forKey: "shepherd.agent.defaultModel") ?? ""
        a.defaultThinking = d.string(forKey: "shepherd.agent.defaultThinking").flatMap(ThinkingLevel.init(rawValue:)) ?? .medium
        a.defaultServiceTier = d.string(forKey: "shepherd.agent.defaultServiceTier").flatMap(ServiceTier.init(rawValue:)) ?? .standard
        a.textGenerationModel = d.string(forKey: "shepherd.agent.textGenerationModel") ?? ""
        a.visionModel = d.string(forKey: "shepherd.agent.visionModel") ?? ""
        a.queueDelivery = d.string(forKey: "shepherd.agent.queueDelivery").flatMap(NativeQueueMode.init(rawValue:)) ?? .all
        a.trimToolOutput = d.object(forKey: "shepherd.agent.trimToolOutput") as? Bool ?? true
        a.notifyOnTurnFinished = d.object(forKey: "shepherd.agent.notifyOnTurnFinished") as? Bool ?? true
        a.deferTools = d.object(forKey: "shepherd.agent.deferTools") as? Bool ?? true
        a.threadsStartThreads = d.object(forKey: "shepherd.agent.threadsStartThreads") as? Bool ?? false
        a.subThreadPlace = d.string(forKey: "shepherd.agent.subThreadPlace").flatMap(SpawnPlace.init(rawValue:)) ?? .checkout
        a.codemode = d.object(forKey: "shepherd.agent.codemode") as? Bool ?? true
        a.compactAtPercent = (d.object(forKey: "shepherd.agent.compactAtPercent") as? Int).flatMap { [60, 70, 80, 90].contains($0) ? $0 : nil }
        return a
    }

    /// Every setting of the group away from its default, as the previous release left its keys.
    private static func seed(_ d: UserDefaults) {
        d.set("acme/seed", forKey: "shepherd.agent.defaultModel")
        d.set("low", forKey: "shepherd.agent.defaultThinking")
        d.set("fast", forKey: "shepherd.agent.defaultServiceTier")
        d.set("acme/seed-text", forKey: "shepherd.agent.textGenerationModel")
        d.set("acme/seed-vision", forKey: "shepherd.agent.visionModel")
        d.set("oneAtATime", forKey: "shepherd.agent.queueDelivery")
        d.set(false, forKey: "shepherd.agent.trimToolOutput")
        d.set(false, forKey: "shepherd.agent.notifyOnTurnFinished")
        d.set(false, forKey: "shepherd.agent.deferTools")
        d.set(true, forKey: "shepherd.agent.threadsStartThreads")
        d.set("worktree", forKey: "shepherd.agent.subThreadPlace")
        d.set(false, forKey: "shepherd.agent.codemode")
        d.set(70, forKey: "shepherd.agent.compactAtPercent")
    }

    /// The file as the host wrote it, read afresh.
    private static func stored(_ file: URL) throws -> Agents {
        try StoredHostPreferences.decode(Data(contentsOf: file)).agents
    }

    /// One change and what it does to the group's copy.
    private struct Step {
        let label: String
        let expect: (inout Agents) -> Void
    }

    @Test func everyAgentsSettingReachesTheFileAndTheOldKeysThroughEachPathItHas() async throws {
        let harness = try AppHarness()
        defer { harness.stop() }
        Self.seed(harness.defaults)
        try await harness.start()
        let file = harness.server.supportDirectory.appendingPathComponent("host-preferences.json")

        // Upgrade with old keys: the host's copy starts as the keys hold it.
        var expected = Self.previousRelease(harness.defaults)
        #expect(expected.defaultModel == "acme/seed" && expected.compactAtPercent == 70)
        #expect(try Self.stored(file) == expected)

        func check(_ label: String) throws {
            let now = try Self.stored(file)
            #expect(now == expected, "\(label): the host's copy")
            #expect(Self.previousRelease(harness.defaults) == expected, "\(label): the old keys, as the previous release reads them")
        }

        // (a) The Mac's own write, followed by the host.
        let app = harness.settings
        let direct: [Step] = [
            Step(label: "defaultModel") { app.defaultModel = "acme/a"; $0.defaultModel = "acme/a" },
            Step(label: "defaultThinking") { app.defaultThinking = .high; $0.defaultThinking = .high },
            Step(label: "defaultServiceTier") { app.defaultServiceTier = .standard; $0.defaultServiceTier = .standard },
            Step(label: "textGenerationModel") { app.textGenerationModel = "acme/a-text"; $0.textGenerationModel = "acme/a-text" },
            Step(label: "visionModel") { app.visionModel = "acme/a-vision"; $0.visionModel = "acme/a-vision" },
            Step(label: "queueDelivery") { app.queueDelivery = .all; $0.queueDelivery = .all },
            Step(label: "trimToolOutput") { app.trimToolOutput = true; $0.trimToolOutput = true },
            Step(label: "notifyOnTurnFinished") { app.notifyOnTurnFinished = true; $0.notifyOnTurnFinished = true },
            Step(label: "deferTools") { app.deferTools = true; $0.deferTools = true },
            Step(label: "threadsStartThreads") { app.threadsStartThreads = false; $0.threadsStartThreads = false },
            Step(label: "subThreadPlace") { app.subThreadPlace = .checkout; $0.subThreadPlace = .checkout },
            Step(label: "codemode") { app.codemode = true; $0.codemode = true },
            Step(label: "compactAtPercent") { app.compactAtPercent = 60; $0.compactAtPercent = 60 },
            Step(label: "compactAtPercent.cleared") { app.compactAtPercent = nil; $0.compactAtPercent = nil },
        ]
        for step in direct {
            // `expect` also makes the write, once: the Mac's own settings are what it changes.
            let before = expected
            step.expect(&expected)
            #expect(expected != before, "\(step.label) changes something")
            try await eventuallyOnMain("the host's copy to take \(step.label)") { (try? Self.stored(file)) == expected }
            try check("direct \(step.label)")
        }

        // (b) A client's request over the host's socket, answered with the settings afterwards.
        let client = RemoteHostClient(localSocket: harness.hostSocket)
        _ = try await client.connect(host: "", port: 0, token: "", clientName: "migration")
        defer { client.disconnect() }
        let wire: [(HostSettingChange, Step)] = [
            (.defaultModel("acme/b"), Step(label: "defaultModel") { $0.defaultModel = "acme/b" }),
            (.defaultThinking(.medium), Step(label: "defaultThinking") { $0.defaultThinking = .medium }),
            (.defaultServiceTier(.fast), Step(label: "defaultServiceTier") { $0.defaultServiceTier = .fast }),
            (.textGenerationModel("acme/b-text"), Step(label: "textGenerationModel") { $0.textGenerationModel = "acme/b-text" }),
            (.namingModel("acme/b-naming"), Step(label: "namingModel") { $0.textGenerationModel = "acme/b-naming" }),
            (.visionModel("acme/b-vision"), Step(label: "visionModel") { $0.visionModel = "acme/b-vision" }),
            (.compactAtPercent(80), Step(label: "compactAtPercent") { $0.compactAtPercent = 80 }),
            (.queueDelivery(.oneAtATime), Step(label: "queueDelivery") { $0.queueDelivery = .oneAtATime }),
            (.bundledExtension(id: "context", on: false), Step(label: "trimToolOutput") { $0.trimToolOutput = false }),
            (.bundledExtension(id: "deferTools", on: false), Step(label: "deferTools") { $0.deferTools = false }),
            (.bundledExtension(id: "codemode", on: false), Step(label: "codemode") { $0.codemode = false }),
            (.threadsStartThreads(true), Step(label: "threadsStartThreads") { $0.threadsStartThreads = true }),
            (.subThreadPlace(.worktree), Step(label: "subThreadPlace") { $0.subThreadPlace = .worktree }),
        ]
        for (change, step) in wire {
            step.expect(&expected)
            _ = try await client.hostSettings(.change(change))
            try check("request \(step.label)")
        }

        // (c) A peer's Fleet op, delivered to the host's own fleet: no request, no reply. Seven of the group sync.
        let server = harness.server
        let engine = try #require(await onQueue(server.queue) { server.fleet?.syncEngine })
        await onQueue(server.queue) { engine.start() }
        let hostSettings = try #require(harness.hostSettings)
        func reported() async throws {
            try await eventuallyAsync("the host to report its settings to the fleet") {
                await onQueue(server.queue) { server.fleetSettings } == HostSettingsMapping.settings(from: hostSettings, shepherdVersion: nil, piVersion: nil)
            }
        }
        try await reported()
        let peer = try #require(UUID(uuidString: "00000000-0000-4000-8000-0000000000C3"))
        let base = UInt64(Date().timeIntervalSince1970 * 1000) + 3_600_000
        let synced: [(FleetHostSetting, String, Step)] = [
            (.defaultModel, "\"acme/c\"", Step(label: "defaultModel") { $0.defaultModel = "acme/c" }),
            (.defaultThinking, "\"low\"", Step(label: "defaultThinking") { $0.defaultThinking = .low }),
            (.defaultServiceTier, "\"standard\"", Step(label: "defaultServiceTier") { $0.defaultServiceTier = .standard }),
            (.textGenerationModel, "\"acme/c-text\"", Step(label: "textGenerationModel") { $0.textGenerationModel = "acme/c-text" }),
            (.visionModel, "\"acme/c-vision\"", Step(label: "visionModel") { $0.visionModel = "acme/c-vision" }),
            (.compactAtPercent, "90", Step(label: "compactAtPercent") { $0.compactAtPercent = 90 }),
            (.queueDelivery, "\"all\"", Step(label: "queueDelivery") { $0.queueDelivery = .all }),
        ]
        for (index, (setting, json, step)) in synced.enumerated() {
            step.expect(&expected)
            let seq = UInt64(index + 1)
            let op = FleetOp(mac: peer, seq: seq, hlc: FleetHLC(wallMs: base + seq), unit: setting.unit, change: .value(json), macName: "Peer")
            await onQueue(server.queue) { _ = engine.serve(.op(op), from: peer) }
            try await eventuallyOnMain("the host's copy to take the synced \(step.label)") { (try? Self.stored(file)) == expected }
            try check("fleet sync \(step.label)")
            try await reported()
        }
    }

    @Test func aHostWithNoOldKeysStoresTheDefaults() async throws {
        let defaults = ScratchDefaults()
        let file = try makeScratchDirectory("hpm").appendingPathComponent("host-preferences.json")
        AppSettings(store: defaults).adoptHostPreferences(HostSettingsStore(file: file))
        #expect(try Self.stored(file) == Agents())
        #expect(Self.previousRelease(defaults) == Agents(), "and the keys the previous release reads still mean the defaults")
    }

    /// Upgrade, change, downgrade (the old release edits its keys), upgrade: the old release's edit is in effect,
    /// and a change after that reaches both again.
    @Test func downgradingAndUpgradingAgainKeepsTheLatestValue() throws {
        let defaults = ScratchDefaults()
        let file = try makeScratchDirectory("hpm").appendingPathComponent("host-preferences.json")
        Self.seed(defaults)
        let first = AppSettings(store: defaults)
        first.adoptHostPreferences(HostSettingsStore(file: file))
        first.defaultModel = "acme/new"
        #expect(try Self.stored(file).defaultModel == "acme/new" && Self.previousRelease(defaults).defaultModel == "acme/new",
                "downgrading now leaves the new value in effect")

        // The previous release runs and edits its keys; the file, which it does not know, stays behind.
        defaults.set("acme/old-edit", forKey: "shepherd.agent.defaultModel")
        defaults.set(false, forKey: "shepherd.agent.codemode")
        defaults.removeObject(forKey: "shepherd.agent.compactAtPercent")
        #expect(try Self.stored(file).defaultModel == "acme/new")

        let second = AppSettings(store: defaults)
        second.adoptHostPreferences(HostSettingsStore(file: file))
        var expected = Self.previousRelease(defaults)
        #expect(expected.defaultModel == "acme/old-edit" && !expected.codemode && expected.compactAtPercent == nil)
        #expect(try Self.stored(file) == expected, "the old release's edits are what the host stores now")

        second.compactAtPercent = 90
        expected.compactAtPercent = 90
        #expect(try Self.stored(file) == expected && Self.previousRelease(defaults) == expected)
    }
}
