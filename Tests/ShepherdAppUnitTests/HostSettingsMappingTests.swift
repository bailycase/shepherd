import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestKit
@testable import ShepherdApp

/// What a remote client sees of this Mac's settings, and a client's change applied as the Mac's
/// own Settings would apply it.
@Suite("Host settings")
@MainActor
struct HostSettingsMappingTests {
    @Test func aClientSeesWhatTheMacsSettingsSay() {
        let app = AppSettings(store: Fixture.defaults())
        app.defaultModel = "anthropic/claude-opus"
        app.defaultThinking = .high
        app.goalsEnabled = true
        app.worktreeBaseMode = .head
        app.piReviewExtension = false
        let settings = HostSettingsMapping.settings(from: app, shepherdVersion: "0.4.2", piVersion: "0.87.1")
        #expect(settings.shepherdVersion == "0.4.2" && settings.piVersion == "0.87.1")
        #expect(settings.defaultModel == "anthropic/claude-opus")
        #expect(settings.defaultThinking == .high)
        #expect(!settings.goalCrossProviderEvaluation && settings.goalsEnabled, "the legacy checker consent is always off")
        #expect(settings.worktreeBase == .head)
        #expect(!settings.mergePRAutomatically && settings.mergeMethod == .squash, "the removed Finalize's settings read as their defaults")
        #expect(settings.bundledExtensions.map(\.id) == ["panes", "review", "nativeSubagents", "subagents", "mcp", "browser", "designReferences", "context", "deferTools", "codemode"])
        #expect(settings.bundledExtensions.first { $0.id == "review" }?.on == false)
        #expect(settings.bundledExtensions.first { $0.id == "review" }?.name == "Diff review tool")
        // The extension keeps its stored id; it reads as terminals to the user.
        #expect(settings.bundledExtensions.first { $0.id == "panes" }?.name == "Terminals and agent tools")
        // pi's own default reads as none.
        app.defaultModel = ""
        #expect(HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil).defaultModel == nil)
    }

    @Test func aClientExplainsEveryBundledExtensionTheMacServes() {
        for bundled in HostSettingsMapping.bundled {
            #expect(HostSettingsPresentation.note(forBundled: bundled.id) != nil, "no note for \(bundled.id)")
        }
        #expect(HostSettingsPresentation.note(forBundled: "someday") == nil)
    }

    /// There is no pane to control: the row and its note, on the Mac and in every client, speak of
    /// terminals.
    @Test func noBundledExtensionsNameOrNoteSaysPane() {
        for bundled in HostSettingsMapping.bundled where bundled.id == "panes" {
            let note = HostSettingsPresentation.note(forBundled: bundled.id) ?? ""
            #expect(bundled.name == "Terminals and agent tools")
            #expect(note.contains("terminals"))
            for text in [bundled.name, note] {
                #expect(!text.lowercased().contains("pane"), "\(text)")
            }
        }
    }

    /// Trimming old tool output is Settings ▸ Agents on the Mac and one more switch in a client's list.
    @Test func aClientCanSwitchOldToolOutputTrimmingOffAndOn() {
        let app = AppSettings(store: Fixture.defaults())
        #expect(HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil).bundledExtensions.first { $0.id == "context" }?.on == true)
        HostSettingsMapping.apply(.bundledExtension(id: "context", on: false), to: app)
        #expect(!app.trimToolOutput)
        #expect(HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil).bundledExtensions.first { $0.id == "context" }?.on == false)
    }

    /// Deferring rarely used tools is Settings ▸ Agents on the Mac and one more switch in a client's list, on until switched off.
    @Test func aClientCanSwitchToolDeferralOffAndOn() {
        let app = AppSettings(store: Fixture.defaults())
        func on() -> Bool? {
            HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil).bundledExtensions.first { $0.id == "deferTools" }?.on
        }
        #expect(on() == true)
        HostSettingsMapping.apply(.bundledExtension(id: "deferTools", on: false), to: app)
        #expect(!app.deferTools && on() == false)
        HostSettingsMapping.apply(.bundledExtension(id: "deferTools", on: true), to: app)
        #expect(app.deferTools && on() == true)
        #expect(HostSettingsMapping.bundled.map(\.id).suffix(3) == ["context", "deferTools", "codemode"], "listed beside the other Context switches")
    }

    @Test func aClientCanSwitchCodemodeWithoutChangingToolDeferral() {
        let app = AppSettings(store: Fixture.defaults())
        #expect(HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil).bundledExtensions.first { $0.id == "codemode" }?.on == true)
        HostSettingsMapping.apply(.bundledExtension(id: "codemode", on: false), to: app)
        #expect(!app.codemode && app.deferTools)
        HostSettingsMapping.apply(.bundledExtension(id: "codemode", on: true), to: app)
        #expect(app.codemode)
    }

    @Test func aClientsChangeLandsInTheMacsSettings() {
        let app = AppSettings(store: Fixture.defaults())
        HostSettingsMapping.apply(.defaultModel("  openai/gpt-5 "), to: app)
        #expect(app.defaultModel == "openai/gpt-5")
        HostSettingsMapping.apply(.defaultModel(nil), to: app)
        #expect(app.defaultModel.isEmpty)
        HostSettingsMapping.apply(.goalCrossProviderEvaluation(true), to: app) // An older client's legacy change is ignored.
        #expect(!HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil).goalCrossProviderEvaluation)
        HostSettingsMapping.apply(.queueDelivery(.oneAtATime), to: app)
        #expect(app.queueDelivery == .oneAtATime)
        HostSettingsMapping.apply(.worktreeBase(.head), to: app)
        #expect(app.worktreeBaseMode == .head)
        // An older client's Finalize settings change nothing.
        let unchanged = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil)
        for legacy: HostSettingChange in [.commitRemainingWork(false), .deleteLocalBranch(false), .mergePRAutomatically(true), .mergeMethod(.merge)] {
            HostSettingsMapping.apply(legacy, to: app)
        }
        #expect(HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil) == unchanged)
        HostSettingsMapping.apply(.bundledExtension(id: "panes", on: false), to: app)
        #expect(!app.piPanesExtension)
        HostSettingsMapping.apply(.bundledExtension(id: "browser", on: false), to: app)
        #expect(!app.piBrowserExtension, "a remote client can switch Browser tools")
        // An extension the Mac doesn't bundle changes nothing.
        let before = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil)
        HostSettingsMapping.apply(.bundledExtension(id: "missiles", on: true), to: app)
        #expect(HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil) == before)
    }

    /// Every change the protocol names reaches the setting it names, as the snapshot reads back.
    @Test(arguments: [
        HostSettingChange.defaultThinking(.low), .textGenerationModel("cheap/mini"), .textGenerationModel(nil), .namingModel("cheap/mini"),
        .visionModel("cheap/sees"), .visionModel(nil),
        .goalsEnabled(true), .goalsEnabled(false), .projectsEnabled(true), .projectsEnabled(false),
        .fetchBeforeCreating(false),
        .generatePRDescriptions(false),
        .bundledExtension(id: "review", on: false), .bundledExtension(id: "nativeSubagents", on: false), .bundledExtension(id: "context", on: false),
        .bundledExtension(id: "designReferences", on: false),
        .designToolEnabled(true), .computerUseEnabled(true), .computerUseEnabled(false),
        .subagentDefaults(HostSettings.SubagentDefaults(concurrency: 9, model: "openai/gpt-5-mini", thinking: .high, context: .fork)),
        .worktreeDeleteAction(.removeWorktree), .skillsInSlashMenu(false), .mcpProjectConfig(true), .slashCommand(name: "review", on: false),
        .closeOnMerge(true), .closeOnMerge(false),
        .threadsStartThreads(true), .subThreadPlace(.worktree),
    ])
    func aChangeReadsBackAsTheProtocolAppliesIt(_ change: HostSettingChange) {
        let app = AppSettings(store: Fixture.defaults())
        var expected = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil)
        expected.apply(change)
        HostSettingsMapping.apply(change, to: app)
        #expect(HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil) == expected)
    }

    /// Every case a client can send changes the field it names, as the reply reads back, except the legacy ones that are
    /// inert on purpose. The exhaustive switch stops the build on a case with no row here: add a sample change for it.
    @Test func everyChangeMovesItsFieldExceptTheInertLegacyCases() {
        func inert(_ change: HostSettingChange) -> Bool {
            switch change {
            case .goalCrossProviderEvaluation, .commitRemainingWork, .deleteLocalBranch, .mergePRAutomatically, .mergeMethod,
                 .updatePiDaily, .updateExtensionsDaily: true
            case .defaultModel, .defaultThinking, .defaultServiceTier, .textGenerationModel, .visionModel, .namingModel, .compactAtPercent,
                 .queueDelivery, .goalsEnabled, .projectsEnabled, .worktreeBase, .fetchBeforeCreating, .generatePRDescriptions, .closeOnMerge,
                 .bundledExtension, .fleetWeight, .fleetThreadsCanSend, .fleetThreadCap, .fleetUncommitted, .fleetSnapshotExcludes,
                 .fleetCheckIgnore, .fleetAutoDispatch, .fleetBatteryCountsHalf, .designToolEnabled, .threadsStartThreads, .subThreadPlace,
                 .computerUseEnabled, .subagentDefaults, .worktreeDeleteAction, .skillsInSlashMenu, .mcpProjectConfig, .slashCommand: false
            }
        }
        let host = UUID()
        let samples: [HostSettingChange] = [
            .defaultModel("acme/model-a"), .defaultThinking(.high), .defaultServiceTier(.fast), .textGenerationModel("acme/text"),
            .visionModel("acme/vision"), .namingModel("acme/naming"), .compactAtPercent(80), .queueDelivery(.oneAtATime),
            .goalCrossProviderEvaluation(true), .goalsEnabled(true), .projectsEnabled(true), .worktreeBase(.head),
            .fetchBeforeCreating(false), .commitRemainingWork(false), .generatePRDescriptions(false), .deleteLocalBranch(false),
            .mergePRAutomatically(true), .mergeMethod(.merge), .closeOnMerge(true), .bundledExtension(id: "review", on: false),
            .updatePiDaily(true), .updateExtensionsDaily(true), .fleetWeight(hostID: host, weight: .prefer), .fleetThreadsCanSend(true),
            .fleetThreadCap(5), .fleetUncommitted(.leaveBehind), .fleetSnapshotExcludes(spaceID: "acme-web", excludes: FleetSnapshotExcludes(excluded: ["dist"])),
            .fleetCheckIgnore(hostID: host, ids: ["check-a"]), .fleetAutoDispatch(true), .fleetBatteryCountsHalf(false),
            .designToolEnabled(true), .threadsStartThreads(true), .subThreadPlace(.worktree), .computerUseEnabled(true),
            .subagentDefaults(.init(concurrency: 8, model: "acme/child", thinking: .high, context: .fork)),
            .worktreeDeleteAction(.keepWorktree), .skillsInSlashMenu(false), .mcpProjectConfig(true), .slashCommand(name: "fix-tests", on: false),
        ]
        for change in samples {
            let app = AppSettings(store: Fixture.defaults())
            let before = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil)
            var expected = before
            if !inert(change) {
                expected.apply(change) // the field the protocol says it names, and no other
                #expect(expected != before, "\(change) moves no field")
            }
            #expect(HostSettingsMapping.apply(change, to: app) == nil)
            let reply = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil)
            #expect(reply == expected, "\(change) \(inert(change) ? "changed the reply though it is inert" : "did not change exactly the field it names")")
        }
    }

    /// The Agents fields of the reply are read from the host's store, not from `AppSettings`: a value only the store
    /// holds shows up, in every field the group moved (the three bundled switches included).
    @Test func theReplyReadsTheAgentsGroupFromTheHostsStore() throws {
        let app = AppSettings(store: Fixture.defaults())
        let store = HostSettingsStore(file: try makeScratchDirectory("hps").appendingPathComponent("host-preferences.json"))
        app.adoptHostPreferences(store)
        store.update {
            $0.agents.defaultModel = "acme/store-model"
            $0.agents.defaultThinking = .high
            $0.agents.defaultServiceTier = .fast
            $0.agents.textGenerationModel = "acme/store-text"
            $0.agents.visionModel = "acme/store-vision"
            $0.agents.compactAtPercent = 80
            $0.agents.queueDelivery = .oneAtATime
            $0.agents.threadsStartThreads = true
            $0.agents.subThreadPlace = .worktree
            $0.agents.trimToolOutput = false
            $0.agents.deferTools = false
            $0.agents.codemode = false
        }
        #expect(app.defaultModel.isEmpty && app.codemode, "AppSettings still holds its own values")
        let reply = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil)
        #expect(reply.defaultModel == "acme/store-model" && reply.defaultThinking == .high && reply.defaultServiceTier == .fast)
        #expect(reply.textGenerationModel == "acme/store-text" && reply.visionModel == "acme/store-vision" && reply.compactAtPercent == 80)
        #expect(reply.queueDelivery == .oneAtATime && reply.threadsStartThreads && reply.subThreadPlace == .worktree)
        for id in ["context", "deferTools", "codemode"] {
            #expect(reply.bundledExtensions.first { $0.id == id }?.on == false, Comment(rawValue: id))
        }
    }

    /// The Worktrees fields of the reply are read from the host's store, not from `AppSettings`: each of the five shows
    /// the store's value, in its own field, and nothing else of the reply moves.
    @Test func theReplyReadsTheWorktreesGroupFromTheHostsStore() throws {
        let app = AppSettings(store: Fixture.defaults())
        let store = HostSettingsStore(file: try makeScratchDirectory("hps").appendingPathComponent("host-preferences.json"))
        app.adoptHostPreferences(store)
        let before = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil)
        #expect(before.worktreeBase == .fresh && before.fetchBeforeCreating && before.generatePRDescriptions
                && !before.closeOnMerge && before.worktreeDeleteAction == .ask)
        store.update {
            $0.worktrees.baseMode = .head
            $0.worktrees.fetchBeforeCreate = false
            $0.worktrees.generatePRDescription = false
            $0.worktrees.closeOnMerge = true
            $0.worktrees.deleteAction = .removeWorktree
        }
        #expect(app.worktreeBaseMode == .fresh && app.worktreeFetchBeforeCreate && !app.worktreeCloseOnMerge, "AppSettings still holds its own values")
        let reply = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil)
        #expect(reply.worktreeBase == .head)
        #expect(!reply.fetchBeforeCreating)
        #expect(!reply.generatePRDescriptions)
        #expect(reply.closeOnMerge)
        #expect(reply.worktreeDeleteAction == .removeWorktree)
        var expected = before
        expected.worktreeBase = .head
        expected.fetchBeforeCreating = false
        expected.generatePRDescriptions = false
        expected.closeOnMerge = true
        expected.worktreeDeleteAction = .removeWorktree
        #expect(reply == expected, "no other field moved")
    }

    /// The Experiments fields of the reply are read from the host's store, not from `AppSettings`: each of the four shows
    /// the store's value, in its own field, and nothing else of the reply moves.
    @Test func theReplyReadsTheExperimentsGroupFromTheHostsStore() throws {
        let app = AppSettings(store: Fixture.defaults())
        let store = HostSettingsStore(file: try makeScratchDirectory("hps").appendingPathComponent("host-preferences.json"))
        app.adoptHostPreferences(store)
        let before = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil)
        #expect(!before.goalsEnabled && !before.projectsEnabled && !before.designToolEnabled && !before.computerUseEnabled)
        store.update {
            $0.experiments.goals = true
            $0.experiments.projects = true
            $0.experiments.designTool = true
            $0.experiments.computerUse = true
        }
        #expect(!app.goalsEnabled && !app.projectsEnabled && !app.designToolEnabled && !app.computerUseEnabled, "AppSettings still holds its own values")
        let reply = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil)
        #expect(reply.goalsEnabled)
        #expect(reply.projectsEnabled)
        #expect(reply.designToolEnabled)
        #expect(reply.computerUseEnabled)
        var expected = before
        expected.goalsEnabled = true
        expected.projectsEnabled = true
        expected.designToolEnabled = true
        expected.computerUseEnabled = true
        #expect(reply == expected, "no other field moved")
    }

    /// The Fleet fields of the reply are read from the host's store, not from `AppSettings`: each of the eight shows
    /// the store's value, in its own field, and nothing else of the reply moves.
    @Test func theReplyReadsTheFleetGroupFromTheHostsStore() throws {
        let app = AppSettings(store: Fixture.defaults())
        let store = HostSettingsStore(file: try makeScratchDirectory("hps").appendingPathComponent("host-preferences.json"))
        app.adoptHostPreferences(store)
        let before = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil)
        #expect(before.fleetWeights.isEmpty && !before.fleetThreadsCanSend && before.fleetThreadCap == HostSettings.fleetThreadCapDefault
                && before.fleetAutoDispatch == nil && before.fleetBatteryCountsHalf && before.fleetUncommitted == .sendThem
                && before.fleetSnapshotExcludes.isEmpty && before.fleetCheckIgnores.isEmpty)
        let mac = try #require(UUID(uuidString: "00000000-0000-4000-8000-0000000000A1"))
        let weights = [FleetSendWeight.settingKey(hostID: mac): FleetSendWeight.prefer]
        let excludes = [FleetSnapshotExcludes.settingKey(spaceID: "acme-web"): FleetSnapshotExcludes(excluded: ["dist"])]
        let ignores = [FleetCheckIgnoreSetting.settingKey(hostID: mac): ["spot-check"]]
        store.update {
            $0.fleet.weights = weights
            $0.fleet.threadsCanSend = true
            $0.fleet.threadCap = 7
            $0.fleet.uncommitted = .leaveBehind
            $0.fleet.snapshotExcludes = excludes
            $0.fleet.checkIgnores = ignores
            $0.fleet.autoDispatch = false
            $0.fleet.batteryCountsHalf = false
        }
        #expect(app.fleetWeights.isEmpty && !app.fleetThreadsCanSend && app.fleetThreadCap == HostSettings.fleetThreadCapDefault
                && app.fleetAutoDispatch == nil && app.fleetBatteryCountsHalf, "AppSettings still holds its own values")
        let reply = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil)
        #expect(reply.fleetWeights == weights)
        #expect(reply.fleetThreadsCanSend)
        #expect(reply.fleetThreadCap == 7)
        #expect(reply.fleetUncommitted == .leaveBehind)
        #expect(reply.fleetSnapshotExcludes == excludes)
        #expect(reply.fleetCheckIgnores == ignores)
        #expect(reply.fleetAutoDispatch == false)
        #expect(!reply.fleetBatteryCountsHalf)
        var expected = before
        expected.fleetWeights = weights
        expected.fleetThreadsCanSend = true
        expected.fleetThreadCap = 7
        expected.fleetUncommitted = .leaveBehind
        expected.fleetSnapshotExcludes = excludes
        expected.fleetCheckIgnores = ignores
        expected.fleetAutoDispatch = false
        expected.fleetBatteryCountsHalf = false
        #expect(reply == expected, "no other field moved")
    }

    /// The stored Agents defaults are the ones `AppSettings` starts with, so a host with no old keys stores the defaults.
    @Test func theStoredAgentsDefaultsAreTheSettingsOwn() throws {
        let app = AppSettings(store: Fixture.defaults())
        let store = HostSettingsStore(file: try makeScratchDirectory("hps").appendingPathComponent("host-preferences.json"))
        app.adoptHostPreferences(store)
        #expect(store.preferences == StoredHostPreferences())
    }

    /// The Mac's own switches a client now reaches: Experiments, Subagent defaults, Worktrees,
    /// Skills, MCP and Slash commands land where Settings keeps them.
    @Test func aClientsHostLevelChangesLandInTheMacsSettings() {
        let app = AppSettings(store: Fixture.defaults())
        HostSettingsMapping.apply(.designToolEnabled(true), to: app)
        #expect(app.designToolEnabled)
        HostSettingsMapping.apply(.computerUseEnabled(true), to: app)
        #expect(app.computerUseEnabled && app.agentLaunch.computerUse)
        HostSettingsMapping.apply(.subagentDefaults(HostSettings.SubagentDefaults(concurrency: 40, model: " openai/gpt-5 ", thinking: .low, context: .fork)), to: app)
        #expect(app.childConcurrency == 16 && app.childModel == "openai/gpt-5" && app.childThinking == "low" && app.childContext == "fork")
        HostSettingsMapping.apply(.subagentDefaults(HostSettings.SubagentDefaults()), to: app)
        #expect(app.childConcurrency == 4 && app.childModel.isEmpty && app.childThinking.isEmpty && app.childContext == "fresh")
        HostSettingsMapping.apply(.worktreeDeleteAction(.keepWorktree), to: app)
        #expect(app.worktreeDeleteAction == .keepWorktree)
        HostSettingsMapping.apply(.slashCommand(name: "review", on: false), to: app)
        #expect(app.hiddenSlashCommands == ["review"])
        HostSettingsMapping.apply(.slashCommand(name: "review", on: true), to: app)
        #expect(app.hiddenSlashCommands.isEmpty)
        #expect(HostSettingsMapping.apply(.slashCommand(name: "", on: false), to: app) != nil)
        let commands = [NativeCommand(name: "review")]
        let settings = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil, slashCommands: commands)
        #expect(settings.slashCommands == commands)
    }

    /// A client's MCP sign-in ends with the address its browser landed on: only pi's own loopback
    /// redirect, with its state, is ever requested on the host.
    @Test func onlyTheLoopbackRedirectPiAskedForIsRelayed() throws {
        let authorization = try #require(URL(string: "https://mcp.linear.app/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A8123%2Fcallback&state=abc"))
        #expect(RemoteSignIns.callback("http://127.0.0.1:8123/callback?code=1&state=abc", for: authorization)?.absoluteString
                == "http://127.0.0.1:8123/callback?code=1&state=abc")
        for wrong in ["http://127.0.0.1:8123/callback?code=1&state=xyz", "http://127.0.0.1:9999/callback?code=1&state=abc",
                      "http://127.0.0.1:8123/other?code=1&state=abc", "http://evil.example:8123/callback?code=1&state=abc",
                      "https://127.0.0.1:8123/callback?code=1&state=abc", "http://127.0.0.1:8123/callback?code=1", "code"] {
            #expect(RemoteSignIns.callback(wrong, for: authorization) == nil, "\(wrong)")
        }
    }

    @Test func aClientsKeyIsAVariableOnlyWhenItNamesOne() throws {
        #expect(try HostConfigMapping.keyInput(" $OPENAI_API_KEY ") == .variable("OPENAI_API_KEY"))
        #expect(try HostConfigMapping.keyInput("sk-$abc") == .literal("sk-$abc"))
        #expect(try HostConfigMapping.keyInput("$not a name") == .literal("$not a name"))
        #expect(throws: RemoteCreateAgentError.self) { try HostConfigMapping.keyInput("  ") }
    }

    /// One server from a client: its secrets become Keychain references, never values in the file.
    @Test func aClientsServerKeepsItsSecretsAsReferences() throws {
        let entry = try HostConfigMapping.entry(#"{"mcpServers":{"gh":{"url":"https://x.dev/mcp","headers":{"X-Key":"typed"}}}}"#,
                                                secrets: ["X-Key": "s3cret"])
        #expect(entry.name == "gh" && entry.headers["X-Key"] == "${keychain:gh/X-Key}")
        #expect(throws: RemoteCreateAgentError.self) {
            try HostConfigMapping.entry(#"{"mcpServers":{"gh":{"url":"https://x.dev/mcp"}}}"#, secrets: ["MISSING": "v"])
        }
        #expect(throws: RemoteCreateAgentError.self) {
            try HostConfigMapping.entry(#"{"mcpServers":{"a":{"command":"x"},"b":{"command":"y"}}}"#, secrets: [:])
        }
    }

    /// A remote read never carries a value written literally into the host's file: references and
    /// an auth scheme before one stay, anything else is masked.
    @Test func aRemoteReadMasksLiteralValues() throws {
        #expect(HostConfigMapping.masked("${keychain:gh/TOKEN}") == "${keychain:gh/TOKEN}")
        #expect(HostConfigMapping.masked("${GITHUB_TOKEN}") == "${GITHUB_TOKEN}")
        #expect(HostConfigMapping.masked("Bearer ${keychain:gh/Authorization}") == "Bearer ${keychain:gh/Authorization}")
        #expect(HostConfigMapping.masked("") == "")
        for literal in ["ghp_live123", "Bearer ghp_live123", "x ${VAR}", "debug"] {
            #expect(HostConfigMapping.masked(literal) == HostConfigMapping.mask, "\(literal)")
        }
        var entry = MCPServerEntry.local("pg", command: "uvx", env: ["DATABASE_URI": "postgres://u:hunter2@db", "REF": "${keychain:pg/REF}"])
        entry.json["shepherd"] = .object(["enabled": .bool(false)])
        let json = HostConfigMapping.maskedJSON(entry)
        #expect(!json.contains("hunter2") && json.contains(HostConfigMapping.mask) && json.contains("${keychain:pg/REF}"))
        #expect(!json.contains("shepherd"))

        // A save that carries the mask keeps the host's value; one with nothing to keep is refused.
        let kept = try HostConfigMapping.entry(json, secrets: [:], existing: entry)
        #expect(kept.env["DATABASE_URI"] == "postgres://u:hunter2@db" && kept.env["REF"] == "${keychain:pg/REF}")
        #expect(throws: RemoteCreateAgentError.self) { try HostConfigMapping.entry(json, secrets: [:], existing: nil) }
        let typed = try HostConfigMapping.entry(json.replacingOccurrences(of: HostConfigMapping.mask, with: "postgres://new"), secrets: [:], existing: entry)
        #expect(typed.env["DATABASE_URI"] == "postgres://new")
    }

    /// A provider's saved accounts reach a client by opaque id and name, with rotation; one
    /// account alone sends none.
    @Test func aProvidersAccountsReachAClientWithoutCredentials() {
        let list = PiAccountList(accounts: [PiAccount(id: "a1", name: "work"), PiAccount(id: "a2", name: "home", limitedUntil: Date(timeIntervalSince1970: 2_000_000_000))],
                                 active: "a1", rotate: true)
        var row = ProviderRowModel(id: "anthropic", name: "Anthropic", badge: "Subscription", auth: .signedIn(plan: "Claude Pro or Max"))
        row.accounts = list
        let status = HostInventoryMapping.provider(row)
        #expect(status.accountList == [HostProviderAccount(id: "a1", name: "work", active: true),
                                      HostProviderAccount(id: "a2", name: "home", active: false, limitedUntil: 2_000_000_000)])
        #expect(status.rotate == true && status.activeAccount == "work")
        row.accounts = PiAccountList(accounts: [PiAccount(id: "a1", name: "work")], active: "a1", rotate: false)
        #expect(HostInventoryMapping.provider(row).accountList == nil)
    }

    /// The host's own words for a server's sign-in name no machine: a client may be another Mac.
    @Test func aServersSignInColumnIsHostNeutral() {
        #expect(HostInventoryMapping.signIn(.signIn) == "Not signed in")
        #expect(HostInventoryMapping.signIn(.expired) == "Expired")
    }
}
