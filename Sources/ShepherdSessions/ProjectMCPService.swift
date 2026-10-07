import Foundation
import ShepherdProtocol

/// Explicit project OAuth work. The bridge uses pi's MCP implementation and host credential store.
actor ProjectMCPService {
    static let timeout: TimeInterval = 300
    private let pi: PiSetup
    private let timeout: TimeInterval
    private struct Preparation { var owner: UUID?; var namespace: String }
    private var preparing: [UUID: Preparation] = [:]
    private struct Run {
        var owner: UUID?
        var namespace: String
        var directory: String
        var file: String
        var bridge: PiSignInBridge
        var result: ProjectMCPResult
        var task: Task<Void, Never>?
        var expiry: Task<Void, Never>?
    }
    private var runs: [UUID: Run] = [:]
    private var resolvedURLs: [String: String] = [:]
    init(pi: PiSetup, timeout: TimeInterval = ProjectMCPService.timeout) { self.pi = pi; self.timeout = timeout }

    func request(directory: String, file: String, text: String, action: ProjectMCPAction, owner: UUID?, canonicalDirectory: String? = nil) async throws -> ProjectMCPResult {
        try Task.checkCancellation()
        switch action {
        case .poll(let id), .complete(let id, _), .cancel(let id):
            guard let run = runs[id], run.owner == owner, run.directory == directory, run.file == file else {
                throw ProjectFileError("expired", "This sign-in is no longer available. Try again.")
            }
            if case .cancel = action { finish(id, message: "Cancelled."); runs[id] = nil; return .init() }
            if case .complete(_, let redirect) = action {
                guard redirect.utf8.count <= 8192 else { throw ProjectFileError("invalid", "The redirect URL is too long.") }
                run.bridge.send(.answer(id: "redirect", value: redirect))
            }
            return runs[id]?.result ?? run.result
        case .approveProject:
            guard file == ".pi/mcp.json", !PiLaunch.isHomeFolder(directory, userHome: pi.userHome) else {
                throw ProjectFileError("protected", "The home folder cannot be trusted as a project.")
            }
            return .init(projectTrusted: try await projectTrust(directory: directory, approve: true, canonicalDirectory: canonicalDirectory ?? PiHome.canonical(directory)))
        case .credentials:
            let entries = try servers(text)
            let data = try? Data(contentsOf: pi.home.appendingPathComponent("mcp-auth.json"))
            let auth = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let signed = entries.compactMap { name, value -> String? in
                guard let url = value["url"] as? String else { return nil }
                let alias = directory + "\n" + file + "\n" + name + "\n" + url
                guard let canonical = resolvedURLs[alias] ?? Self.canonicalURL(url, shared: file == ".mcp.json") else { return nil }
                let key = "mcp__" + name.replacingOccurrences(of: "-", with: "_") + "|" + canonical
                let state = (auth[key] ?? auth[canonical]) as? [String: Any]
                return (state?["tokens"] as? [String: Any])?["access_token"] is String ? name : nil
            }
            guard file == ".pi/mcp.json" else { return .init(signedIn: signed.sorted()) }
            do {
                return .init(signedIn: signed.sorted(), projectTrusted: try await projectTrust(directory: directory, approve: false))
            } catch {
                return .init(signedIn: signed.sorted(), message: "Couldn't check project approval. Check again before starting a new thread.")
            }
        case .login(let server), .logout(let server):
            guard runs.values.filter({ $0.result.phase == .waiting }).count + preparing.count < 4 else {
                throw ProjectFileError("busy", "Too many sign-ins are running. Close one and try again.")
            }
            guard let entry = try servers(text)[server], let url = entry["url"] as? String,
                  let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme), parsed.host != nil,
                  !((entry["headers"] as? [String: Any]) ?? [:]).keys.contains(where: { $0.lowercased() == "authorization" }),
                  server.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                throw ProjectFileError("unsupported", "Only HTTP servers without an Authorization header use OAuth.")
            }
            let namespace = server.replacingOccurrences(of: "-", with: "_")
            // One OAuth flow per namespace, even across projects, avoids overwriting pi's PKCE state.
            guard !preparing.values.contains(where: { $0.namespace == namespace }),
                  !runs.values.contains(where: { $0.namespace == namespace && $0.result.phase == .waiting }) else {
                throw ProjectFileError("busy", "This server already has a sign-in running. Close it and try again.")
            }
            let started = Date()
            let preparation = UUID()
            preparing[preparation] = Preparation(owner: owner, namespace: namespace)
            defer { preparing[preparation] = nil }
            if let problem = await Task.detached(operation: { [pi] in pi.prepare() }).value {
                throw ProjectFileError("pi", problem.message)
            }
            guard preparing[preparation] != nil, !Task.isCancelled else { throw CancellationError() }
            guard Date().timeIntervalSince(started) < timeout else { throw ProjectFileError("timeout", "The sign-in preparation timed out.") }
            if runs.count >= 16, let completed = runs.first(where: { $0.value.result.phase != .waiting })?.key {
                runs[completed]?.expiry?.cancel(); remove(completed)
            }
            guard let package = pi.engine.packageDirectory else { throw ProjectFileError("pi", "Shepherd's pi SDK is unavailable.") }
            let script = try ProjectMCPScript.install(in: pi.home)
            let sdk = URL(fileURLWithPath: package).appendingPathComponent(BundledPiEngine.libraryPath).path
            let bridge = PiSignInBridge(line: PiLaunch.signInBridge(node: pi.engine.node, script: script.path, sdk: sdk, home: pi.files))
            let id = UUID()
            runs[id] = Run(owner: owner, namespace: namespace, directory: directory, file: file, bridge: bridge,
                           result: .init(id: id, phase: .waiting))
            runs[id]?.task = Task { [weak self] in
                for await reply in bridge.replies { await self?.hear(reply, id: id) }
                await self?.ended(id)
            }
            let timeout = max(0, timeout - Date().timeIntervalSince(started))
            runs[id]?.expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                await self?.finish(id, message: "Signing in didn't finish within 300 seconds.")
                try? await Task.sleep(for: .seconds(30))
                await self?.remove(id)
            }
            let command: String = if case .logout = action { "logout" } else { "login" }
            let payload: [String: Any] = ["server": server, "config": entry, "shared": file == ".mcp.json", "directory": directory, "command": command]
            let data = try JSONSerialization.data(withJSONObject: payload)
            bridge.send(.answer(id: "config", value: String(decoding: data, as: UTF8.self)))
            return runs[id]!.result
        }
    }

    /// Reads or saves Pi's decision without starting a session or loading any project code.
    private func projectTrust(directory: String, approve: Bool, canonicalDirectory: String? = nil) async throws -> Bool {
        if let problem = await Task.detached(operation: { [pi] in pi.prepare() }).value {
            throw ProjectFileError("pi", problem.message)
        }
        try Task.checkCancellation()
        guard let package = pi.engine.packageDirectory else { throw ProjectFileError("pi", "Shepherd's pi SDK is unavailable.") }
        let script = try ProjectMCPScript.install(in: pi.home)
        let sdk = URL(fileURLWithPath: package).appendingPathComponent(BundledPiEngine.libraryPath).path
        let bridge = PiSignInBridge(line: PiLaunch.signInBridge(node: pi.engine.node, script: script.path, sdk: sdk, home: pi.files))
        let expiry = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { bridge.close() }
        }
        defer { expiry.cancel(); bridge.close() }
        let payload = ["command": approve ? "trust" : "trust-status", "directory": directory, "userHome": pi.userHome, "canonicalDirectory": canonicalDirectory ?? PiHome.canonical(directory)]
        bridge.send(.answer(id: "config", value: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)))
        return try await withTaskCancellationHandler {
            var trusted: Bool?
            for await reply in bridge.replies {
                try Task.checkCancellation()
                switch reply {
                case .info(let message):
                    trusted = (try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Bool])?["projectTrusted"]
                case .done:
                    if let trusted { return trusted }
                case .failed: throw ProjectFileError("trust", "Project approval couldn't be checked or saved. Try again.")
                default: break
                }
            }
            throw ProjectFileError("trust", "Project approval didn't finish. Try again.")
        } onCancel: { bridge.close() }
    }

    private func servers(_ text: String) throws -> [String: [String: Any]] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let entries = (object["mcpServers"] ?? [:]) as? [String: [String: Any]] else {
            throw ProjectFileError("invalid", "Enter a valid MCP server configuration before signing in.")
        }
        return entries
    }

    private static func canonicalURL(_ raw: String, shared: Bool) -> String? {
        var value = raw
        if shared {
            let regex = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}"#)
            for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                guard let range = Range(match.range, in: value), let keyRange = Range(match.range(at: 1), in: value) else { continue }
                let key = String(value[keyRange])
                let fallback = Range(match.range(at: 2), in: value).map { String(value[$0]) }
                let replacement = key.hasPrefix("SHEPHERD_") ? fallback ?? "" : ProcessInfo.processInfo.environment[key] ?? fallback
                // ponytail: login-shell-only variables resolve after an explicit sign-in; no shell starts just to show settings.
                guard let replacement else { return nil }
                value.replaceSubrange(range, with: replacement)
            }
        }
        guard var parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased() else { return nil }
        parts.scheme = scheme; parts.host = host
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.url?.standardized.absoluteString
    }

    private func hear(_ reply: PiSignInReply, id: UUID) {
        switch reply {
        case .authURL(let url, _): runs[id]?.result.authorizationURL = url.absoluteString
        case .info(let message):
            guard let data = message.data(using: .utf8),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let name = info["server"], let raw = info["rawURL"], let url = info["resolvedURL"], let run = runs[id] else { return }
            if resolvedURLs.count >= 128 { resolvedURLs.removeAll() }
            resolvedURLs[run.directory + "\n" + run.file + "\n" + name + "\n" + raw] = url
        case .done: finish(id, message: nil)
        case .failed(let failure): finish(id, message: failure.reason)
        default: break
        }
    }
    private func ended(_ id: UUID) {
        if runs[id]?.result.phase == .waiting { finish(id, message: "The sign-in stopped before it finished.") }
    }
    private func finish(_ id: UUID, message: String?) {
        guard var run = runs[id], run.result.phase == .waiting else { return }
        run.result.phase = message == nil ? .done : .failed
        run.result.message = message
        run.result.authorizationURL = nil
        run.bridge.close()
        runs[id] = run
    }
    private func remove(_ id: UUID) { runs[id]?.bridge.close(); runs[id]?.expiry?.cancel(); runs[id] = nil }
    func cancelAll() {
        preparing.removeAll()
        for id in runs.keys { runs[id]?.task?.cancel(); remove(id) }
    }
    func cancel(owner: UUID) {
        for id in preparing.keys.filter({ preparing[$0]?.owner == owner }) { preparing[id] = nil }
        for id in runs.keys.filter({ runs[$0]?.owner == owner }) {
            runs[id]?.expiry?.cancel(); runs[id]?.task?.cancel(); remove(id)
        }
    }
}
