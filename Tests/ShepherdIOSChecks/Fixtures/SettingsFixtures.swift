import Foundation
import ShepherdCore
import ShepherdProtocol

// Home track's settings and hosts screens.
extension FixtureCatalog {
    static var settings: [FixtureScreen] {
        [
            FixtureScreen(name: "settings", routes: [.settings(.root)], tab: .settings),
            FixtureScreen(name: "appearance", routes: [.settings(.appearance)], tab: .settings),
            FixtureScreen(name: "hosts", routes: [.settings(.hosts)], tab: .settings),
            FixtureScreen(name: "host", routes: [.settings(.hosts), .settings(.host(FixtureData.studio))], tab: .settings),
            FixtureScreen(name: "host-offline", routes: [.settings(.hosts), .settings(.host(FixtureData.laptop))], tab: .settings),
            FixtureScreen(name: "hosts-refused", hosts: FixtureData.refusingLaptop(), routes: [.settings(.hosts)], tab: .settings),
            FixtureScreen(name: "host-refused", hosts: FixtureData.refusingLaptop(),
                          routes: [.settings(.hosts), .settings(.host(FixtureData.laptop))], tab: .settings),
            FixtureScreen(name: "addhost", routes: [.settings(.hosts), .settings(.host(nil))], tab: .settings),
            FixtureScreen(name: "addhost-sheet", presented: .settings(.host(nil))),
            // Each host's own settings (hostSettings.v1).
            FixtureScreen(name: "settings-defaults", routes: [.settings(.defaults)], tab: .settings),
            FixtureScreen(name: "settings-worktrees", routes: [.settings(.worktrees)], tab: .settings),
            FixtureScreen(name: "settings-pi", routes: [.settings(.piExtensions)], tab: .settings),
            // Root instructions on every host (instructions.v1).
            FixtureScreen(name: "settings-instructions", routes: [.settings(.instructions)], tab: .settings),
            FixtureScreen(name: "settings-instructions-edit", routes: [.settings(.instructions), .settings(.instructionsFile(.agents))],
                          tab: .settings, prepare: { app in await FixtureData.draft(app, .agents, adding: "- Always run `sqlc vet` after a query change.") }),
            FixtureScreen(name: "settings-instructions-differ", hosts: FixtureData.differingBuildBox(), routes: [.settings(.instructions)],
                          tab: .settings),
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
                SettingsStore.of(app.hosts).page = .instructions
                await FixtureData.draft(app, .agents, adding: "- Prefer a draft PR over a long explanation.")
            }),
            FixtureScreen(name: "settings-pad-experiments", hosts: FixtureData.suggestingHosts(), routes: [.settings(.root)], tab: .settings,
                          prepare: { app in SettingsStore.of(app.hosts).page = .experiments }),
            FixtureScreen(name: "settings-pad-skills", routes: [.settings(.root)], tab: .settings,
                          prepare: { app in SettingsStore.of(app.hosts).page = .skills }),
        ]
    }
}

extension FixtureData {
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
            queueDelivery: .all, mergePRAutomatically: true, mergeMethod: .squash,
            bundledExtensions: [
                HostSettings.BundledExtension(id: "namer", name: "Name agents automatically", on: true),
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

    /// The usual hosts, with build-01's AGENTS.md two lines apart.
    static func differingBuildBox() -> [FixtureHostData] {
        hosts().map { host in
            var host = host
            if host.id == buildBox {
                host.instructions = instructions(agents: agentsFile.replacingOccurrences(of: "- Migrations are reversible.\n", with: "")
                    + "- Use docker compose for local services.\n")
            }
            return host
        }
    }

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
