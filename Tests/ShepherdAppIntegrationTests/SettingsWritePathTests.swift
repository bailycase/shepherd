import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Every persisting setting and every way a write reaches it today, pinned as a golden
/// (`Tests/Fixtures/settings-write-paths.json`): (a) the Mac's own write, followed by the other process
/// through the store, (b) a client's `hostSettings` change over the host socket, (c) a Fleet sync of a
/// host setting, and what none of them reach. Characterization only: the golden records today's
/// outcome, known oddities included. `SHEPHERD_GOLDEN_CAPTURE=<file>` writes the observations there
/// instead of comparing.
@Suite("Settings write paths", .mainActorExclusive)
@MainActor
struct SettingsWritePathTests {
    @Test func everySettingsWritePathMatchesTheGolden() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.checkingWritePaths() }
        }
        expectScenarioCompleted(result)
    }

    private static let seed = [
        "hostID": "00000000-0000-4000-8000-0000000000A1", "otherHostID": "00000000-0000-4000-8000-0000000000B2",
        "spaceID": "acme-web-space", "otherSpaceID": "acme-docs-space",
    ]

    private static func checkingWritePaths() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/settings-write-paths.json")
        let capture = ProcessInfo.processInfo.environment["SHEPHERD_GOLDEN_CAPTURE"]
        let golden = capture == nil ? try jsonObject(Data(contentsOf: fixture)) : [:]
        if capture == nil { try #require(golden["seed"] as? [String: String] == seed, "the golden was captured with other seed inputs") }
        let run = GoldenRun(expected: golden["observations"] as? [[String: Any]], directory: ValidationEvidence.directory)

        try await observeWritePaths { step, fields in try run.observe(step, fields) }

        if let capture {
            let data = try JSONSerialization.data(withJSONObject: ["seed": seed, "observations": run.captured],
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: URL(fileURLWithPath: capture))
            return
        }
        try #require(run.index == run.expected?.count, "not all golden observations were checked")
        let completed = "every settings write path matched the golden"
        for step in ["compare-golden", "complete"] {
            try ValidationEvidence.record(in: run.directory, step: step, status: "passed", expected: completed, actual: completed)
        }
    }

    // MARK: Golden comparison (the seeded rename case's way, field by field)

    private final class GoldenRun {
        let expected: [[String: Any]]?
        let directory: URL?
        var index = 0
        var captured: [[String: Any]] = []

        init(expected: [[String: Any]]?, directory: URL?) { (self.expected, self.directory) = (expected, directory) }

        func observe(_ step: String, _ fields: [String: String]) throws {
            guard let expected else { captured.append(["step": step, "fields": fields]); return }
            let previous = try #require(expected.indices.contains(index) ? expected[index] : nil, "unexpected observation: \(step)")
            let expectedStep = try #require(previous["step"] as? String)
            try #require(expectedStep == step, "observation \(index) out of order: expected \(expectedStep), got \(step)")
            let recorded = try #require(previous["fields"] as? [String: String])
            index += 1
            var before: [String] = [], after: [String] = []
            for field in Set(recorded.keys).union(fields.keys).sorted() {
                let old = recorded[field] ?? "<missing>", new = fields[field] ?? "<missing>"
                if old != new {
                    before.append("\(step).\(field) = \(old)")
                    after.append("\(step).\(field) = \(new)")
                }
            }
            if !before.isEmpty {
                let expected = before.joined(separator: "\n"), actual = after.joined(separator: "\n")
                try? ValidationEvidence.record(in: directory, step: "compare-golden", status: "failed", expected: expected, actual: actual)
                try #require(before.isEmpty, "Expected: \(expected)\nActual:   \(actual)")
            }
        }
    }

    // MARK: The observations

    private static func observeWritePaths(_ observe: (String, [String: String]) throws -> Void) async throws {
        let hostID = try #require(UUID(uuidString: seed["hostID"]!)), otherHostID = try #require(UUID(uuidString: seed["otherHostID"]!))
        let spaceID = seed["spaceID"]!, otherSpaceID = seed["otherSpaceID"]!

        // (a) The Mac's own write, and whether the other process on the same preferences takes it.
        let probes = Dictionary(uniqueKeysWithValues: Self.probes(hostID: hostID, spaceID: spaceID).map { ($0.key, $0) })
        let keys = AppSettings.Key.all
        try #require(Set(probes.keys) == Set(keys), "settings without a write-path probe: \(Set(keys).subtracting(probes.keys).sorted())")
        var followed: [String: Bool] = [:]
        for key in keys {
            let probe = probes[key]!
            let store = ScratchDefaults()
            let app = AppSettings(store: store), other = AppSettings(store: store)
            let before = snapshot(store), otherBefore = probe.read(other)
            let written = probe.write(app)
            let after = snapshot(store)
            other.reload()
            let taken = probe.read(other) != otherBefore
            followed[key] = taken
            try observe("direct.\(key)", [
                "write": written, "stored": after[key] ?? "<missing>",
                "storedKeysChanged": changedKeys(before, after).joined(separator: ","),
                "otherProcess.before": otherBefore, "otherProcess.afterReload": probe.read(other), "followed": taken ? "yes" : "no",
            ])
        }

        // The same through the Darwin notice a real write posts, for the two kinds of follower.
        do {
            let store = ScratchDefaults(), notice = "shepherd-test-settings-\(UUID().uuidString)"
            let app = AppSettings(store: store), other = AppSettings(store: store)
            app.followOtherProcesses(notice: notice)
            other.followOtherProcesses(notice: notice)
            var listener: [Bool] = []
            other.onRemoteListenerChange = { listener.append($0) }
            app.sidebarWidth = 300
            try await eventuallyOnMain("the other process to take the width") { other.sidebarWidth == 300 }
            app.remoteListenerEnabled = true
            try await eventuallyOnMain("the other process to take Serve this Mac") { other.remoteListenerEnabled }
            try observe("notice", ["sidebarWidth": "\(other.sidebarWidth)", "remoteListenerEnabled": "\(other.remoteListenerEnabled)",
                                   "remoteListenerCallbacks": "\(listener)"])
        }

        // (b) and (c) run against the host the app serves, over its socket.
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        try await app.start()
        let hostSettings = try #require(app.hostSettings)
        let session = Session(wire: try Wire(path: app.hostSocket))

        let hello = try await session.send { .hello(id: $0, token: "", clientName: "validation", protocolVersion: RemoteProtocol.version) }
        try observe("wire.hello", correlation(hello))
        var settings = flatten(try await session.fetch()["settings"] as? [String: Any] ?? [:])
        var stored = snapshot(app.defaults)

        /// The reply's HostSettings fields that moved, and the stored keys that moved, since the last look.
        func movement(_ reply: [String: Any]) throws -> (fields: [String: String], keys: [String]) {
            var fields: [String: String] = [:]
            // A refusal carries no settings: nothing of them moved.
            if let carried = reply["settings"] as? [String: Any] {
                let now = flatten(carried)
                for field in Set(settings.keys).union(now.keys).sorted() where settings[field] != now[field] {
                    fields["reply.settings.\(field)"] = now[field] ?? "<missing>"
                }
                settings = now
            }
            let after = snapshot(app.defaults)
            let keys = changedKeys(stored, after)
            for key in keys { fields["stored.\(key)"] = after[key] ?? "<missing>" }
            stored = after
            return (fields, keys)
        }

        var wireKeys: [String: [String]] = [:], wireFields: [String: Set<String>] = [:]
        for (label, change) in changes(hostID: hostID, spaceID: spaceID) {
            let exchange = try await session.send { .hostSettings(id: $0, request: .change(change)) }
            let moved = try movement(exchange.reply)
            var fields = correlation(exchange)
            fields["capability"] = change.capability ?? "none"
            fields.merge(moved.fields) { $1 }
            try observe("wire.\(label)", fields)
            for key in moved.keys {
                wireKeys[key, default: []].append(label)
                wireFields[key, default: []].formUnion(moved.fields.keys.filter { $0.hasPrefix("reply.settings.") }.map { String($0.dropFirst("reply.settings.".count)) })
            }
        }

        // (c) A Fleet sync applies the same change in the host with no request and no capability check.
        let (applied, signal) = AsyncStream<Void>.makeStream()
        let source = FleetHostSettingsSource(apply: { change in
            Task { @MainActor in
                HostSettingsMapping.apply(change, to: hostSettings)
                signal.yield()
            }
        })
        var fleetKeys: [String: [String]] = [:]
        var synced = applied.makeAsyncIterator()
        for (label, unit, value) in fleetWrites(hostID: otherHostID, spaceID: otherSpaceID) {
            var fields = ["unit": unit, "value": value ?? "<deleted>"]
            do {
                try source.write(unit, value.map { Data($0.utf8) }, origin: "peer")
                _ = await synced.next()
                let moved = try movement(try await session.fetch())
                fields.merge(moved.fields) { $1 }
                for key in moved.keys { fleetKeys[key, default: []].append(label) }
                for field in moved.fields.keys where field.hasPrefix("reply.settings.") {
                    for key in moved.keys { wireFields[key, default: []].insert(String(field.dropFirst("reply.settings.".count))) }
                }
            } catch {
                fields["refused"] = "\(error)"
            }
            try observe("sync.\(label)", fields)
        }

        // Each setting's write paths, from what was seen above.
        var summary: [String: String] = [:]
        for key in keys {
            let paths: [String: Any] = [
                "a": followed[key] == true ? "followed" : "own process only",
                "b": wireKeys[key] ?? [], "c": fleetKeys[key] ?? [],
                "hostSettingsFields": (wireFields[key] ?? []).sorted(),
            ]
            summary[key] = text(paths)
        }
        try observe("summary", summary)
    }

    // MARK: Probes for the Mac's own write

    private struct Probe {
        let key: String
        /// Writes a value that is not the default; returns it as text.
        let write: @MainActor (AppSettings) -> String
        let read: @MainActor (AppSettings) -> String
    }

    private static func probe<T>(_ key: String, _ path: ReferenceWritableKeyPath<AppSettings, T>, to value: T,
                                 show: @escaping (T) -> String = { "\($0)" }) -> Probe {
        Probe(key: key, write: { $0[keyPath: path] = value; return show(value) }, read: { show($0[keyPath: path]) })
    }

    private static func flip(_ key: String, _ path: ReferenceWritableKeyPath<AppSettings, Bool>) -> Probe {
        Probe(key: key, write: { settings in let value = !settings[keyPath: path]; settings[keyPath: path] = value; return "\(value)" },
              read: { "\($0[keyPath: path])" })
    }

    private static func next<T: CaseIterable & Equatable>(_ key: String, _ path: ReferenceWritableKeyPath<AppSettings, T>) -> Probe {
        Probe(key: key, write: { settings in
            let current = settings[keyPath: path]
            let value = T.allCases.first { $0 != current }!
            settings[keyPath: path] = value
            return "\(value)"
        }, read: { "\($0[keyPath: path])" })
    }

    private static func encoded<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "<unencodable>"
    }

    private static func probes(hostID: UUID, spaceID: String) -> [Probe] {
        typealias K = AppSettings.Key
        return [
            probe(K.terminalFontFamily, \.terminalFontFamily, to: "Menlo"),
            probe(K.terminalFontSize, \.terminalFontSize, to: 14),
            probe(K.defaultModel, \.defaultModel, to: "acme/model-a"),
            probe(K.defaultThinking, \.defaultThinking, to: .high),
            probe(K.defaultServiceTier, \.defaultServiceTier, to: .fast),
            probe(K.textGenerationModel, \.textGenerationModel, to: "acme/text"),
            probe(K.visionModel, \.visionModel, to: "acme/vision"),
            next(K.queueDelivery, \.queueDelivery),
            flip(K.trimToolOutput, \.trimToolOutput),
            flip(K.notifyOnTurnFinished, \.notifyOnTurnFinished),
            flip(K.deferTools, \.deferTools),
            flip(K.threadsStartThreads, \.threadsStartThreads),
            next(K.subThreadPlace, \.subThreadPlace),
            flip(K.codemode, \.codemode),
            probe(K.compactAtPercent, \.compactAtPercent, to: 80, show: { encoded($0) }),
            probe(K.shellPath, \.shellPath, to: "/bin/bash"),
            probe(K.editor, \.editor, to: "acme-edit", show: { encoded($0) }),
            probe(K.editorsByType, \.editorsByType, to: ["swift": "acme-edit"], show: { encoded($0) }),
            flip(K.piPanesExtension, \.piPanesExtension),
            flip(K.piReviewExtension, \.piReviewExtension),
            flip(K.subagentDisplay, \.subagentDisplay),
            flip(K.piNativeSubagents, \.piNativeSubagents),
            flip(K.piMCPExtension, \.piMCPExtension),
            flip(K.piBrowserExtension, \.piBrowserExtension),
            flip(K.piDesignReferences, \.piDesignReferences),
            probe(K.childConcurrency, \.childConcurrency, to: 8),
            probe(K.childModel, \.childModel, to: "acme/child"),
            probe(K.childThinking, \.childThinking, to: "high"),
            probe(K.childContext, \.childContext, to: "fork"),
            probe(K.uiDensity, \.uiDensity, to: 1.25),
            probe(K.uiTextScale, \.uiTextScale, to: 1.1),
            probe(K.sidebarWidth, \.sidebarWidth, to: 300),
            next(K.sidebarRowDensity, \.sidebarRowDensity),
            next(K.sidebarStyle, \.sidebarStyle),
            probe(K.sidebarKeepIdleDays, \.sidebarKeepIdleDays, to: 14),
            flip(K.shareDiagnostics, \.shareDiagnostics),
            flip(K.remoteListenerEnabled, \.remoteListenerEnabled),
            probe(K.remoteListenerPort, \.remoteListenerPort, to: 9123),
            next(K.worktreeBaseMode, \.worktreeBaseMode),
            flip(K.worktreeFetchBeforeCreate, \.worktreeFetchBeforeCreate),
            flip(K.worktreeGeneratePRDescription, \.worktreeGeneratePRDescription),
            next(K.worktreeDeleteAction, \.worktreeDeleteAction),
            flip(K.worktreeCloseOnMerge, \.worktreeCloseOnMerge),
            probe(K.skippedConfirmations, \.skippedConfirmations, to: [SkippableConfirmation.removeSpace.rawValue: "remove"], show: { encoded($0) }),
            flip(K.skillsInSlashMenu, \.skillsInSlashMenu),
            probe(K.hiddenSlashCommands, \.hiddenSlashCommands, to: ["fix-tests"], show: { $0.sorted().joined(separator: ",") }),
            flip(K.mcpProjectConfig, \.mcpProjectConfig),
            flip(K.goalsEnabled, \.goalsEnabled),
            flip(K.projectsEnabled, \.projectsEnabled),
            flip(K.designToolEnabled, \.designToolEnabled),
            flip(K.computerUseEnabled, \.computerUseEnabled),
            probe(K.fleetWeights, \.fleetWeights, to: [FleetSendWeight.settingKey(hostID: hostID): .prefer], show: { encoded($0) }),
            flip(K.fleetThreadsCanSend, \.fleetThreadsCanSend),
            probe(K.fleetThreadCap, \.fleetThreadCap, to: 5),
            probe(K.fleetAutoDispatch, \.fleetAutoDispatch, to: true, show: { encoded($0) }),
            flip(K.fleetBatteryCountsHalf, \.fleetBatteryCountsHalf),
            next(K.fleetUncommitted, \.fleetUncommitted),
            probe(K.fleetSnapshotExcludes, \.fleetSnapshotExcludes,
                  to: [FleetSnapshotExcludes.settingKey(spaceID: spaceID): FleetSnapshotExcludes(excluded: ["dist"])], show: { encoded($0) }),
            probe(K.fleetCheckIgnores, \.fleetCheckIgnores, to: [FleetCheckIgnoreSetting.settingKey(hostID: hostID): ["check-a"]], show: { encoded($0) }),
            flip(K.implementOpensThread, \.implementOpensThread),
            flip(K.filesWordWrap, \.filesWordWrap),
            flip(K.filesMarkdownPreview, \.filesMarkdownPreview),
        ]
    }

    // MARK: What a client sends and what a Fleet sync writes

    /// One change per case a client can send, with the odd ones (legacy, unknown, out of range, refused) beside them.
    /// The exhaustive switch in `kind` stops the build on a case this list has not met.
    private static func changes(hostID: UUID, spaceID: String) -> [(String, HostSettingChange)] {
        func kind(_ change: HostSettingChange) {
            switch change {
            case .defaultModel, .defaultThinking, .defaultServiceTier, .textGenerationModel, .visionModel, .namingModel, .compactAtPercent,
                 .queueDelivery, .goalCrossProviderEvaluation, .goalsEnabled, .projectsEnabled, .worktreeBase, .fetchBeforeCreating,
                 .commitRemainingWork, .generatePRDescriptions, .deleteLocalBranch, .mergePRAutomatically, .mergeMethod, .closeOnMerge,
                 .bundledExtension, .updatePiDaily, .updateExtensionsDaily, .fleetWeight, .fleetThreadsCanSend, .fleetThreadCap,
                 .fleetUncommitted, .fleetSnapshotExcludes, .fleetCheckIgnore, .fleetAutoDispatch, .fleetBatteryCountsHalf,
                 .designToolEnabled, .threadsStartThreads, .subThreadPlace, .computerUseEnabled, .subagentDefaults,
                 .worktreeDeleteAction, .skillsInSlashMenu, .mcpProjectConfig, .slashCommand: break
            }
        }
        let list: [(String, HostSettingChange)] = [
            ("defaultModel", .defaultModel("  acme/model-a ")),
            ("defaultModel.cleared", .defaultModel(nil)),
            ("defaultModel.again", .defaultModel("acme/model-b")),
            ("defaultThinking", .defaultThinking(.high)),
            ("defaultServiceTier", .defaultServiceTier(.fast)),
            ("textGenerationModel", .textGenerationModel("acme/text")),
            ("namingModel", .namingModel("acme/naming")),
            ("visionModel", .visionModel("acme/vision")),
            ("compactAtPercent", .compactAtPercent(80)),
            ("compactAtPercent.notOffered", .compactAtPercent(75)),
            ("queueDelivery", .queueDelivery(.oneAtATime)),
            ("goalCrossProviderEvaluation", .goalCrossProviderEvaluation(true)),
            ("goalsEnabled", .goalsEnabled(true)),
            ("projectsEnabled", .projectsEnabled(true)),
            ("worktreeBase", .worktreeBase(.head)),
            ("fetchBeforeCreating", .fetchBeforeCreating(false)),
            ("generatePRDescriptions", .generatePRDescriptions(false)),
            ("closeOnMerge", .closeOnMerge(true)),
            ("commitRemainingWork", .commitRemainingWork(false)),
            ("deleteLocalBranch", .deleteLocalBranch(false)),
            ("mergePRAutomatically", .mergePRAutomatically(true)),
            ("mergeMethod", .mergeMethod(.merge)),
        ] + HostSettingsMapping.bundled.map { ("bundledExtension.\($0.id)", HostSettingChange.bundledExtension(id: $0.id, on: false)) } + [
            ("bundledExtension.unknown", .bundledExtension(id: "someday", on: false)),
            ("updatePiDaily", .updatePiDaily(true)),
            ("updateExtensionsDaily", .updateExtensionsDaily(true)),
            ("fleetWeight", .fleetWeight(hostID: hostID, weight: .prefer)),
            ("fleetThreadsCanSend", .fleetThreadsCanSend(true)),
            ("fleetThreadCap", .fleetThreadCap(5)),
            ("fleetThreadCap.aboveRange", .fleetThreadCap(1000)),
            ("fleetUncommitted", .fleetUncommitted(.leaveBehind)),
            ("fleetSnapshotExcludes", .fleetSnapshotExcludes(spaceID: spaceID, excludes: FleetSnapshotExcludes(excluded: ["dist"]))),
            ("fleetCheckIgnore", .fleetCheckIgnore(hostID: hostID, ids: ["check-a", "check-b"])),
            ("fleetAutoDispatch", .fleetAutoDispatch(true)),
            ("fleetBatteryCountsHalf", .fleetBatteryCountsHalf(false)),
            ("designToolEnabled", .designToolEnabled(true)),
            ("threadsStartThreads", .threadsStartThreads(true)),
            ("subThreadPlace", .subThreadPlace(.worktree)),
            ("computerUseEnabled", .computerUseEnabled(true)),
            ("subagentDefaults", .subagentDefaults(.init(concurrency: 8, model: "acme/child", thinking: .high, context: .fork))),
            ("subagentDefaults.aboveRange", .subagentDefaults(.init(concurrency: 99))),
            ("worktreeDeleteAction", .worktreeDeleteAction(.keepWorktree)),
            ("skillsInSlashMenu", .skillsInSlashMenu(false)),
            ("mcpProjectConfig", .mcpProjectConfig(true)),
            ("slashCommand", .slashCommand(name: "fix-tests", on: false)),
            ("slashCommand.refused", .slashCommand(name: "", on: false)),
        ]
        list.forEach { kind($0.1) }
        return list
    }

    /// Host settings a peer's sync writes (`FleetHostSetting`, then a weight, a space's excludes and a Mac's ignores), each with a value
    /// the wire changes above left otherwise, so a change shows. `nil` is a deletion.
    private static func fleetWrites(hostID: UUID, spaceID: String) -> [(label: String, unit: String, value: String?)] {
        let hostValues: [String: String] = [
            "defaultModel": "\"acme/model-c\"", "defaultThinking": "\"low\"", "defaultServiceTier": "\"standard\"",
            "textGenerationModel": "\"acme/text-c\"", "visionModel": "\"acme/vision-c\"", "compactAtPercent": "60",
            "queueDelivery": "\"all\"", "worktreeBase": "\"fresh\"", "fetchBeforeCreating": "true", "generatePRDescriptions": "true",
            "closeOnMerge": "false", "worktreeDeleteAction": "\"removeWorktree\"", "fleetThreadsCanSend": "false", "fleetThreadCap": "7",
            "fleetAutoDispatch": "false", "fleetBatteryCountsHalf": "true", "fleetUncommitted": "\"sendThem\"",
        ]
        precondition(Set(hostValues.keys) == Set(FleetHostSetting.allCases.map(\.rawValue)), "a synced host setting has no sample value")
        let weight = FleetWeightSetting.unit(hostID: hostID)
        return FleetHostSetting.allCases.map { ($0.key, $0.unit, hostValues[$0.rawValue]) } + [
            ("fleet.weight", weight, "\"lessOften\""),
            ("fleet.weight.deleted", weight, nil),
            ("fleet.snapshotExcludes", FleetSnapshotExcludeSetting.unit(spaceID: spaceID), "{\"excluded\":[\"build\"],\"included\":[]}"),
            ("fleet.checkIgnore", FleetCheckIgnoreSetting.unit(hostID: hostID), "[\"check-c\"]"),
            ("refused.value", FleetHostSetting.defaultThinking.unit, "\"loud\""),
            ("refused.unit", FleetUnit.setting("host.someday"), "true"),
        ]
    }

    // MARK: Observation helpers

    private final class Wire: @unchecked Sendable {
        private let client: ExtensionClient
        init(path: String) throws { client = try ExtensionClient(path: path) }

        func exchange(_ request: RemoteRequest) async throws -> (request: [String: Any], reply: [String: Any]) {
            let (sent, received) = try await Task.detached { [client] in
                let sent = try NDJSON.encode(request)
                try client.sendRaw(sent)
                while true {
                    let received = try client.readLine()
                    // A pushed notification has no request ID; keep the first reply that has one, whatever it is.
                    if try SettingsWritePathTests.jsonObject(received)["id"] != nil { return (sent, received) }
                }
            }.value
            return (try SettingsWritePathTests.jsonObject(sent), try SettingsWritePathTests.jsonObject(received))
        }
    }

    /// The requests of one connection, numbered from 1.
    private final class Session {
        let wire: Wire
        var nextID = 1
        init(wire: Wire) { self.wire = wire }

        func send(_ build: @Sendable (Int) -> RemoteRequest) async throws -> (request: [String: Any], reply: [String: Any]) {
            defer { nextID += 1 }
            return try await wire.exchange(build(nextID))
        }

        func fetch() async throws -> [String: Any] { try await send { .hostSettings(id: $0, request: .fetch) }.reply }
    }

    /// The request and reply the way a client matches them: type, id and, for a refusal, its code and words.
    private static func correlation(_ exchange: (request: [String: Any], reply: [String: Any])) -> [String: String] {
        var fields: [String: String] = [:]
        for key in ["id", "type", "protocolVersion"] {
            fields["request.\(key)"] = exchange.request[key].map { text($0) }
            fields["reply.\(key)"] = exchange.reply[key].map { text($0) }
        }
        for key in ["code", "message"] { fields["reply.\(key)"] = exchange.reply[key].map { text($0) } }
        if let body = exchange.request["request"] { fields["request.body"] = text(body) }
        return fields.compactMapValues { $0 }
    }

    /// HostSettings fields as text, the bundled extensions one by one so a switch shows as itself.
    private static func flatten(_ settings: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (field, value) in settings {
            if field == "bundledExtensions", let list = value as? [[String: Any]] {
                for item in list { out["bundledExtensions[\(item["id"] ?? "?")].on"] = text(item["on"]) }
            } else {
                out[field] = text(value)
            }
        }
        return out
    }

    /// Every persisting key's stored value, as the same JSON text however the store holds it.
    private static func snapshot(_ store: UserDefaults) -> [String: String] {
        var out: [String: String] = [:]
        for key in AppSettings.Key.all {
            guard var value = store.object(forKey: key) else { continue }
            if let data = value as? Data, let parsed = try? JSONSerialization.jsonObject(with: data) { value = parsed }
            out[key] = text(value)
        }
        return out
    }

    private static func changedKeys(_ before: [String: String], _ after: [String: String]) -> [String] {
        Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
    }

    nonisolated private static func text(_ value: Any?) -> String {
        guard let value else { return "<missing>" }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else {
            return "\(value)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
