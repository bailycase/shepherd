import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Home track's settings and hosts screens.
extension FixtureCatalog {
    static var settings: [FixtureScreen] {
        [
            FixtureScreen(name: "settings", routes: [.settings(.root)], tab: .settings),
            FixtureScreen(name: "appearance", routes: [.settings(.appearance)], tab: .settings),
            FixtureScreen(name: "notifications", routes: [.settings(.notifications)], tab: .settings),
            // NotifSettings: Send me, Which device, and each mission still going.
            FixtureScreen(name: "notifications-missions", hosts: MissionsFixtureData.hosts(), routes: [.settings(.notifications)],
                          tab: .settings, prepare: { app in
                for host in app.hosts.hosts where host.servesMissions { await host.missions.refresh() }
                await app.push.setPreferences(RemotePushPreferences(missions: [MissionsFixtureData.question.rawValue: .onlyBlocked,
                                                                               MissionsFixtureData.running.rawValue: .onlyFailures]),
                                              hosts: app.hosts.hosts)
            }),
            // Threads muted from their long-press menus, found again here with Unmute.
            FixtureScreen(name: "notifications-muted", hosts: FixtureData.mutedThreads(), routes: [.settings(.notifications)], tab: .settings),
            FixtureScreen(name: "diagnostics", routes: [.settings(.diagnostics)], tab: .settings),
            // Hosts became Fleet (`fleet`, `fleet-off`, `fleet-forget`): a paired host's form is no longer reachable.
            // Add a Mac: the Macs Bonjour found, the code half entered, and the ways it can go wrong.
            FixtureScreen(name: "addhost", routes: [.settings(.fleet), .settings(.host(nil))], tab: .settings,
                          setup: { FixtureData.pairing(code: "4829") }),
            FixtureScreen(name: "addhost-sheet", presented: .settings(.host(nil)), setup: { FixtureData.pairing(code: "4829") }),
            FixtureScreen(name: "addhost-refused", routes: [.settings(.fleet), .settings(.host(nil))], tab: .settings,
                          setup: { FixtureData.pairing(code: "482913", failure: "That code isn't right. 4 tries left.") }),
            FixtureScreen(name: "addhost-none", routes: [.settings(.fleet), .settings(.host(nil))], tab: .settings,
                          setup: { FixtureData.pairing(found: [], code: "") }),
            // Each host's own settings (hostSettings.v1).
            FixtureScreen(name: "settings-defaults", routes: [.settings(.defaults)], tab: .settings),
            FixtureScreen(name: "settings-worktrees", routes: [.settings(.worktrees)], tab: .settings),
            // Its lower half: Deleting, with Close threads when their pull request merges.
            FixtureScreen(name: "settings-worktrees-lower", routes: [.settings(.worktrees)], tab: .settings,
                          prepare: { _ in await TriggerFlowCheck.scrollDown(holding: nil) }),
            FixtureScreen(name: "settings-pi", routes: [.settings(.piExtensions)], tab: .settings),
            // Root instructions, the fleet's (instructions.v1): one copy, no host to pick.
            FixtureScreen(name: "settings-instructions", routes: [.settings(.instructions)], tab: .settings),
            FixtureScreen(name: "settings-instructions-edit", routes: [.settings(.instructions), .settings(.instructionsFile(.agents))],
                          tab: .settings, prepare: { app in await FixtureData.draft(app, .agents, adding: "- Always run `sqlc vet` after a query change.") }),
            // No Mac to read them from: "Add a Mac in Settings ▸ Fleet to start."
            FixtureScreen(name: "settings-instructions-empty", hosts: [], routes: [.settings(.instructions)], tab: .settings),
            // Agent skills on every host (skills.v1): the list, pdf's detail with its update,
            // and a repository's skills to pick from.
            FixtureScreen(name: "settings-skills", routes: [.settings(.skills)], tab: .settings),
            FixtureScreen(name: "settings-skill", routes: [.settings(.skills), .settings(.skill("pdf"))], tab: .settings),
            FixtureScreen(name: "settings-skills-repo", hosts: FixtureData.skillsRepoHosts(),
                          routes: [.settings(.skills), .settings(.skillsRepo("anthropics/skills"))], tab: .settings),
            // Suggested instructions on every host (suggestions.v1).
            FixtureScreen(name: "settings-experiments", hosts: FixtureData.suggestingHosts(), routes: [.settings(.experiments)], tab: .settings),
            FixtureScreen(name: "settings-experiments-off", routes: [.settings(.experiments)], tab: .settings),
            FixtureScreen(name: "settings-suggestion", hosts: FixtureData.suggestingHosts(),
                          routes: [.settings(.experiments), .settings(.suggestion(FixtureData.joinKeys))], tab: .settings),
            // The iPad's list beside a page (iPadSettingsInstructions).
            FixtureScreen(name: "settings-pad-instructions", routes: [.settings(.root)], tab: .settings, prepare: { app in
                app.navigator.settingsSelection.page = .instructions
                await FixtureData.draft(app, .agents, adding: "- Prefer a draft PR over a long explanation.")
            }),
            FixtureScreen(name: "settings-pad-experiments", hosts: FixtureData.suggestingHosts(), routes: [.settings(.root)], tab: .settings,
                          prepare: { app in app.navigator.settingsSelection.page = .experiments }),
            FixtureScreen(name: "settings-pad-skills", routes: [.settings(.root)], tab: .settings,
                          prepare: { app in app.navigator.settingsSelection.page = .skills }),
        ]
    }
}

extension FixtureData {
    /// Add a Mac's seams: the Macs Bonjour found, and a code (and refusal) already on the screen.
    @MainActor static func pairing(found: [FoundMac] = [
        FoundMac(id: "mini", name: "Mac mini", version: "1.9", idHash: "aaaaaaaaaaaaaaaa", address: "192.168.1.52", port: 7434),
        FoundMac(id: "studio", name: "Mac Studio", version: "1.9", idHash: "bbbbbbbbbbbbbbbb", address: "192.168.1.60", port: 7434),
    ], code: String, failure: String? = nil) {
        MobilePairing.source = { update in update(found); return {} }
        MobilePairing.seed = { model in
            model.picked = found.first?.id
            model.code = code
            if let failure { model.phase = .failed(failure) }
        }
    }

    /// The usual hosts, with the studio's background service turned off in Login Items.
    /// Two of the studio's threads muted on the host (`Agent.pushMuted`).
    static func mutedThreads() -> [FixtureHostData] {
        hosts().map { host in
            var host = host
            if host.id == studio { for index in host.state.agents.indices.prefix(2) { host.state.agents[index].pushMuted = true } }
            return host
        }
    }

    static func serviceOff() -> [FixtureHostData] {
        hosts().map { host in
            var host = host
            if host.id == studio { host.hostSettings?.backgroundService = false }
            return host
        }
    }

    /// The given hosts (the usual ones by default), with the laptop up but refusing the phone's token.
    static func refusingLaptop(_ hosts: [FixtureHostData] = hosts()) -> [FixtureHostData] {
        hosts.map { host in
            var host = host
            if host.id == laptop {
                host.online = true
                host.refusesToken = true
            }
            return host
        }
    }

    /// A host's settings, as a Mac with Shepherd's defaults answers them.
    static func hostSettings(pi: String = "0.87.1") -> HostSettings {
        HostSettings(
            shepherdVersion: "0.4.2", piVersion: pi, defaultModel: "anthropic/claude-opus", defaultThinking: .medium,
            queueDelivery: .all, mergePRAutomatically: true, mergeMethod: .squash, closeOnMerge: true, backgroundService: true,
            bundledExtensions: [
                HostSettings.BundledExtension(id: "panes", name: "Panes and agent tools", on: true),
                HostSettings.BundledExtension(id: "review", name: "Diff review tool", on: true),
                HostSettings.BundledExtension(id: "nativeSubagents", name: "Native subagents", on: false),
                HostSettings.BundledExtension(id: "subagents", name: "Subagent display", on: true),
            ],
            installedExtensions: ["npm:@example/pi-tools@1.0.0", "~/pi/checks.ts"],
            updatePiDaily: true
        )
    }

    /// The root instructions every fixture host keeps (MobileInstructionsEdit,
    /// iPadSettingsInstructions).
    static func instructions(agents: String = agentsFile) -> InstructionsSnapshot {
        InstructionsSnapshot(
            agents: agents, appendSystem: appendSystemFile, directory: "~/Library/Application Support/Shepherd/instructions",
            history: [
                InstructionHistoryEntry(id: UUID(uuidString: "1A5E0000-0000-4000-8000-000000000001")!, file: .agents,
                                        savedAt: start / 1000 - 7_200, summary: "Added “Migrations are reversible.”", origin: "iPhone"),
                InstructionHistoryEntry(id: UUID(uuidString: "1A5E0000-0000-4000-8000-000000000002")!, file: .agents,
                                        savedAt: start / 1000 - 180_000, summary: "Synced from Studio", origin: "Studio"),
            ]
        )
    }

    static let agentsFile = """
        # How I work

        ## Stack
        - Go 1.23 services that talk gRPC. Protos live in `contracts` and go through buf.
        - Kafka for events, always through the transactional outbox.
        - Postgres with sqlc. No hand-written SQL in Go files.
        - Web UIs are Go templates and HTMX. No SPA frameworks.

        ## Before you say you're done
        - `go test ./...` and `buf lint` pass.
        - Migrations are reversible.
        - Small commits, imperative subjects, no emoji.

        """

    static let appendSystemFile = """
        Never push to main or force-push. Open a PR instead.
        Never print or commit anything from .env files.
        Ask before running a migration against anything but a local or throwaway database.
        Keep replies short. Lead with what changed.

        """

    /// The suggestion the detail screen opens.
    static let joinKeys = UUID(uuidString: "5A660000-0000-4000-8000-000000000001")!

    /// The usual hosts with Suggested instructions on and lines waiting on two of them
    /// (MobileExperiments).
    static func suggestingHosts() -> [FixtureHostData] {
        let now = start / 1000
        let on = SuggestedInstructionsSettings(enabled: true, since: now - 1_000_000)
        return hosts().map { host in
            var host = host
            switch host.id {
            case studio:
                host.suggestions = SuggestionsSnapshot(settings: on, waiting: [
                    InstructionSuggestion(id: joinKeys, line: "- Ask for join keys before adding an event.",
                                          reason: "The funnel query double-counted until the event carried the session and order ids.",
                                          file: .agents, source: SuggestionSource(kind: .thread, name: "Checkout funnel events"),
                                          suggestedAt: now - 600),
                    InstructionSuggestion(line: "- Don't skip or retry a flaky test; find the race.",
                                          reason: "The ledger test failed twice before the shared clock turned up.",
                                          file: .agents, source: SuggestionSource(kind: .thread, name: "Fix flaky ledger test"),
                                          suggestedAt: now - 86_400),
                ])
            case buildBox:
                host.suggestions = SuggestionsSnapshot(settings: on, waiting: [
                    InstructionSuggestion(line: "- Run `go mod tidy` and commit go.sum with any dependency bump.",
                                          reason: "CI failed on a stale go.sum.",
                                          file: .agents, source: SuggestionSource(kind: .automation, name: "Nightly dependency bump"),
                                          suggestedAt: now - 3_600),
                ])
            default:
                break
            }
            return host
        }
    }

    /// Reads every host's instructions, then leaves a draft of `file` with a line added, as the
    /// editor shows one being typed.
    @MainActor static func draft(_ app: MobileApp, _ file: InstructionFile, adding line: String) async {
        let store = SettingsStore.of(app.hosts)
        await store.refresh()
        let text = store.instructions.text(file, in: store.hosts)
        store.instructions.setText(text + line + "\n", file: file, in: store.hosts)
    }
}
