import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
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
        app.goalCrossProviderEvaluation = true
        app.goalsEnabled = true
        app.worktreeBaseMode = .head
        app.worktreeAutoMergePR = true
        app.worktreeMergeMethod = .rebase
        app.piReviewExtension = false
        let settings = HostSettingsMapping.settings(from: app, shepherdVersion: "0.4.2", piVersion: "0.87.1")
        #expect(settings.shepherdVersion == "0.4.2" && settings.piVersion == "0.87.1")
        #expect(settings.defaultModel == "anthropic/claude-opus")
        #expect(settings.defaultThinking == .high)
        #expect(settings.goalCrossProviderEvaluation && settings.goalsEnabled)
        #expect(settings.worktreeBase == .head)
        #expect(settings.mergePRAutomatically && settings.mergeMethod == .rebase)
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
        #expect(!app.goalCrossProviderEvaluation)
        HostSettingsMapping.apply(.goalCrossProviderEvaluation(true), to: app)
        #expect(app.goalCrossProviderEvaluation)
        HostSettingsMapping.apply(.goalCrossProviderEvaluation(false), to: app)
        #expect(!app.goalCrossProviderEvaluation)
        HostSettingsMapping.apply(.queueDelivery(.oneAtATime), to: app)
        #expect(app.queueDelivery == .oneAtATime)
        HostSettingsMapping.apply(.worktreeBase(.head), to: app)
        #expect(app.worktreeBaseMode == .head)
        HostSettingsMapping.apply(.mergeMethod(.merge), to: app)
        #expect(app.worktreeMergeMethod == .merge)
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
        HostSettingChange.defaultThinking(.low), .goalCrossProviderEvaluation(true), .goalCrossProviderEvaluation(false),
        .goalsEnabled(true), .goalsEnabled(false), .projectsEnabled(true), .projectsEnabled(false),
        .fetchBeforeCreating(false), .commitRemainingWork(false),
        .generatePRDescriptions(false), .deleteLocalBranch(false), .mergePRAutomatically(true),
        .bundledExtension(id: "review", on: false), .bundledExtension(id: "nativeSubagents", on: false), .bundledExtension(id: "context", on: false),
        .bundledExtension(id: "designReferences", on: false),
        .designToolEnabled(true), .missionsEnabled(true),
        .subagentDefaults(HostSettings.SubagentDefaults(concurrency: 9, model: "openai/gpt-5-mini", thinking: .high, context: .fork)),
        .worktreeDeleteAction(.removeWorktree), .skillsInSlashMenu(false), .mcpProjectConfig(true), .slashCommand(name: "review", on: false),
    ])
    func aChangeReadsBackAsTheProtocolAppliesIt(_ change: HostSettingChange) {
        let app = AppSettings(store: Fixture.defaults())
        var expected = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil)
        expected.apply(change)
        HostSettingsMapping.apply(change, to: app)
        #expect(HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil) == expected)
    }

    /// The Mac's own switches a client now reaches: Experiments, Subagent defaults, Worktrees,
    /// Skills, MCP and Slash commands land where Settings keeps them.
    @Test func aClientsHostLevelChangesLandInTheMacsSettings() {
        let app = AppSettings(store: Fixture.defaults())
        HostSettingsMapping.apply(.designToolEnabled(true), to: app)
        #expect(app.designToolEnabled)
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
        let settings = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil, missionsActive: true, slashCommands: commands)
        #expect(settings.missionsActive && settings.slashCommands == commands)
    }

    /// The Mac's card locks Missions on under a live mission; a client is refused the same, and
    /// may still turn it on.
    @Test func missionsCantBeTurnedOffWhileOneIsActive() {
        let app = AppSettings(store: Fixture.defaults())
        #expect(HostSettingsMapping.apply(.missionsEnabled(true), to: app, missionsActive: true) == nil)
        #expect(app.missionsEnabled)
        #expect(HostSettingsMapping.apply(.missionsEnabled(false), to: app, missionsActive: true) == HostSettingsMapping.missionsLocked)
        #expect(app.missionsEnabled)
        #expect(HostSettingsMapping.apply(.missionsEnabled(false), to: app, missionsActive: false) == nil)
        #expect(!app.missionsEnabled)
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
