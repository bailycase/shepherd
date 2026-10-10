import Foundation
import ShepherdSessions
import ShepherdProtocol
import ShepherdUI

/// Project files are configuration, not the global store's live connections or Keychain entries.
struct ProjectMCPConfiguration: Equatable {
    var document = MCPConfigDocument()
    var entries: [MCPServerEntry] = []
    var rows: [MCPServerRowModel] = []
    var details: [String: MCPServerDetailModel] = [:]
    var problem: String?
    var native = true

    init(text: String = "", path: String = ".shepherd/mcp.json", host: String = "This Mac", signedIn: Set<String> = [], canSignIn: Bool = false, projectTrusted: Bool? = nil) {
        // Older remote hosts still inventory native Pi configuration under .pi.
        native = path == ".shepherd/mcp.json" || path == ".pi/mcp.json"
        switch MCPConfigFile.parse(Data(text.utf8)) {
        case .invalid(let line):
            problem = "This file isn't valid JSON at line \(line). Open it in an editor to repair it, then Reload."
            return
        case .document(let parsed): document = parsed
        }
        if let value = document.root["mcpServers"] {
            guard case .object(let servers) = value, servers.values.allSatisfy({ if case .object = $0 { true } else { false } }) else {
                problem = "mcpServers must contain named server objects. Open in editor to repair this file."
                return
            }
        }
        // Neither project runtime reads VS Code's `servers` block. Keep it, but never edit or list it.
        entries = MCPConfigDocument(root: ["mcpServers": document.root["mcpServers"] ?? .object([:])], order: document.order).servers
        for entry in entries {
            for key in ["env", "headers"] {
                if let value = entry.json[key] {
                    guard case .object(let fields) = value, fields.values.allSatisfy({ $0.stringValue != nil }) else {
                        problem = "\(entry.name): \(key) must contain text values. Open in editor to repair this file."
                        return
                    }
                }
            }
            if let args = entry.json["args"], args.arrayValue?.allSatisfy({ $0.stringValue != nil }) != true {
                problem = "\(entry.name): args must be a list of text values. Open in editor to repair this file."
                return
            }
            for key in ["command", "url", "type"] where entry.json[key] != nil && entry.json[key]?.stringValue == nil {
                problem = "\(entry.name): \(key) must be text. Open in editor to repair this file."
                return
            }
            if native, let value = entry.json["timeout"] {
                guard let seconds = value.doubleValue, seconds > 0, Int(exactly: seconds.rounded(.down)) != nil else {
                    problem = "\(entry.name): timeout must be a positive number of seconds. Open in editor to repair this file."
                    return
                }
            }
            if native, let value = entry.json["oauth"] {
                guard case .object(let oauth) = value,
                      ["clientId", "clientSecret", "scope"].allSatisfy({ oauth[$0] == nil || oauth[$0]?.stringValue != nil }) else {
                    problem = "\(entry.name): oauth must be an object with text clientId, clientSecret and scope values. Open in editor to repair this file."
                    return
                }
            }
        }
        rows = entries.map { entry in
            let enabled = native ? entry.json["enabled"]?.boolValue != false : entry.json["disabled"]?.boolValue != true
            let variables = entry.env.count + entry.headers.count
            return MCPServerRowModel(name: entry.name, kind: entry.kind == .local ? .local : .remote,
                                     endpoint: entry.endpoint, status: enabled ? .idle : .off,
                                     signIn: canSignIn && Self.usesOAuth(entry) ? (signedIn.contains(entry.name) ? .account("Credentials saved") : .signIn)
                                         : variables > 0 ? .variables(variables) : .unverified,
                                     tools: nil, enabled: enabled)
        }
        details = Dictionary(uniqueKeysWithValues: entries.map { entry in
            let exposure = native ? entry.json["exposure"]?.stringValue ?? "codemode" : "deferred"
            let direct: Bool? = exposure == "direct" ? true : exposure == "deferred" ? false : nil
            let note = native ? (direct == nil ? "Current mode: \(exposure)." : nil) : "Shared .mcp.json uses Search."
            let signIn: MCPServerDetailModel.SignIn = if canSignIn && Self.usesOAuth(entry) {
                signedIn.contains(entry.name)
                    ? .signedIn(account: nil, scopes: [], note: "OAuth credentials saved on \(host). This does not confirm a thread connection.", title: "Credentials saved")
                    : .needsSignIn(title: "Not signed in", note: "Sign in once on \(host); the agent keeps the token fresh.", again: false)
            } else {
                .unverified(canSignIn ? "Environment references are read on \(host)." : "Update Shepherd on \(host) to sign in here. Environment references are read on that host.")
            }
            let detail = MCPServerDetailModel(
                signIn: signIn,
                toolNames: [], toolCount: nil, direct: direct, searchCost: "", directCost: "", chosenNote: note,
                transport: entry.kind == .local ? "stdio" : entry.transport == .sse ? "Legacy SSE" : "Streamable HTTP",
                hosts: [.init(name: host, detail: native && projectTrusted == false ? "Blocked" : "Unchecked", mark: .none)], toolsNote: native && projectTrusted == false ? "New threads cannot load this server until the project is approved." : "Connection and tools are checked in each thread.")
            return (entry.name, detail)
        })
    }

    static func usesOAuth(_ entry: MCPServerEntry) -> Bool {
        entry.kind == .remote && entry.transport != .sse && !entry.headers.keys.contains { $0.lowercased() == "authorization" }
    }

    mutating func upsert(_ entry: MCPServerEntry) {
        var servers: [String: JSONValue] = [:]
        if case .object(let existing) = document.root["mcpServers"] { servers = existing }
        servers[entry.name] = .object(entry.json)
        document.root["mcpServers"] = .object(servers)
        if !document.order.contains(entry.name) { document.order.append(entry.name) }
        if let index = entries.firstIndex(where: { $0.name == entry.name }) { entries[index] = entry }
        else { entries.append(entry) }
    }

    mutating func remove(_ name: String) {
        guard case .object(var servers) = document.root["mcpServers"] else { return }
        servers[name] = nil
        document.root["mcpServers"] = .object(servers)
        document.order.removeAll { $0 == name }
        entries.removeAll { $0.name == name }
    }
}

extension ProjectsModel {
    var mcpEditable: Bool { category == .mcp && fileLoaded && !fileLoading && !saving && selected?.unavailable == nil && mcp.problem == nil }

    /// Reuses the project's expected-content save and leaves a failed draft available for retry.
    func saveMCP(_ entries: [MCPServerEntry], replacing names: Set<String> = []) async throws {
        guard mcpEditable else { throw ProjectFileError("unavailable", "This project file cannot be edited right now.") }
        var next = mcp
        for name in names where !entries.contains(where: { $0.name == name }) { next.remove(name) }
        for var entry in entries {
            guard MCPServerName.isValid(entry.name) else { throw ProjectFileError("name", "Use letters, digits, - and _ in server names.") }
            guard names.contains(entry.name) || !next.entries.contains(where: {
                $0.name.replacingOccurrences(of: "-", with: "_") == entry.name.replacingOccurrences(of: "-", with: "_")
            }) else { throw ProjectFileError("name", "\(entry.name) is already here.") }
            if next.native, !names.contains(entry.name), entry.json["exposure"] == nil { entry.json["exposure"] = .string("deferred") }
            next.upsert(entry)
        }
        try await persistMCP(next)
    }

    func setMCPEnabled(_ name: String, _ enabled: Bool) async {
        guard mcpEditable, var entry = mcp.entries.first(where: { $0.name == name }) else { return }
        entry.json[mcp.native ? "enabled" : "disabled"] = .bool(mcp.native ? enabled : !enabled)
        do { try await saveMCP([entry], replacing: [name]) } catch { fileError = String(describing: error) }
    }

    func setMCPDirect(_ name: String, _ direct: Bool) async {
        guard mcpEditable, mcp.native, var entry = mcp.entries.first(where: { $0.name == name }) else { return }
        entry.json["exposure"] = .string(direct ? "direct" : "deferred")
        do { try await saveMCP([entry], replacing: [name]) } catch { fileError = String(describing: error) }
    }

    func removeMCP(_ name: String) async throws {
        guard mcpEditable else { throw ProjectFileError("unavailable", "This project file cannot be edited right now.") }
        var next = mcp
        next.remove(name)
        try await persistMCP(next)
    }

    private func persistMCP(_ next: ProjectMCPConfiguration) async throws {
        let projectID = selected?.id, path = selectedFile?.path
        let text = next.document.text + "\n"
        if let problem = ProjectMCPConfiguration(text: text, path: path ?? ".shepherd/mcp.json").problem {
            throw ProjectFileError("invalid", problem)
        }
        draft = text
        await save()
        guard selected?.id == projectID, selectedFile?.path == path else { throw ProjectFileError("changed", "The selected project file changed.") }
        if let fileError { throw ProjectFileError("save", fileError) }
        guard !dirty else { throw ProjectFileError("save", "The project file was not saved. Try again.") }
    }
}
