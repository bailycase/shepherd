import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Settings' host-level pages drawn for a remote host through the shared models
/// (`RemoteHostSettingsPage`), from a stand-in host that answers as a newer Shepherd would, and
/// from one too old to take changes. No network.
@Suite("Remote host settings previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR"))
@MainActor
struct RemoteHostSettingsPreviewTests {
    final class Host: SettingsClient, @unchecked Sendable {
        let settings = HostSettings(
            shepherdVersion: "0.9.0", piVersion: "0.87.1", defaultModel: "anthropic/claude-opus-4", defaultThinking: .high,
            namingModel: nil, compactAtPercent: 80, goalsEnabled: true, projectsEnabled: false,
            designToolEnabled: false, missionsEnabled: true, missionsActive: true,
            subagentDefaults: HostSettings.SubagentDefaults(concurrency: 6, model: nil, thinking: .low, context: .fork),
            worktreeDeleteAction: .keepWorktree,
            slashCommands: [NativeCommand(name: "review", description: "Review the working tree"),
                            NativeCommand(name: "skill:pdf", description: "Read, fill and merge PDFs")],
            hiddenSlashCommands: ["skill:pdf"],
            bundledExtensions: [HostSettings.BundledExtension(id: "review", name: "Diff review tool", on: true),
                                HostSettings.BundledExtension(id: "designReferences", name: "Design references", on: false)])
        func skills(_ request: RemoteSkillsRequest) async throws -> RemoteSkillsResult { throw RemoteHostClientError.disconnected }
        func hostSettings(_ request: RemoteHostSettingsRequest) async throws -> HostSettings { settings }
        func instructions(_ request: RemoteInstructionsRequest) async throws -> InstructionsSnapshot { InstructionsSnapshot(directory: "~") }
        func suggestions(_ request: RemoteSuggestionsRequest) async throws -> SuggestionsSnapshot { SuggestionsSnapshot() }
        func hostInventory(_ request: RemoteHostInventoryRequest) async throws -> RemoteHostInventoryResult {
            switch request {
            case .providers:
                return .providers([HostProviderStatus(id: "anthropic", name: "Anthropic", badge: "Subscription", auth: .signedIn, detail: "Claude Pro or Max"),
                                   HostProviderStatus(id: "openai-codex", name: "OpenAI Codex", badge: "Subscription", auth: .notSignedIn, detail: "ChatGPT Plus or Pro"),
                                   HostProviderStatus(id: "openai", name: "OpenAI", badge: "API key", auth: .apiKey, detail: "$OPENAI_API_KEY")])
            case .subagents, .subagent:
                return .subagents([HostSubagentProfile(file: "reviewer.md", name: "reviewer", description: "Reviews a diff.", tools: ["read"], isDefault: true, fingerprint: "ab"),
                                   HostSubagentProfile(file: "team/scout.md", name: "scout", description: "Finds code.", context: "fork")])
            case .mcp:
                return .mcp(HostMCPInventory(servers: [
                    HostMCPServer(name: "linear", kind: .remote, endpoint: "https://mcp.linear.app/mcp", status: .connected, signIn: "Signed in",
                                  tools: 23, exposure: .proxy, oauth: true, signedIn: true),
                    HostMCPServer(name: "postgres", kind: .local, endpoint: "uvx postgres-mcp", status: .error, note: "connection refused",
                                  signIn: "DATABASE_URI in Keychain", enabled: false, exposure: .direct),
                ], configPath: "~/Library/Application Support/Shepherd/pi/mcp.json"))
            }
        }
        func hostConfig(_ request: RemoteHostConfigRequest) async throws -> RemoteHostConfigResult {
            .signIn(HostSignInProgress(id: UUID(), phase: .waiting, name: "OpenAI Codex", authorizationURL: "https://auth.openai.com/oauth", wantsCode: true))
        }
    }

    static let newer: Set<String> = [RemoteProtocol.hostSettingsCapability, RemoteProtocol.hostSettingsAgentDefaultsCapability,
                                     RemoteProtocol.hostSettingsV2Capability, RemoteProtocol.hostInventoryCapability,
                                     RemoteProtocol.hostConfigCapability, RemoteProtocol.goalExperimentCapability,
                                     RemoteProtocol.projectsExperimentCapability, RemoteProtocol.designToolExperimentCapability,
                                     RemoteProtocol.missionsExperimentCapability]
    static let older: Set<String> = [RemoteProtocol.hostSettingsCapability, RemoteProtocol.hostInventoryCapability,
                                     RemoteProtocol.goalExperimentCapability]

    @Test(arguments: [SettingsSection.experiments, .agents, .subagents, .worktrees, .extensions, .piSlashCommands, .mcp, .piSignIn])
    func aRemoteHostsPage(_ section: SettingsSection) async throws {
        for (label, capabilities) in [("newer", Self.newer), ("older", Self.older)] {
            let host = SettingsHost(id: UUID(), name: "studio", client: Host(), capabilities: capabilities)
            let settings = ClientHostSettings(), config = ClientHostConfig()
            await settings.refresh(host)
            for page in [ClientHostConfig.Page.mcp, .subagents, .providers] { await config.refresh(page, on: host) }
            if section == .piSignIn, label == "newer" { await config.perform(.providerSignIn(provider: "openai-codex"), on: host) }
            try await Preview.render("settings-remote-\(section.rawValue)-\(label)", size: CGSize(width: 900, height: 1100),
                                     ready: { settings.settings(of: host) != nil }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppLayout.settingsGroupSpacing) {
                        HStack(spacing: SH.Space.m) {
                            Text("Host").font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textSecondary)
                            SHPopupMenu("studio", minWidth: AppLayout.settingsPopupWidth) { Button("This Mac") {} }
                            Spacer(minLength: 0)
                        }
                        RemoteHostSettingsPage(section: section, host: host, settings: settings, config: config)
                    }
                    .padding(.top, AppLayout.settingsTop)
                    .padding(.horizontal, AppLayout.settingsWideSides)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.sh.bgWindow)
            }
        }
    }
}
