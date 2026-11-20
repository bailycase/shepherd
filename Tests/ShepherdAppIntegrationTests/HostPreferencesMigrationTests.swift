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

/// C-MIGRATE for the Worktrees group (Settings ▸ Git, the five `shepherd.worktree.*` keys), as for Agents. All five
/// have the three paths: (a) the Mac's own write followed by the host, (b) a client's `HostSettingChange`, which is
/// also answered with the reply that must carry the value, (c) an incoming Fleet sync (no request, no reply).
@Suite("Host preferences migration: Worktrees", .mainActorExclusive)
@MainActor
struct HostPreferencesWorktreesMigrationTests {
    typealias Worktrees = StoredHostPreferences.Worktrees

    /// What the previous release read for the group: its own parsing of the old keys, kept as it was.
    private static func previousRelease(_ d: UserDefaults) -> Worktrees {
        var w = Worktrees()
        w.baseMode = d.string(forKey: "shepherd.worktree.baseMode").flatMap(WorktreeBaseMode.init(rawValue:)) ?? .fresh
        w.fetchBeforeCreate = d.object(forKey: "shepherd.worktree.fetchBeforeCreate") as? Bool ?? true
        w.generatePRDescription = d.object(forKey: "shepherd.worktree.generatePRDescription") as? Bool ?? true
        w.closeOnMerge = d.bool(forKey: "shepherd.worktree.closeOnMerge")
        w.deleteAction = d.string(forKey: "shepherd.worktree.deleteAction").flatMap(HostSettings.WorktreeDeleteAction.init(rawValue:)) ?? .ask
        return w
    }

    /// Every setting of the group away from its default, as the previous release left its keys.
    private static func seed(_ d: UserDefaults) {
        d.set("head", forKey: "shepherd.worktree.baseMode")
        d.set(false, forKey: "shepherd.worktree.fetchBeforeCreate")
        d.set(false, forKey: "shepherd.worktree.generatePRDescription")
        d.set(true, forKey: "shepherd.worktree.closeOnMerge")
        d.set("keepWorktree", forKey: "shepherd.worktree.deleteAction")
    }

    private static func stored(_ file: URL) throws -> Worktrees {
        try StoredHostPreferences.decode(Data(contentsOf: file)).worktrees
    }

    /// The reply's field for each setting, in the order of `Worktrees`.
    private static func reply(_ s: HostSettings) -> [String] {
        [s.worktreeBase.rawValue, "\(s.fetchBeforeCreating)", "\(s.generatePRDescriptions)", "\(s.closeOnMerge)", s.worktreeDeleteAction.rawValue]
    }

    private static func fields(_ w: Worktrees) -> [String] {
        [w.baseMode.rawValue, "\(w.fetchBeforeCreate)", "\(w.generatePRDescription)", "\(w.closeOnMerge)", w.deleteAction.rawValue]
    }

    private struct Step {
        let label: String
        let expect: (inout Worktrees) -> Void
    }

    @Test func everyWorktreesSettingReachesTheFileAndTheOldKeysThroughEachPathItHas() async throws {
        let harness = try AppHarness()
        defer { harness.stop() }
        Self.seed(harness.defaults)
        try await harness.start()
        let file = harness.server.supportDirectory.appendingPathComponent("host-preferences.json")

        // Upgrade with old keys: the host's copy starts as the keys hold it.
        var expected = Self.previousRelease(harness.defaults)
        #expect(expected.baseMode == .head && expected.closeOnMerge && expected.deleteAction == .keepWorktree)
        #expect(try Self.stored(file) == expected)

        func check(_ label: String) throws {
            #expect(try Self.stored(file) == expected, "\(label): the host's copy")
            #expect(Self.previousRelease(harness.defaults) == expected, "\(label): the old keys, as the previous release reads them")
        }

        // (a) The Mac's own write, followed by the host.
        let app = harness.settings
        let direct: [Step] = [
            Step(label: "baseMode") { app.worktreeBaseMode = .fresh; $0.baseMode = .fresh },
            Step(label: "fetchBeforeCreate") { app.worktreeFetchBeforeCreate = true; $0.fetchBeforeCreate = true },
            Step(label: "generatePRDescription") { app.worktreeGeneratePRDescription = true; $0.generatePRDescription = true },
            Step(label: "closeOnMerge") { app.worktreeCloseOnMerge = false; $0.closeOnMerge = false },
            Step(label: "deleteAction") { app.worktreeDeleteAction = .removeWorktree; $0.deleteAction = .removeWorktree },
        ]
        for step in direct {
            let before = expected
            step.expect(&expected) // also makes the write, once
            #expect(expected != before, "\(step.label) changes something")
            try await eventuallyOnMain("the host's copy to take \(step.label)") { (try? Self.stored(file)) == expected }
            try check("direct \(step.label)")
        }

        // (b) A client's request over the host's socket, answered with the settings afterwards.
        let client = RemoteHostClient(localSocket: harness.hostSocket)
        _ = try await client.connect(host: "", port: 0, token: "", clientName: "migration")
        defer { client.disconnect() }
        let wire: [(HostSettingChange, Step)] = [
            (.worktreeBase(.head), Step(label: "baseMode") { $0.baseMode = .head }),
            (.fetchBeforeCreating(false), Step(label: "fetchBeforeCreate") { $0.fetchBeforeCreate = false }),
            (.generatePRDescriptions(false), Step(label: "generatePRDescription") { $0.generatePRDescription = false }),
            (.closeOnMerge(true), Step(label: "closeOnMerge") { $0.closeOnMerge = true }),
            (.worktreeDeleteAction(.keepWorktree), Step(label: "deleteAction") { $0.deleteAction = .keepWorktree }),
        ]
        for (change, step) in wire {
            step.expect(&expected)
            let reply = try await client.hostSettings(.change(change))
            #expect(Self.reply(reply) == Self.fields(expected), "request \(step.label): the reply")
            try check("request \(step.label)")
        }

        // (c) A peer's Fleet op, delivered to the host's own fleet: no request, no reply.
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
            (.worktreeBase, "\"fresh\"", Step(label: "baseMode") { $0.baseMode = .fresh }),
            (.fetchBeforeCreating, "true", Step(label: "fetchBeforeCreate") { $0.fetchBeforeCreate = true }),
            (.generatePRDescriptions, "true", Step(label: "generatePRDescription") { $0.generatePRDescription = true }),
            (.closeOnMerge, "false", Step(label: "closeOnMerge") { $0.closeOnMerge = false }),
            (.worktreeDeleteAction, "\"ask\"", Step(label: "deleteAction") { $0.deleteAction = .ask }),
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

    @Test func aHostWithNoOldKeysStoresTheDefaults() throws {
        let defaults = ScratchDefaults()
        let file = try makeScratchDirectory("hpm").appendingPathComponent("host-preferences.json")
        AppSettings(store: defaults).adoptHostPreferences(HostSettingsStore(file: file))
        #expect(try Self.stored(file) == Worktrees())
        #expect(Self.previousRelease(defaults) == Worktrees(), "and the keys the previous release reads still mean the defaults")
    }

    /// Upgrade, change, downgrade (the old release edits its keys), upgrade: the old release's edit is in effect,
    /// and a change after that reaches both again.
    @Test func downgradingAndUpgradingAgainKeepsTheLatestValue() throws {
        let defaults = ScratchDefaults()
        let file = try makeScratchDirectory("hpm").appendingPathComponent("host-preferences.json")
        Self.seed(defaults)
        let first = AppSettings(store: defaults)
        first.adoptHostPreferences(HostSettingsStore(file: file))
        first.worktreeBaseMode = .fresh
        #expect(try Self.stored(file).baseMode == .fresh && Self.previousRelease(defaults).baseMode == .fresh,
                "downgrading now leaves the new value in effect")

        // The previous release runs and edits its keys; the file, which it does not know, stays behind.
        defaults.set("head", forKey: "shepherd.worktree.baseMode")
        defaults.set(true, forKey: "shepherd.worktree.fetchBeforeCreate")
        defaults.removeObject(forKey: "shepherd.worktree.closeOnMerge")
        defaults.set("removeWorktree", forKey: "shepherd.worktree.deleteAction")
        #expect(try Self.stored(file).baseMode == .fresh)

        let second = AppSettings(store: defaults)
        second.adoptHostPreferences(HostSettingsStore(file: file))
        var expected = Self.previousRelease(defaults)
        #expect(expected.baseMode == .head && expected.fetchBeforeCreate && !expected.closeOnMerge && expected.deleteAction == .removeWorktree)
        #expect(try Self.stored(file) == expected, "the old release's edits are what the host stores now")

        second.worktreeGeneratePRDescription = true
        expected.generatePRDescription = true
        #expect(try Self.stored(file) == expected && Self.previousRelease(defaults) == expected)
    }
}

/// C-MIGRATE for the Experiments group (Settings ▸ Experiments, the four `shepherd.experiments.*` keys), as for Agents. All
/// four have two paths: (a) the Mac's own write followed by the host, (b) a client's `HostSettingChange`, which is also
/// answered with the reply that must carry the value. None is synced by Fleet, so there is no path (c).
@Suite("Host preferences migration: Experiments", .mainActorExclusive)
@MainActor
struct HostPreferencesExperimentsMigrationTests {
    typealias Experiments = StoredHostPreferences.Experiments

    /// What the previous release read for the group: its own parsing of the old keys, kept as it was.
    private static func previousRelease(_ d: UserDefaults) -> Experiments {
        var e = Experiments()
        e.goals = d.object(forKey: "shepherd.experiments.goals") as? Bool ?? false
        e.projects = d.object(forKey: "shepherd.experiments.projects") as? Bool ?? false
        e.designTool = d.bool(forKey: "shepherd.experiments.designTool")
        e.computerUse = d.bool(forKey: "shepherd.experiments.computerUse")
        return e
    }

    /// Every setting of the group away from its default, as the previous release left its keys.
    private static func seed(_ d: UserDefaults) {
        for key in ["goals", "projects", "designTool", "computerUse"] { d.set(true, forKey: "shepherd.experiments.\(key)") }
    }

    private static func stored(_ file: URL) throws -> Experiments {
        try StoredHostPreferences.decode(Data(contentsOf: file)).experiments
    }

    /// The reply's field for each setting, in the order of `Experiments`.
    private static func reply(_ s: HostSettings) -> [Bool] { [s.goalsEnabled, s.projectsEnabled, s.designToolEnabled, s.computerUseEnabled] }

    private static func fields(_ e: Experiments) -> [Bool] { [e.goals, e.projects, e.designTool, e.computerUse] }

    private struct Step {
        let label: String
        let expect: (inout Experiments) -> Void
    }

    @Test func everyExperimentsSettingReachesTheFileAndTheOldKeysThroughEachPathItHas() async throws {
        let harness = try AppHarness()
        defer { harness.stop() }
        Self.seed(harness.defaults)
        try await harness.start()
        let file = harness.server.supportDirectory.appendingPathComponent("host-preferences.json")

        // Upgrade with old keys: the host's copy starts as the keys hold it.
        var expected = Self.previousRelease(harness.defaults)
        #expect(Self.fields(expected) == [true, true, true, true])
        #expect(try Self.stored(file) == expected)

        func check(_ label: String) throws {
            #expect(try Self.stored(file) == expected, "\(label): the host's copy")
            #expect(Self.previousRelease(harness.defaults) == expected, "\(label): the old keys, as the previous release reads them")
        }

        // (a) The Mac's own write, followed by the host.
        let app = harness.settings
        let direct: [Step] = [
            Step(label: "goals") { app.goalsEnabled = false; $0.goals = false },
            Step(label: "projects") { app.projectsEnabled = false; $0.projects = false },
            Step(label: "designTool") { app.designToolEnabled = false; $0.designTool = false },
            Step(label: "computerUse") { app.computerUseEnabled = false; $0.computerUse = false },
        ]
        for step in direct {
            let before = expected
            step.expect(&expected) // also makes the write, once
            #expect(expected != before, "\(step.label) changes something")
            try await eventuallyOnMain("the host's copy to take \(step.label)") { (try? Self.stored(file)) == expected }
            try check("direct \(step.label)")
        }

        // (b) A client's request over the host's socket, answered with the settings afterwards.
        let client = RemoteHostClient(localSocket: harness.hostSocket)
        _ = try await client.connect(host: "", port: 0, token: "", clientName: "migration")
        defer { client.disconnect() }
        let wire: [(HostSettingChange, Step)] = [
            (.goalsEnabled(true), Step(label: "goals") { $0.goals = true }),
            (.projectsEnabled(true), Step(label: "projects") { $0.projects = true }),
            (.designToolEnabled(true), Step(label: "designTool") { $0.designTool = true }),
            (.computerUseEnabled(true), Step(label: "computerUse") { $0.computerUse = true }),
            (.goalsEnabled(false), Step(label: "goals off") { $0.goals = false }),
        ]
        for (change, step) in wire {
            step.expect(&expected)
            let reply = try await client.hostSettings(.change(change))
            #expect(Self.reply(reply) == Self.fields(expected), "request \(step.label): the reply")
            try check("request \(step.label)")
        }
    }

    @Test func aHostWithNoOldKeysStoresTheDefaults() throws {
        let defaults = ScratchDefaults()
        let file = try makeScratchDirectory("hpm").appendingPathComponent("host-preferences.json")
        AppSettings(store: defaults).adoptHostPreferences(HostSettingsStore(file: file))
        #expect(try Self.stored(file) == Experiments())
        #expect(Self.previousRelease(defaults) == Experiments(), "and the keys the previous release reads still mean the defaults")
    }

    /// Upgrade, change, downgrade (the old release edits its keys), upgrade: the old release's edit is in effect,
    /// and a change after that reaches both again.
    @Test func downgradingAndUpgradingAgainKeepsTheLatestValue() throws {
        let defaults = ScratchDefaults()
        let file = try makeScratchDirectory("hpm").appendingPathComponent("host-preferences.json")
        Self.seed(defaults)
        let first = AppSettings(store: defaults)
        first.adoptHostPreferences(HostSettingsStore(file: file))
        first.goalsEnabled = false
        #expect(try Self.stored(file).goals == false && Self.previousRelease(defaults).goals == false,
                "downgrading now leaves the new value in effect")

        // The previous release runs and edits its keys; the file, which it does not know, stays behind.
        defaults.set(true, forKey: "shepherd.experiments.goals")
        defaults.set(false, forKey: "shepherd.experiments.projects")
        defaults.removeObject(forKey: "shepherd.experiments.designTool")
        #expect(try Self.stored(file).goals == false)

        let second = AppSettings(store: defaults)
        second.adoptHostPreferences(HostSettingsStore(file: file))
        var expected = Self.previousRelease(defaults)
        #expect(Self.fields(expected) == [true, false, false, true])
        #expect(try Self.stored(file) == expected, "the old release's edits are what the host stores now")

        second.computerUseEnabled = false
        expected.computerUse = false
        #expect(try Self.stored(file) == expected && Self.previousRelease(defaults) == expected)
    }
}

/// C-MIGRATE for the Fleet group (Settings ▸ Fleet, the eight `shepherd.fleet.*` keys), as for Agents. All eight have the
/// three paths: (a) the Mac's own write followed by the host (`AppSettings.followed`, which this slice leaves as it is),
/// (b) a client's `HostSettingChange`, also answered with the reply that must carry the value, (c) an incoming Fleet
/// sync (no request, no reply).
@Suite("Host preferences migration: Fleet", .mainActorExclusive)
@MainActor
struct HostPreferencesFleetMigrationTests {
    typealias Fleet = StoredHostPreferences.Fleet

    private static let macA = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    private static let macB = UUID(uuidString: "00000000-0000-4000-8000-0000000000B2")!
    private static let space = "acme-web"

    /// What the previous release read for the group: its own parsing of the old keys, kept as it was.
    private static func previousRelease(_ d: UserDefaults) -> Fleet {
        var f = Fleet()
        f.weights = (d.dictionary(forKey: "shepherd.fleet.weights") as? [String: String] ?? [:]).compactMapValues(FleetSendWeight.init(rawValue:))
        f.threadsCanSend = d.object(forKey: "shepherd.fleet.threadsCanSend") as? Bool ?? false
        f.threadCap = HostSettings.clampedThreadCap(d.object(forKey: "shepherd.fleet.threadCap") as? Int ?? HostSettings.fleetThreadCapDefault)
        f.uncommitted = d.string(forKey: "shepherd.fleet.uncommitted").flatMap(FleetUncommittedChanges.init(rawValue:)) ?? .sendThem
        f.snapshotExcludes = d.data(forKey: "shepherd.fleet.snapshotExcludes").flatMap { try? JSONDecoder().decode([String: FleetSnapshotExcludes].self, from: $0) } ?? [:]
        f.checkIgnores = d.dictionary(forKey: "shepherd.fleet.checkIgnores") as? [String: [String]] ?? [:]
        f.autoDispatch = d.object(forKey: "shepherd.fleet.autoDispatch") as? Bool
        f.batteryCountsHalf = d.object(forKey: "shepherd.fleet.batteryCountsHalf") as? Bool ?? true
        return f
    }

    /// Every setting of the group away from its default, as the previous release left its keys.
    private static func seed(_ d: UserDefaults) {
        d.set([FleetSendWeight.settingKey(hostID: macA): "prefer"], forKey: "shepherd.fleet.weights")
        d.set(true, forKey: "shepherd.fleet.threadsCanSend")
        d.set(5, forKey: "shepherd.fleet.threadCap")
        d.set("leaveBehind", forKey: "shepherd.fleet.uncommitted")
        d.set(try? JSONEncoder().encode([FleetSnapshotExcludes.settingKey(spaceID: space): FleetSnapshotExcludes(excluded: ["dist"])]), forKey: "shepherd.fleet.snapshotExcludes")
        d.set([FleetCheckIgnoreSetting.settingKey(hostID: macB): ["check-a"]], forKey: "shepherd.fleet.checkIgnores")
        d.set(false, forKey: "shepherd.fleet.autoDispatch")
        d.set(false, forKey: "shepherd.fleet.batteryCountsHalf")
    }

    private static func stored(_ file: URL) throws -> Fleet {
        try StoredHostPreferences.decode(Data(contentsOf: file)).fleet
    }

    /// The reply's fields for the group, so a reply is compared to the store's copy field for field.
    private static func reply(_ s: HostSettings) -> Fleet {
        var f = Fleet()
        f.weights = s.fleetWeights
        f.threadsCanSend = s.fleetThreadsCanSend
        f.threadCap = s.fleetThreadCap
        f.uncommitted = s.fleetUncommitted
        f.snapshotExcludes = s.fleetSnapshotExcludes
        f.checkIgnores = s.fleetCheckIgnores
        f.autoDispatch = s.fleetAutoDispatch
        f.batteryCountsHalf = s.fleetBatteryCountsHalf
        return f
    }

    private struct Step {
        let label: String
        let expect: (inout Fleet) -> Void
    }

    @Test func everyFleetSettingReachesTheFileAndTheOldKeysThroughEachPathItHas() async throws {
        let harness = try AppHarness()
        defer { harness.stop() }
        Self.seed(harness.defaults)
        try await harness.start()
        let file = harness.server.supportDirectory.appendingPathComponent("host-preferences.json")
        let weightKey = FleetSendWeight.settingKey(hostID: Self.macA)
        let excludesKey = FleetSnapshotExcludes.settingKey(spaceID: Self.space)
        let ignoresKey = FleetCheckIgnoreSetting.settingKey(hostID: Self.macA)

        // Upgrade with old keys: the host's copy starts as the keys hold it.
        var expected = Self.previousRelease(harness.defaults)
        #expect(expected.weights == [weightKey: .prefer] && expected.threadsCanSend && expected.threadCap == 5 && expected.uncommitted == .leaveBehind)
        #expect(expected.autoDispatch == false && !expected.batteryCountsHalf && expected.snapshotExcludes.count == 1 && expected.checkIgnores.count == 1)
        #expect(try Self.stored(file) == expected)

        func check(_ label: String) throws {
            #expect(try Self.stored(file) == expected, "\(label): the host's copy")
            #expect(Self.previousRelease(harness.defaults) == expected, "\(label): the old keys, as the previous release reads them")
        }

        // (a) The Mac's own write, followed by the host.
        let app = harness.settings
        let direct: [Step] = [
            Step(label: "weights") { app.setFleetWeight(.lessOften, of: Self.macA); $0.weights[weightKey] = .lessOften },
            Step(label: "threadsCanSend") { app.fleetThreadsCanSend = false; $0.threadsCanSend = false },
            Step(label: "threadCap") { app.fleetThreadCap = 4; $0.threadCap = 4 },
            Step(label: "uncommitted") { app.fleetUncommitted = .sendThem; $0.uncommitted = .sendThem },
            Step(label: "snapshotExcludes") {
                app.setFleetExcludes(FleetSnapshotExcludes(excluded: ["build"]), of: SpaceID(rawValue: Self.space))
                $0.snapshotExcludes[excludesKey] = FleetSnapshotExcludes(excluded: ["build"])
            },
            Step(label: "checkIgnores") { app.setFleetCheckIgnored(["check-b"], on: Self.macA); $0.checkIgnores[ignoresKey] = ["check-b"] },
            Step(label: "autoDispatch") { app.fleetAutoDispatch = true; $0.autoDispatch = true },
            Step(label: "autoDispatch.cleared") { app.fleetAutoDispatch = nil; $0.autoDispatch = nil },
            Step(label: "batteryCountsHalf") { app.fleetBatteryCountsHalf = true; $0.batteryCountsHalf = true },
        ]
        for step in direct {
            let before = expected
            step.expect(&expected) // also makes the write, once
            #expect(expected != before, "\(step.label) changes something")
            try await eventuallyOnMain("the host's copy to take \(step.label)") { (try? Self.stored(file)) == expected }
            try check("direct \(step.label)")
        }

        // (b) A client's request over the host's socket, answered with the settings afterwards.
        let client = RemoteHostClient(localSocket: harness.hostSocket)
        _ = try await client.connect(host: "", port: 0, token: "", clientName: "migration")
        defer { client.disconnect() }
        let wire: [(HostSettingChange, Step)] = [
            (.fleetWeight(hostID: Self.macA, weight: .manualOnly), Step(label: "weights") { $0.weights[weightKey] = .manualOnly }),
            (.fleetThreadsCanSend(true), Step(label: "threadsCanSend") { $0.threadsCanSend = true }),
            (.fleetThreadCap(6), Step(label: "threadCap") { $0.threadCap = 6 }),
            (.fleetThreadCap(1000), Step(label: "threadCap.aboveRange") { $0.threadCap = HostSettings.clampedThreadCap(1000) }),
            (.fleetUncommitted(.leaveBehind), Step(label: "uncommitted") { $0.uncommitted = .leaveBehind }),
            (.fleetSnapshotExcludes(spaceID: Self.space, excludes: FleetSnapshotExcludes(excluded: ["out"], included: ["lib"])),
             Step(label: "snapshotExcludes") { $0.snapshotExcludes[excludesKey] = FleetSnapshotExcludes(excluded: ["out"], included: ["lib"]) }),
            (.fleetCheckIgnore(hostID: Self.macA, ids: ["y", "x"]), Step(label: "checkIgnores") { $0.checkIgnores[ignoresKey] = ["x", "y"] }),
            (.fleetAutoDispatch(false), Step(label: "autoDispatch") { $0.autoDispatch = false }),
            (.fleetBatteryCountsHalf(false), Step(label: "batteryCountsHalf") { $0.batteryCountsHalf = false }),
        ]
        for (change, step) in wire {
            let before = expected
            step.expect(&expected)
            #expect(expected != before, "request \(step.label) changes something")
            let reply = try await client.hostSettings(.change(change))
            #expect(Self.reply(reply) == expected, "request \(step.label): the reply")
            try check("request \(step.label)")
        }

        // (c) A peer's Fleet op, delivered to the host's own fleet: no request, no reply. All eight sync.
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
        let synced: [(unit: String, json: String, step: Step)] = [
            (FleetWeightSetting.unit(hostID: Self.macA), "\"prefer\"", Step(label: "weights") { $0.weights[weightKey] = .prefer }),
            (FleetHostSetting.fleetThreadsCanSend.unit, "false", Step(label: "threadsCanSend") { $0.threadsCanSend = false }),
            (FleetHostSetting.fleetThreadCap.unit, "7", Step(label: "threadCap") { $0.threadCap = 7 }),
            (FleetHostSetting.fleetUncommitted.unit, "\"sendThem\"", Step(label: "uncommitted") { $0.uncommitted = .sendThem }),
            (FleetSnapshotExcludeSetting.unit(spaceID: Self.space), "{\"excluded\":[\"dist\"],\"included\":[]}",
             Step(label: "snapshotExcludes") { $0.snapshotExcludes[excludesKey] = FleetSnapshotExcludes(excluded: ["dist"]) }),
            (FleetCheckIgnoreSetting.unit(hostID: Self.macA), "[\"check-c\"]", Step(label: "checkIgnores") { $0.checkIgnores[ignoresKey] = ["check-c"] }),
            (FleetHostSetting.fleetAutoDispatch.unit, "true", Step(label: "autoDispatch") { $0.autoDispatch = true }),
            (FleetHostSetting.fleetBatteryCountsHalf.unit, "true", Step(label: "batteryCountsHalf") { $0.batteryCountsHalf = true }),
        ]
        for (index, (unit, json, step)) in synced.enumerated() {
            let before = expected
            step.expect(&expected)
            #expect(expected != before, "fleet sync \(step.label) changes something")
            let seq = UInt64(index + 1)
            let op = FleetOp(mac: peer, seq: seq, hlc: FleetHLC(wallMs: base + seq), unit: unit, change: .value(json), macName: "Peer")
            await onQueue(server.queue) { _ = engine.serve(.op(op), from: peer) }
            try await eventuallyOnMain("the host's copy to take the synced \(step.label)") { (try? Self.stored(file)) == expected }
            try check("fleet sync \(step.label)")
            try await reported()
        }
    }

    @Test func aHostWithNoOldKeysStoresTheDefaults() throws {
        let defaults = ScratchDefaults()
        let file = try makeScratchDirectory("hpm").appendingPathComponent("host-preferences.json")
        AppSettings(store: defaults).adoptHostPreferences(HostSettingsStore(file: file))
        #expect(try Self.stored(file) == Fleet())
        #expect(Self.previousRelease(defaults) == Fleet(), "and the keys the previous release reads still mean the defaults")
    }

    /// Upgrade, change, downgrade (the old release edits its keys), upgrade: the old release's edit is in effect,
    /// and a change after that reaches both again.
    @Test func downgradingAndUpgradingAgainKeepsTheLatestValue() throws {
        let defaults = ScratchDefaults()
        let file = try makeScratchDirectory("hpm").appendingPathComponent("host-preferences.json")
        Self.seed(defaults)
        let first = AppSettings(store: defaults)
        first.adoptHostPreferences(HostSettingsStore(file: file))
        first.fleetThreadCap = 8
        #expect(try Self.stored(file).threadCap == 8 && Self.previousRelease(defaults).threadCap == 8,
                "downgrading now leaves the new value in effect")

        // The previous release runs and edits its keys; the file, which it does not know, stays behind.
        defaults.set(2, forKey: "shepherd.fleet.threadCap")
        defaults.set(false, forKey: "shepherd.fleet.threadsCanSend")
        defaults.removeObject(forKey: "shepherd.fleet.autoDispatch")
        defaults.set([FleetSendWeight.settingKey(hostID: Self.macB): "manualOnly"], forKey: "shepherd.fleet.weights")
        #expect(try Self.stored(file).threadCap == 8)

        let second = AppSettings(store: defaults)
        second.adoptHostPreferences(HostSettingsStore(file: file))
        var expected = Self.previousRelease(defaults)
        #expect(expected.threadCap == 2 && !expected.threadsCanSend && expected.autoDispatch == nil
                && expected.weights == [FleetSendWeight.settingKey(hostID: Self.macB): .manualOnly])
        #expect(try Self.stored(file) == expected, "the old release's edits are what the host stores now")

        second.fleetBatteryCountsHalf = true
        expected.batteryCountsHalf = true
        #expect(try Self.stored(file) == expected && Self.previousRelease(defaults) == expected)
    }
}
