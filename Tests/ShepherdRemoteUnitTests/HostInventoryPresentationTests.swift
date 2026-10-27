import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// Settings ▸ MCP, Subagents, Sign-in and Spaces on the iPhone and the iPad say what the host's
/// inventory says, in the Mac's words, and point to the Mac for what they can't do.
@Suite("Host inventory presentation")
struct HostInventoryPresentationTests {
    typealias P = HostInventoryPresentation

    @Test func mcpRowsAndValue() {
        let github = HostMCPServer(name: "github", kind: .remote, endpoint: "https://api.githubcopilot.com/mcp/", status: .connected, tools: 12)
        let postgres = HostMCPServer(name: "postgres", kind: .local, endpoint: "npx server-postgres", status: .error, note: "connection refused", tools: nil)
        let off = HostMCPServer(name: "old", kind: .remote, endpoint: "https://example.invalid", status: .off, enabled: false)
        #expect(P.serverLine(github) == "https://api.githubcopilot.com/mcp/ · 12 tools")
        #expect(P.serverLine(postgres) == "connection refused")
        #expect(P.serverLine(HostMCPServer(name: "x", kind: .local, endpoint: "cmd", status: .idle, tools: 1)) == "cmd · 1 tool")
        #expect(P.tone(.connected) == .done && P.tone(.needsYou) == .attention && P.tone(.error) == .failed && P.tone(.off) == .idle)
        #expect(P.statusWord(.idle) == "Not checked yet")
        #expect(P.mcpValue(HostMCPInventory(servers: [github, postgres, off], configPath: "~/mcp.json")) == "2 · 1 needs you")
        #expect(P.mcpValue(HostMCPInventory(servers: [github, off], configPath: "~/mcp.json")) == "1")
        #expect(P.mcpValue(HostMCPInventory(servers: [off], configPath: "~/mcp.json")) == "Off")
        #expect(P.mcpValue(HostMCPInventory(servers: [], configPath: "~/mcp.json")) == "None")
        #expect(P.mcpGuidance(host: "studio", configPath: "~/mcp.json").contains("Settings ▸ MCP on studio"))
    }

    @Test func subagentRowsSayWhatTheMacsListSays() {
        let scout = HostSubagentProfile(file: "scout.md", name: "scout", description: "Finds things.", tools: ["read", "grep"], context: "fork", isDefault: true)
        let worker = HostSubagentProfile(file: "worker.md", name: "worker", description: "Edits.", tools: nil)
        let broken = HostSubagentProfile(file: "team/broken.md", name: "broken", error: "No front matter")
        let off = HostSubagentProfile(file: "off.md", name: "off", description: "Idle.", disabled: true)
        #expect(P.capability(scout) == "read-only · fork" && P.capability(worker) == "can edit")
        #expect(P.profileLine(scout) == "Finds things." && P.profileLine(broken) == "No front matter" && P.profileLine(off) == "Disabled")
        #expect(P.tone(scout) == .done && P.tone(broken) == .failed && P.tone(off) == .idle)
    }

    @Test func providerRowsNeverNeedAValueAndPointToTheMac() {
        let expired = HostProviderStatus(id: "anthropic", name: "Anthropic", badge: "Subscription", auth: .expired, detail: "Claude Pro or Max",
                                         accounts: 2, activeAccount: "work")
        let key = HostProviderStatus(id: "openai", name: "OpenAI", badge: "API key", auth: .apiKey, detail: "$OPENAI_API_KEY")
        let none = HostProviderStatus(id: "google", name: "Google", badge: "Subscription", auth: .notSignedIn)
        #expect(P.providerLine(expired) == "Expired · sign in on the Mac · Claude Pro or Max · 2 accounts · work")
        #expect(P.providerLine(key) == "API key · $OPENAI_API_KEY")
        #expect(P.providerLine(none) == "Not signed in")
        #expect(P.tone(.expired) == .attention && P.tone(.apiKey) == .done && P.tone(.notSignedIn) == .idle)
        #expect(P.providersValue([expired, key, none]) == "1 expired")
        #expect(P.providersValue([key, none]) == "1" && P.providersValue([none]) == "None")
        #expect(P.providersGuidance(host: "studio").contains("Settings ▸ Sign-in on studio"))
    }

    @Test func spaceRowsAndTrust() {
        let ready = ProjectSummary(directory: "/r", name: "repo", displayPath: "~/repo", summary: "AGENTS.md · 2 skills")
        let broken = ProjectSummary(directory: "/g", name: "gone", displayPath: "~/gone", summary: "directory unavailable", minimal: true, error: "not found")
        #expect(P.spaceLine(ready) == "AGENTS.md · 2 skills" && P.spaceLine(broken) == "not found")
        #expect(P.tone(ready) == .done && P.tone(broken) == .failed)
        #expect(P.trustWord(true) == "Approved on the Mac" && P.trustWord(false) == "Not yet approved" && P.trustWord(nil) == nil)
    }
}
