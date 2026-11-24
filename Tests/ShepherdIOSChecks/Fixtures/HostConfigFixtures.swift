import Foundation
import ShepherdCore
import ShepherdProtocol

// Settings for a host's configuration, changed from the phone (`hostSettings.v2`,
// `hostConfig.v1`): Experiments per host, Subagent defaults, MCP servers and their editor, a
// subagent profile's editor, and Sign-in with saved accounts. Every screen only reads; the
// fixture host refuses any change.
extension FixtureCatalog {
    static var hostConfig: [FixtureScreen] {
        [
            FixtureScreen(name: "settings-experiments-hosts", hosts: FixtureData.configuredHosts(), routes: [.settings(.experiments)], tab: .settings),
            FixtureScreen(name: "settings-agents-subagents", hosts: FixtureData.configuredHosts(), routes: [.settings(.agents)], tab: .settings),
            // Agents' foot: the Subagents card ends with Profiles, which opens them.
            FixtureScreen(name: "settings-agents-profiles", hosts: FixtureData.configuredHosts(), routes: [.settings(.agents)], tab: .settings,
                          prepare: { _ in await TriggerFlowCheck.scrollDown(holding: nil) }),
            FixtureScreen(name: "settings-mcp", hosts: FixtureData.configuredHosts(), routes: [.settings(.tools)], tab: .settings),
            // Tools' Extensions: the pi extensions added in Shepherd or copied from the host's pi, each with its switch.
            FixtureScreen(name: "settings-extensions", hosts: FixtureData.configuredHosts(), routes: [.settings(.tools)], tab: .settings,
                          prepare: { _ in await TriggerFlowCheck.scrollDown(holding: nil) }),
            // Its two dialogs: Add from a Git repository, and Remove…'s confirmation.
            FixtureScreen(name: "settings-extensions-add", hosts: FixtureData.configuredHosts(), routes: [.settings(.tools)], tab: .settings,
                          prepare: { app in
                              await TriggerFlowCheck.scrollDown(holding: nil)
                              SettingsStore.of(app.hosts).addingExtension = true
                          }),
            FixtureScreen(name: "settings-extensions-remove", hosts: FixtureData.configuredHosts(), routes: [.settings(.tools)], tab: .settings,
                          prepare: { app in
                              await TriggerFlowCheck.scrollDown(holding: nil)
                              SettingsStore.of(app.hosts).removingExtension = HostExtension(
                                  id: "your-extensions/added/acme-login", name: "acme-login", subtitle: "", on: true, added: true)
                          }),
            FixtureScreen(name: "settings-mcp-editor", hosts: FixtureData.configuredHosts(), routes: [.settings(.tools)], tab: .settings,
                          prepare: { app in
                              SettingsStore.of(app.hosts).mcpEditor = MCPEditor(replacing: "postgres", json: FixtureData.postgresJSON)
                          }),
            FixtureScreen(name: "settings-subagents", hosts: FixtureData.configuredHosts(), routes: [.settings(.subagents)], tab: .settings),
            FixtureScreen(name: "settings-subagent-edit", hosts: FixtureData.configuredHosts(),
                          routes: [.settings(.subagents), .settings(.subagent("reviewer.md"))], tab: .settings),
            FixtureScreen(name: "settings-signin-accounts", hosts: FixtureData.configuredHosts(), routes: [.settings(.models)], tab: .settings),
        ]
    }
}

extension FixtureData {
    /// Studio as a current Shepherd: Goals on, the Design tool off, Subagent defaults set, and
    /// an inventory of servers, profiles and accounts.
    static func configuredHosts() -> [FixtureHostData] {
        hosts().map { host in
            var host = host
            guard host.id == studio else { return host }
            var settings = hostSettings()
            settings.goalsEnabled = true
            settings.subagentDefaults = HostSettings.SubagentDefaults(concurrency: 6, model: "anthropic/claude-sonnet", thinking: .low, context: .fork)
            host.hostSettings = settings
            host.reply = { request in
                guard case .hostInventory(let id, let inventory) = request else { return nil }
                return .hostInventory(id: id, result: FixtureData.inventory(inventory))
            }
            return host
        }
    }

    static func inventory(_ request: RemoteHostInventoryRequest) -> RemoteHostInventoryResult {
        switch request {
        case .mcp:
            return .mcp(HostMCPInventory(servers: [
                HostMCPServer(name: "linear", kind: .remote, endpoint: "https://mcp.linear.app/mcp", status: .connected, signIn: "Signed in",
                              tools: 23, exposure: .proxy, oauth: true, signedIn: true),
                HostMCPServer(name: "sentry", kind: .remote, endpoint: "https://mcp.sentry.dev/mcp", status: .needsYou, signIn: "Not signed in",
                              exposure: .proxy, oauth: true, signedIn: false),
                HostMCPServer(name: "postgres", kind: .local, endpoint: "uvx postgres-mcp --access-mode=restricted", status: .error,
                              note: "connection refused", signIn: "DATABASE_URI in Keychain", enabled: false, exposure: .direct),
            ], configPath: "~/Library/Application Support/Shepherd/mcp.json", checkedAt: start / 1000 - 300))
        case .subagents:
            return .subagents([
                HostSubagentProfile(file: "reviewer.md", name: "reviewer", description: "Reviews a diff for correctness.", tools: ["read", "grep"],
                                    isDefault: true, fingerprint: "ab12"),
                HostSubagentProfile(file: "team/scout.md", name: "scout", description: "Finds the code a task touches.", context: "fork"),
            ])
        case .subagent(let file):
            return .subagent(HostSubagentProfileText(file: file, text: reviewerProfile, fingerprint: "ab12"))
        case .providers:
            return .providers([
                HostProviderStatus(id: "anthropic", name: "Anthropic", badge: "Subscription", auth: .signedIn, detail: "Claude Pro or Max",
                                   accounts: 2, activeAccount: "work",
                                   accountList: [HostProviderAccount(id: "a1", name: "work", active: true),
                                                 HostProviderAccount(id: "a2", name: "personal", active: false)],
                                   rotate: true),
                HostProviderStatus(id: "openai-codex", name: "OpenAI Codex", badge: "Subscription", auth: .notSignedIn, detail: "ChatGPT Plus or Pro"),
                HostProviderStatus(id: "deepseek", name: "DeepSeek", badge: "API key", auth: .apiKey, detail: "$DEEPSEEK_API_KEY",
                                   balance: HostBalance(amount: 110, currency: "CNY")),
                HostProviderStatus(id: "acme", name: "Acme", badge: "Subscription", auth: .signedIn, detail: "Acme account · from acme-login",
                                   usage: [HostUsageWindow(name: "Month", usedPercent: 42)],
                                   balance: HostBalance(amount: 18.4, currency: "USD", label: "Credit")),
            ])
        case .extensions:
            return .extensions([
                HostExtension(id: "your-extensions/added/acme-login", name: "acme-login",
                              subtitle: "Adds Acme sign-in, /acme-usage · Added from https://github.com/acme/pi-login", on: true, added: true,
                              support: .works, supportDetail: "Everything it registered works in Shepherd."),
                HostExtension(id: "your-extensions/added/acme-footer", name: "acme-footer",
                              subtitle: "Adds 1 event hook · Not shown in Shepherd: footer or header · Added from ~/code/acme-footer", on: true, added: true,
                              support: .partly, supportDetail: "Its code uses terminal UI Shepherd may not show: footer or header."),
                HostExtension(id: "your-extensions/added/acme-tools", name: "acme-tools", subtitle: "Added from ~/code/acme-tools", on: true,
                              failure: "Cannot find module 'acme-sdk'", added: true),
                HostExtension(id: "your-extensions/review.ts", name: "review", subtitle: "From your pi · extensions/review.ts", on: false),
            ])
        }
    }

    static let reviewerProfile = """
        ---
        name: reviewer
        description: Reviews a diff for correctness.
        tools: [read, grep, find, ls]
        ---
        Review the assigned patch for correctness, then for clarity. Report findings with file and line.

        """

    static let postgresJSON = """
        {
          "mcpServers": {
            "postgres": {
              "command": "uvx",
              "args": ["postgres-mcp", "--access-mode=restricted"],
              "env": { "DATABASE_URI": "${keychain:postgres/DATABASE_URI}", "PGAPPNAME": "••••••••" }
            }
          }
        }
        """
}
