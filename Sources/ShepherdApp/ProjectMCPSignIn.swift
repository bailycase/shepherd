import Foundation
import ShepherdProtocol
import ShepherdSessions

extension ProjectsModel {
    func refreshMCPCredentials() async {
        guard let selected, let file = selectedFile, selected.host.supportsMCP else { return }
        let identity = selected.id, contents = saved
        if case .mcp(let result) = try? await request(selected.host, .mcp(directory: selected.project.directory, file: file.path, action: .credentials)),
           self.selected?.id == identity, self.selected?.host.endpointID == selected.host.endpointID,
           selectedFile?.path == file.path, saved == contents {
            mcpSignedIn = Set(result.signedIn)
            deriveMCP()
        }
    }

    func beginMCPSignIn(_ name: String) {
        guard mcpEditable, !dirty, let selected, selected.host.supportsMCP, let file = selectedFile,
              let entry = mcp.entries.first(where: { $0.name == name }), ProjectMCPConfiguration.usesOAuth(entry),
              let url = entry.url.flatMap(URL.init(string:)) else { return }
        closeMCPSignIn()
        let flow = MCPSignInFlow(server: name, url: url,
            run: { [weak self] arguments, onLine in
                guard let self else { return nil }
                return await self.runProjectMCP(host: selected.host, directory: selected.project.directory, file: file.path,
                                                action: .login(server: name), onLine: onLine)
            }, openURL: openMCPURL, copy: copyMCPLink,
            finished: { [weak self] in Task { await self?.refreshMCPCredentials() } })
        mcpSignIn = flow
        flow.start()
    }

    func signOutMCP(_ name: String) {
        guard mcpEditable, !dirty, let selected, let file = selectedFile, selected.host.supportsMCP else { return }
        closeMCPSignIn()
        mcpSignOut = Task { [weak self] in
            guard let self else { return }
            let result = await runProjectMCP(host: selected.host, directory: selected.project.directory, file: file.path,
                                            action: .logout(server: name), onLine: { _ in })
            guard !Task.isCancelled, self.selected?.id == selected.id, selectedFile?.path == file.path else { return }
            if result.status != 0 { fileError = result.stderr }
            await refreshMCPCredentials()
        }
    }

    func closeMCPSignIn() {
        mcpSignIn?.cancel(); mcpSignIn = nil
        mcpSignOut?.cancel(); mcpSignOut = nil
    }

    private func runProjectMCP(host: ProjectsHost, directory: String, file: String, action: ProjectMCPAction,
                               onLine: @escaping @Sendable (String) -> Void) async -> MCPCLIResult {
        let request = self.request
        func send(_ action: ProjectMCPAction) async throws -> ProjectMCPResult {
            guard case .mcp(let value) = try await request(host, .mcp(directory: directory, file: file, action: action)) else {
                throw ProjectFileError("protocol", "Unexpected project MCP reply.")
            }
            return value
        }
        var id: UUID?
        var relay: MCPCallbackRelay?
        defer {
            relay?.cancel()
            if let id { Task { _ = try? await send(.cancel(id: id)) } }
        }
        do {
            var result = try await send(action)
            id = result.id
            let deadline = Date().addingTimeInterval(MCPSignInFlow.timeout)
            var opened: String?
            while result.phase == .waiting {
                try Task.checkCancellation()
                guard Date() < deadline, let id else { throw ProjectFileError("timeout", "Signing in didn't finish within 300 seconds.") }
                if let address = result.authorizationURL, opened != address, let url = URL(string: address) {
                    if host.id != "local" {
                        let receiver = try MCPCallbackRelay(authorizationURL: url) { redirect in
                            Task { @MainActor in _ = try? await send(.complete(id: id, redirectURL: redirect)) }
                        }
                        relay = receiver
                        try await receiver.start()
                    }
                    try Task.checkCancellation()
                    opened = address
                    onLine(address)
                    openMCPURL(url)
                }
                try await Task.sleep(for: .milliseconds(250))
                result = try await send(.poll(id: id))
            }
            return .init(status: result.phase == .done ? 0 : 1, stdout: "", stderr: result.message ?? "")
        } catch is CancellationError {
            return .init(status: 1, stdout: "", stderr: "Cancelled.")
        } catch {
            return .init(status: 1, stdout: "", stderr: String(describing: error))
        }
    }
}
