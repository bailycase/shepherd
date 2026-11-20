import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import SwiftUI

/// The configured OAuth servers for this specific space and paired host.
struct SpaceMCP: View {
    let hostID: UUID
    let directory: String
    let files: [ProjectFile]
    @Environment(MobileHosts.self) private var hosts
    @State private var browser = MobileMCPBrowser()
    @State private var servers: [Server] = []
    @State private var active: Server.ID?
    @State private var authTask: Task<Void, Never>?
    @State private var problem: String?

    private struct Server: Identifiable {
        struct ID: Hashable { let file: String; let name: String }
        let id: ID
        let endpoint: String
        var signedIn: Bool
    }

    private var host: MobileHost? { hosts.host(hostID) }

    #if DEBUG
    static var fixtureServer: String?
    #endif

    var body: some View {
        content.task(id: files) { await load() }
    }

    @ViewBuilder private var content: some View {
        if !servers.isEmpty || problem != nil {
            SettingsSection("MCP sign-in") {
                if !servers.isEmpty {
                    SHLazyListCard(servers) { server in
                        HStack(spacing: SH.Space.m) {
                            SHListRow(server.id.name, subtitle: subtitle(for: server),
                                      subtitleMono: false, chevron: false)
                            if active == server.id {
                                Button("Cancel") { authTask?.cancel() }
                                    .buttonStyle(.sh(.secondary, size: .l))
                                    .padding(.trailing, SH.Space.l)
                            } else if !server.signedIn {
                                Button("Sign in") { signIn(server.id) }
                                    .buttonStyle(.sh(.secondary, size: .l))
                                    .disabled(active != nil || host?.connectedClient == nil)
                                    .padding(.trailing, SH.Space.l)
                            }
                        }
                    }
                }
                if let problem { SettingsFootnote(problem, tone: .failed) }
                SettingsFootnote("Credentials stay on the host.")
            }
            .background { MobileMCPBrowserAnchor(browser: browser).allowsHitTesting(false) }
        }
    }

    private func subtitle(for server: Server) -> String {
        if active == server.id { return host?.connectedClient == nil ? "Waiting for host…" : "Signing in…" }
        return server.signedIn ? "Signed in · \(server.endpoint)" : server.endpoint
    }

    private func load() async {
        guard let client = host?.connectedClient, client.supports(.projectMCP) else { return }
        do {
            var found: [Server] = []
            for file in files where file.category == .mcp && file.exists {
                guard case .text(let value) = try await client.projects(.read(directory: directory, file: file.path)),
                      let text = value.text,
                      let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      let entries = json["mcpServers"] as? [String: [String: Any]] else { continue }
                let credentials = try await send(file.path, .credentials)
                for name in entries.keys.sorted() {
                    guard let entry = entries[name], let address = entry["url"] as? String, let url = URL(string: address),
                          ["https", "http"].contains(url.scheme), let endpoint = url.host,
                          !((entry["headers"] as? [String: Any]) ?? [:]).keys.contains(where: { $0.lowercased() == "authorization" }) else { continue }
                    found.append(.init(id: .init(file: file.path, name: name), endpoint: endpoint,
                                       signedIn: credentials.signedIn.contains(name)))
                }
            }
            guard !Task.isCancelled else { return }
            servers = found
            #if DEBUG
            if let name = Self.fixtureServer, let server = found.first(where: { $0.id.name == name }) {
                Self.fixtureServer = nil
                signIn(server.id)
            }
            #endif
        } catch {
            if !Task.isCancelled { problem = message(error) }
        }
    }

    private func signIn(_ server: Server.ID) {
        guard active == nil else { return }
        active = server
        problem = nil
        // A view disappearing is not a cancellation. The request always resolves the same
        // host's current connection, and the user can cancel here or in the browser.
        authTask = Task {
            defer { active = nil; authTask = nil }
            do {
                try await ClientSpaceMCPSignIn.run(server: server.name, send: { try await send(server.file, $0) },
                                                  authorize: browser.authorize)
                if let index = servers.firstIndex(where: { $0.id == server }) { servers[index].signedIn = true }
            } catch is CancellationError {
            } catch {
                problem = message(error)
            }
        }
    }

    private func send(_ file: String, _ action: ProjectMCPAction) async throws -> ProjectMCPResult {
        guard let client = host?.connectedClient else { throw RemoteHostClientError.disconnected }
        guard case .mcp(let result) = try await client.projects(.mcp(directory: directory, file: file, action: action)) else {
            throw ProjectFileError("protocol", "Unexpected space MCP reply.")
        }
        return result
    }

    private func message(_ error: any Error) -> String {
        if let error = error as? ProjectFileError { return error.description }
        if let error = error as? MCPCallbackError { return error.description }
        if let error = error as? LocalizedError, let reason = error.errorDescription { return reason }
        return settingsProblem(error)
    }
}
