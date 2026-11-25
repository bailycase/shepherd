import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Every persisting setting and every way a write reaches it today, pinned as a golden
/// (`Tests/Fixtures/settings-write-paths.json`): (a) the Mac's own write, taken by the host through the
/// real change notice and read back in the host's reply, (b) a client's `hostSettings` change over the
/// host socket, (c) a Fleet op delivered to the host's registered settings source, and what none of them
/// reach. Characterization only: the golden records today's outcome, known oddities included.
/// `SHEPHERD_GOLDEN_CAPTURE=<file>` writes the observations there instead of comparing.
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
        "peerID": "00000000-0000-4000-8000-0000000000C3", "spaceID": "acme-web-space", "otherSpaceID": "acme-docs-space",
    ]

    private static func checkingWritePaths() async throws {
        if let capture = ProcessInfo.processInfo.environment["SHEPHERD_GOLDEN_CAPTURE"] {
            var captured: [[String: Any]] = []
            try await observeWritePaths { captured.append(["step": $0, "fields": $1]) }
            let data = try JSONSerialization.data(withJSONObject: ["seed": seed, "observations": captured],
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: URL(fileURLWithPath: capture))
            return
        }
        try await ValidationGolden.check("settings-write-paths.json", from: #filePath,
                                         completion: "every settings write path matched the golden") { golden in
            try #require(golden.seed as? [String: String] == seed, "the golden was captured with other seed inputs")
            try await observeWritePaths(golden.observe)
        }
    }

    // MARK: The settings, read from what production declares and writes

    /// A setting the golden does not know, or a probe for one that is gone: the message names it.
    private struct Inventory: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Declared in `AppSettings.Key` but no longer a setting: read once at load to move its choice to the text
    /// generation model, then removed.
    private static let retired: Set<String> = ["legacyNamingModel"]

    private static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// The persisting settings, from `AppSettings.swift` itself: the keys declared in `enum Key` and the keys its `store.set` calls
    /// write, never `Key.all` (which only has to agree). `tracked` adds the retired keys, so a write to one still shows.
    private static func inventory() throws -> (settings: [String], tracked: [String]) {
        let source = try String(contentsOf: sources.appendingPathComponent("ShepherdApp/AppSettings.swift"), encoding: .utf8)
        let declarations = try #require(source.range(of: "enum Key {").flatMap { start in
            source.range(of: "static let all = [", range: start.upperBound..<source.endIndex).map { source[start.upperBound..<$0.lowerBound] }
        })
        var declared: [String: String] = [:]
        for match in declarations.matches(of: /static let (\w+) = "(shepherd\.[^"]+)"/) { declared[String(match.1)] = String(match.2) }
        var written: Set<String> = [], literals: Set<String> = []
        for match in source.matches(of: /store\.set\([^\n]*forKey: (?:Key\.(\w+)|("[^"]*"))/) {
            if let name = match.1 { written.insert(String(name)) } else if let literal = match.2 { literals.insert(String(literal)) }
        }
        guard literals.isEmpty else { throw Inventory("settings written to a key that is not declared in AppSettings.Key: \(literals.sorted())") }
        let names = Set(declared.keys).subtracting(retired)
        guard written == names else {
            throw Inventory("AppSettings.Key declares and `store.set` writes differ: declared only \(names.subtracting(written).sorted()), written only \(written.subtracting(names).sorted())")
        }
        let settings = names.map { declared[$0]! }.sorted()
        guard Set(AppSettings.Key.all) == Set(settings) else {
            throw Inventory("settings declared and written by AppSettings but missing from AppSettings.Key.all: \(Set(settings).subtracting(AppSettings.Key.all).sorted()); listed there but not declared: \(Set(AppSettings.Key.all).subtracting(settings).sorted())")
        }
        return (settings, (settings + retired.map { declared[$0]! }).sorted())
    }

    /// Where production assigns `remoteListenerPort`: file name and count, outside the declaration of its key.
    private static func portWriters() throws -> String {
        var writers: [String: Int] = [:]
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let count = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
                .filter { $0.contains(/remoteListenerPort\s*=[^=]/) && !$0.contains("static let") }.count
            if count > 0 { writers[url.lastPathComponent] = count }
        }
        return text(writers)
    }

    // MARK: The observations

    private static func observeWritePaths(_ observe: (String, [String: Any]) throws -> Void) async throws {
        let hostID = try #require(UUID(uuidString: seed["hostID"]!)), otherHostID = try #require(UUID(uuidString: seed["otherHostID"]!))
        let peerID = try #require(UUID(uuidString: seed["peerID"]!))
        let spaceID = seed["spaceID"]!, otherSpaceID = seed["otherSpaceID"]!

        let (keys, tracked) = try inventory()
        let probes = Dictionary(uniqueKeysWithValues: Self.probes(hostID: hostID, spaceID: spaceID).map { ($0.key, $0) })
        guard Set(probes.keys) == Set(keys) else {
            throw Inventory("settings without a write-path probe: \(Set(keys).subtracting(probes.keys).sorted()); probes for no setting: \(Set(probes.keys).subtracting(keys).sorted())")
        }
        AccessibilityNode.enable()

        // (a) The Mac's own write, taken by the host and read back in its reply.
        let direct = try await observeDirectWrites(keys: keys, tracked: tracked, probes: probes, observe)
        try observe("remoteListenerPort.writers", ["assignmentsInSources": try portWriters()])

        // (b) and (c) run against a fresh host the app serves, over its socket.
        let app = try AppHarness()
        defer { app.stop() }
        try await app.server.useLoopbackNetworkingForTests()
        try await app.start()
        let hostSettings = try #require(app.hostSettings)
        let session = Session(wire: try Wire(path: app.hostSocket))

        let hello = try await session.send { .hello(id: $0, token: "", clientName: "validation", protocolVersion: RemoteProtocol.version) }
        try observe("wire.hello", correlation(hello))
        var settings = flatten(try await session.fetch()["settings"] as? [String: Any] ?? [:])
        var stored = snapshot(app.defaults, tracked)

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
            let after = snapshot(app.defaults, tracked)
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

        // (c) A peer's op reaches the host's own fleet, which hands it to the settings source the app registered
        // (`ShepherdHost.serveSettings`): no request, no capability check.
        /// The host's settings reach the fleet a moment after they change; the next op waits for that, so it never meets a
        /// change the fleet has not yet seen as the host's own.
        func reported() async throws {
            try await eventuallyOnMain("the host to report its settings to the fleet") {
                app.server.fleetSettingsForTests == HostSettingsMapping.settings(from: hostSettings, shepherdVersion: nil, piVersion: nil)
            }
        }
        try await reported()
        let engine = try #require(app.server.queue.sync { app.server.fleet?.syncEngine })
        // Sync runs only while a Mac is paired (`FleetService.updateEngines`); this host has none, so start the engine as that would.
        app.server.queue.sync { engine.start() }
        try await reported()
        let base = UInt64(Date().timeIntervalSince1970 * 1000) + 3_600_000
        var fleetKeys: [String: [String]] = [:]
        for (index, (label, unit, value)) in fleetWrites(hostID: otherHostID, spaceID: otherSpaceID).enumerated() {
            let seq = UInt64(index + 1)
            let op = FleetOp(mac: peerID, seq: seq, hlc: FleetHLC(wallMs: base + seq), unit: unit,
                             change: value.map { .value($0) } ?? .deletion, macName: "Peer")
            let reply = app.server.queue.sync { engine.serve(.op(op), from: peerID) }
            // The app applies it on the main actor.
            await Task { @MainActor in }.value
            var fields = ["unit": unit, "value": value ?? "<deleted>"]
            if case .success = reply { fields["accepted"] = "yes" } else { fields["accepted"] = "no" }
            let moved = try movement(try await session.fetch())
            fields.merge(moved.fields) { $1 }
            for key in moved.keys { fleetKeys[key, default: []].append(label) }
            for field in moved.fields.keys where field.hasPrefix("reply.settings.") {
                for key in moved.keys { wireFields[key, default: []].insert(String(field.dropFirst("reply.settings.".count))) }
            }
            try observe("sync.\(label)", fields)
            try await reported()
        }

        // Each setting's write paths, from what was seen above.
        var summary: [String: String] = [:]
        for key in keys {
            let reaches = direct[key]!
            let hostFields = Set(reaches.fields).union(wireFields[key] ?? [])
            let paths: [String: Any] = [
                "a": reaches.followed ? "followed" : "not followed",
                "aHostReplyFields": reaches.fields,
                "b": wireKeys[key] ?? [], "c": fleetKeys[key] ?? [],
                "hostSettingsFields": hostFields.sorted(),
                "deviceOnly": hostFields.isEmpty && wireKeys[key] == nil && fleetKeys[key] == nil ? "yes" : "no",
            ]
            summary[key] = text(paths)
        }
        try observe("summary", summary)
    }

    /// (a) One write per setting on the app's `AppSettings`, with the host's own `AppSettings` following the same preferences through
    /// the Darwin change notice, as the background host does. A notice has no reply to wait on, so each write is followed by one the
    /// host is known to take (a sentinel setting, the terminal font family or, for that one, the editor): the host reads the whole store on each notice, so by the time it
    /// has the sentinel it has had its chance at the setting. Records whether it took it and which HostSettings fields its reply moved.
    private static func observeDirectWrites(keys: [String], tracked: [String], probes: [String: Probe],
                                            _ observe: (String, [String: Any]) throws -> Void) async throws -> [String: (followed: Bool, fields: [String])] {
        typealias K = AppSettings.Key
        let harness = try AppHarness()
        defer { harness.stop() }
        try await harness.server.useLoopbackNetworkingForTests()
        try await harness.start()
        let app = harness.settings, host = try #require(harness.hostSettings)
        let services = try #require(harness.host)
        // Nothing in production writes the port (`remoteListenerPort.writers`): the host would listen on the stored one, the
        // edition's. Aim it at 0 so Serve this Mac opens on a free port.
        host.remoteListenerPort = 0
        let session = Session(wire: try Wire(path: harness.hostSocket))
        _ = try await session.send { .hello(id: $0, token: "", clientName: "validation", protocolVersion: RemoteProtocol.version) }
        var seen = flatten(try await session.fetch()["settings"] as? [String: Any] ?? [:])
        var sentinels = 0

        func reachHost(from probe: Probe) async throws {
            sentinels += 1
            let value = "sentinel-\(sentinels)"
            if probe.key == K.terminalFontFamily {
                app.editor = value
                try await eventuallyOnMain("the host to take the sentinel after \(probe.key)") { host.editor == value }
            } else {
                app.terminalFontFamily = value
                try await eventuallyOnMain("the host to take the sentinel after \(probe.key)") { host.terminalFontFamily == value }
            }
        }
        /// The HostSettings fields of the host's reply that moved since the last look.
        func hostReplyMoved() async throws -> [String: String] {
            let now = flatten(try await session.fetch()["settings"] as? [String: Any] ?? [:])
            defer { seen = now }
            return Dictionary(uniqueKeysWithValues: Set(seen.keys).union(now.keys).sorted().filter { seen[$0] != now[$0] }.map { ("hostReply.\($0)", now[$0] ?? "<missing>") })
        }

        var reaches: [String: (followed: Bool, fields: [String])] = [:]
        var openedPort: UInt16?
        for key in keys {
            let probe = probes[key]!
            let before = snapshot(harness.defaults, tracked), hostBefore = probe.read(host)
            let written = probe.write(app)
            let after = snapshot(harness.defaults, tracked)
            try await reachHost(from: probe)
            let followed = probe.read(host) != hostBefore
            var fields: [String: Any] = [
                "write": written, "stored": after[key] ?? "<missing>",
                "storedKeysChanged": changedKeys(before, after).joined(separator: ","),
                "hostProcess.before": hostBefore, "hostProcess.afterNotice": probe.read(host), "followed": followed ? "yes" : "no",
            ]
            let moved = try await hostReplyMoved()
            fields.merge(moved) { $1 }
            try observe("direct.\(key)", fields)
            reaches[key] = (followed, moved.keys.map { String($0.dropFirst("hostReply.".count)) }.sorted())
            if key == K.remoteListenerEnabled {
                try await eventuallyOnMain("Serve this Mac to open the TCP listener") { services.listener.port != nil }
                let port = try #require(services.listener.port)
                try #require(try loopbackConnectError(port) == nil)
                openedPort = port
            }
        }

        // Serve this Mac's switch opens the listener in the host; turning it off closes it.
        app.remoteListenerEnabled = false
        try await reachHost(from: probes[K.remoteListenerEnabled]!)
        try observe("direct.\(K.remoteListenerEnabled).off", try await hostReplyMoved())
        try await eventuallyOnMain("Serve this Mac to close the TCP listener") { services.listener.port == nil }
        let port = try #require(openedPort)
        try #require(try loopbackConnectError(port) == ECONNREFUSED)
        return reaches
    }

    /// Probe the actual TCP socket, independent of the host's listener bookkeeping.
    private static func loopbackConnectError(_ port: UInt16) throws -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Inventory("TCP probe socket: errno \(errno)") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 ? nil : errno
            }
        }
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

    /// Host settings a peer's ops write (`FleetHostSetting`, then a weight, a space's excludes and a Mac's ignores), each with a value
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
    @MainActor private final class Session {
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
            } else if field == "listenerPort" {
                // The port is whatever the system gave.
                out[field] = "<open>"
            } else {
                out[field] = text(value)
            }
        }
        return out
    }

    /// Every persisting key's stored value, as the same JSON text however the store holds it.
    private static func snapshot(_ store: UserDefaults, _ keys: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for key in keys {
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
