import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

extension HostStores {
    func hostConfig(_ request: RemoteHostConfigRequest) async throws -> RemoteHostConfigResult {
        switch request {
        case .mcpEntry(let name):
            mcp.reload()
            guard let entry = mcp.entry(name) else { throw RemoteCreateAgentError("No MCP server is named \(name).") }
            return .mcpEntry(json: HostConfigMapping.maskedJSON(entry))
        case .mcpSave(let json, let secrets, let replacing):
            mcp.reload()
            let parsedName = try HostConfigMapping.entry(json, secrets: [:], existing: nil, keepingMasks: true).name
            var entry = try HostConfigMapping.entry(json, secrets: secrets, existing: mcp.entry(replacing ?? parsedName))
            if let replacing {
                guard let old = mcp.entry(replacing) else { throw RemoteCreateAgentError("No MCP server is named \(replacing).") }
                // An edit keeps the Mac's own switches (on, exposure, tools) unless it sets them.
                if entry.json["shepherd"] == nil { entry.json["shepherd"] = old.json["shepherd"] }
            } else if mcp.entry(entry.name) != nil {
                throw RemoteCreateAgentError("An MCP server is already named \(entry.name).")
            }
            try mcp.save(entry, secrets: secrets, replacing: replacing)
            return try await mcpInventory()
        case .mcpSetEnabled(let name, let on):
            try requireServer(name)
            mcp.setEnabled(name, on)
            return try await mcpInventory()
        case .mcpSetExposure(let name, let exposure):
            try requireServer(name)
            mcp.setExposure(name, exposure == .direct ? .direct : .proxy)
            return try await mcpInventory()
        case .mcpSetTools(let name, let tools):
            try requireServer(name)
            mcp.setTools(name, tools)
            return try await mcpInventory()
        case .mcpRemove(let name):
            try requireServer(name)
            mcp.remove(name)
            return try await mcpInventory()
        case .mcpImport(let json, let replace):
            mcp.reload()
            let entries: [MCPServerEntry]
            switch MCPImport.parse(json) {
            case .success(let parsed): entries = parsed
            case .failure(let failure): throw RemoteCreateAgentError("\(failure)")
            }
            guard entries.allSatisfy({ MCPServerName.isValid($0.name) }) else {
                throw RemoteCreateAgentError("Server names use letters, digits, - and _ only.")
            }
            try mcp.importEntries(entries, replace: replace)
            return try await mcpInventory()
        case .mcpRefresh:
            mcp.reload()
            mcp.refresh()
            return try await mcpInventory()
        case .mcpSignIn(let name):
            try requireServer(name)
            guard let entry = mcp.entry(name), mcp.signsInWithOAuth(entry) else {
                throw RemoteCreateAgentError("\(name) doesn't sign in with OAuth.")
            }
            return .signIn(try remoteSignIns.startMCP(name, store: mcp))
        case .mcpSignOut(let name):
            try requireServer(name)
            await mcp.signOutNow(name)
            return try await mcpInventory()

        case .subagentSave(let file, let text, let fingerprint):
            guard SubagentDefinitionsStore.acceptsFilename(file) else { throw RemoteCreateAgentError("Not a subagent file.") }
            let store = subagentDefinitions.store
            let saved = try await Task.detached(priority: .userInitiated) {
                try store.save(file, text: text, expected: fingerprint)
            }.value
            await subagentDefinitions.refresh()
            return .subagent(HostSubagentProfileText(file: saved.file, text: saved.text, fingerprint: saved.fingerprint))
        case .subagentDelete(let file, let fingerprint):
            guard SubagentDefinitionsStore.acceptsFilename(file) else { throw RemoteCreateAgentError("Not a subagent file.") }
            let store = subagentDefinitions.store
            try await Task.detached(priority: .userInitiated) { try store.delete(file, expected: fingerprint) }.value
            return try await subagentProfiles()
        case .subagentRestoreDefaults(let expected):
            let store = subagentDefinitions.store
            try await Task.detached(priority: .userInitiated) { try store.restore(expected: expected) }.value
            return try await subagentProfiles()

        case .providerKey(let provider, let key):
            try await saveProviderKey(provider, key: HostConfigMapping.keyInput(key))
            return .providers(await hostProviders())
        case .providerSignOut(let provider):
            try HostConfigMapping.requireProvider(provider)
            await piAuth.signOut(provider)
            if let problem = piAuth.problems[provider] { throw RemoteCreateAgentError(problem) }
            return .providers(await hostProviders())
        case .providerSignIn(let provider, let method, let adding):
            let selected = method ?? .oauth
            let methods = try await providerMethods(provider, method: selected)
            let subscription = PiSignInCatalog.account(id: provider, name: methods.name, label: selected == .oauth ? methods.oauth : methods.apiKey)
            if adding == true, !(await piAuth.beginAddingRemotely(provider)) {
                throw RemoteCreateAgentError(piAuth.problems[provider] ?? "Couldn’t add an account.")
            }
            do { return .signIn(try remoteSignIns.startProvider(subscription, auth: piAuth, method: selected)) } catch {
                if adding == true { piAuth.stopAdding(provider) }
                throw error
            }
        case .providerAccount(let provider, let action):
            try HostConfigMapping.requireProvider(provider)
            switch action {
            case .use(let id): await piAuth.switchAccount(provider, to: id)
            case .remove(let id): await piAuth.removeAccount(provider, id)
            case .rename(let id, let name):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count <= 64 else { throw RemoteCreateAgentError("Enter a name of up to 64 characters.") }
                await piAuth.renameAccount(provider, id, to: trimmed)
            case .rotate(let on): await piAuth.setRotate(provider, on)
            case .add:
                let methods = try await providerMethods(provider, method: .oauth)
                let subscription = PiSignInCatalog.account(id: provider, name: methods.name, label: methods.oauth)
                guard await piAuth.beginAddingRemotely(provider) else {
                    throw RemoteCreateAgentError(piAuth.problems[provider] ?? "Couldn’t add an account.")
                }
                do { return .signIn(try remoteSignIns.startProvider(subscription, auth: piAuth)) } catch {
                    piAuth.stopAdding(provider)
                    throw error
                }
            case .addKey(let key):
                // As Settings ▸ Sign-in's Add account for a key: the current key is saved first,
                // and the new one lands beside it.
                let input = try HostConfigMapping.keyInput(key)
                guard try await providerMethods(provider, method: .apiKey).keyForm == true else {
                    throw RemoteCreateAgentError("This provider needs interactive sign-in. Update Shepherd on this device.")
                }
                guard await piAuth.beginAddingRemotely(provider) else {
                    throw RemoteCreateAgentError(piAuth.problems[provider] ?? "Couldn’t add an account.")
                }
                do { try await saveProviderKey(provider, key: input) } catch {
                    piAuth.stopAdding(provider)
                    throw error
                }
            }
            if let problem = piAuth.problems[provider] { throw RemoteCreateAgentError(problem) }
            return .providers(await hostProviders())
        case .extensionSetEnabled(let destination, let on):
            try await requireExtension(destination)
            let row = YourPiModel.extensionRowID(destination)
            await yourPi.setExtension(destination, on: on)
            return try await extensionsAfter(row)
        case .extensionRemove(let destination):
            try await requireExtension(destination)
            let row = YourPiModel.extensionRowID(destination)
            await yourPi.removeExtension(destination)
            return try await extensionsAfter(row)
        case .extensionAddGit(let url):
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= HostConfigMapping.maxURLBytes else {
                throw RemoteCreateAgentError("Enter a Git repository address.")
            }
            await yourPi.addExtension(.git(trimmed))
            return try await extensionsAfter(YourPiModel.addExtensionRow)
        case .signIn(let id, let action):
            return .signIn(try await remoteSignIns.act(id, action))
        }
    }

    /// An extension the host has a copy of, as Settings lists it: a client names it by `HostExtension.id`.
    private func requireExtension(_ destination: String) async throws {
        await yourPi.refresh()
        guard yourPi.survey?.extensions.contains(where: { $0.copy.destination == destination }) == true else {
            throw RemoteCreateAgentError("This Mac has no extension by that name.")
        }
    }

    /// The extensions after a change, or the reason the Mac's row shows for why it failed.
    private func extensionsAfter(_ row: String) async throws -> RemoteHostConfigResult {
        if let problem = yourPi.problems[row] { throw RemoteCreateAgentError(problem) }
        return .extensions(await hostExtensions())
    }

    private func providerMethods(_ provider: String, method: PiSignInMethod) async throws -> PiSignInProvider {
        try HostConfigMapping.requireProvider(provider)
        await piAuth.refreshProviders()
        if let problem = piAuth.providersProblem { throw RemoteCreateAgentError(problem) }
        guard let methods = piAuth.providers?.first(where: { $0.id == provider }),
              method == .oauth ? methods.oauth != nil : methods.apiKey != nil else {
            throw RemoteCreateAgentError("This provider does not offer that sign-in method.")
        }
        return methods
    }

    private func requireServer(_ name: String) throws {
        mcp.reload()
        guard mcp.entry(name) != nil else { throw RemoteCreateAgentError("No MCP server is named \(name).") }
    }

    private func mcpInventory() async throws -> RemoteHostConfigResult {
        await mcp.settle()
        return .mcp(HostInventoryMapping.mcp(mcp))
    }

    private func subagentProfiles() async throws -> RemoteHostConfigResult {
        await subagentDefinitions.refresh()
        let store = subagentDefinitions.store
        let definitions = try await Task.detached(priority: .userInitiated) { try store.snapshot() }.value
        return .subagents(definitions.map(HostInventoryMapping.profile))
    }

    /// pi's key login, answered with `key` once pi asks and the provider took it (as Settings'
    /// key form does: a key the provider refuses is not saved).
    private func saveProviderKey(_ provider: String, key: PiKeyInput) async throws {
        guard try await providerMethods(provider, method: .apiKey).keyForm == true else {
            throw RemoteCreateAgentError("This provider needs interactive sign-in. Update Shepherd on this device.")
        }
        let bridge = try piAuth.bridge()
        defer { bridge.close() }
        let watchdog = Task {
            try? await Task.sleep(for: HostConfigMapping.keyTimeout)
            if !Task.isCancelled { bridge.close() }
        }
        defer { watchdog.cancel() }
        bridge.send(.login(provider: provider, method: .apiKey, flow: .browser))
        bridge.send(.check(id: "remote", provider: provider, key: key))
        var prompt: String?
        var checked = false
        for await reply in bridge.replies {
            switch reply {
            case .prompt(let asked):
                guard asked.kind == .secret, asked.keyForm == true else {
                    throw RemoteCreateAgentError("The provider needs additional setup. Use its interactive sign-in.")
                }
                prompt = asked.id
            case .checked("remote", let result):
                switch result {
                case .rejected(let reason), .unset(let reason): throw RemoteCreateAgentError(reason)
                case .works, .unreachable: checked = true
                }
            case .done(let landed, _):
                _ = piAuth.landed(landed)
                return
            case .failed(let failure): throw RemoteCreateAgentError(failure.reason)
            default: break
            }
            if checked, let id = prompt {
                prompt = nil
                bridge.send(.answer(id: id, value: key.stored))
            }
        }
        throw RemoteCreateAgentError("The sign-in helper stopped before the key was saved.")
    }
}

/// A client's MCP entry and key as this Mac's stores take them.
@MainActor
enum HostConfigMapping {
    static let keyTimeout: Duration = .seconds(60)

    /// The longest address a client may ask the host to clone.
    static let maxURLBytes = 2048

    /// What a remote read shows in place of a value written literally into the host's file.
    static let mask = "••••••••"

    /// A value a client may read: references (`${keychain:…}`, `${VAR}`), an auth scheme before
    /// one ("Bearer ${…}") and empty values as written; anything else written literally is masked.
    static func masked(_ value: String) -> String {
        let rest = value.replacingOccurrences(of: #"\$\{[^}]*\}"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || ["bearer", "token", "basic"].contains(rest.lowercased()) ? value : mask
    }

    /// One server's entry as `{"mcpServers": {name: …}}` JSON for a remote client, without
    /// Shepherd's fields and with every literal env and header value masked.
    static func maskedJSON(_ entry: MCPServerEntry) -> String {
        var copy = entry
        if !copy.env.isEmpty { copy.env = copy.env.mapValues(masked) }
        if !copy.headers.isEmpty { copy.headers = copy.headers.mapValues(masked) }
        return MCPJSON.write(.object([MCPConfigDocument.serversKey: .object([entry.name: .object(copy.withoutShepherd)])]))
    }

    /// One server from `{"mcpServers": {name: …}}` JSON. A key named in `secrets` must be one of
    /// its env or header keys; its value in the file becomes the Keychain reference. A value the
    /// client read masked (`mask`) keeps `existing`'s value for that key.
    static func entry(_ json: String, secrets: [String: String], existing: MCPServerEntry? = nil,
                      keepingMasks: Bool = false) throws -> MCPServerEntry {
        guard json.utf8.count <= 64 * 1024 else { throw RemoteCreateAgentError("The server's JSON is too long.") }
        let entries: [MCPServerEntry]
        switch MCPImport.parse(json) {
        case .success(let parsed): entries = parsed
        case .failure(let failure): throw RemoteCreateAgentError("\(failure)")
        }
        guard entries.count == 1, var entry = entries.first else { throw RemoteCreateAgentError("Send one server at a time.") }
        guard MCPServerName.isValid(entry.name) else { throw RemoteCreateAgentError("Server names use letters, digits, - and _ only.") }
        var env = entry.env, headers = entry.headers
        if !keepingMasks {
            for (key, value) in env where value == mask {
                guard let kept = existing?.env[key] else { throw RemoteCreateAgentError("Enter a value for \(key): the host has none to keep.") }
                env[key] = kept
            }
            for (key, value) in headers where value == mask {
                guard let kept = existing?.headers[key] else { throw RemoteCreateAgentError("Enter a value for \(key): the host has none to keep.") }
                headers[key] = kept
            }
        }
        for key in secrets.keys {
            let reference = MCPSecretReference.reference(server: entry.name, name: key)
            if env[key] != nil { env[key] = reference } else if headers[key] != nil { headers[key] = reference } else {
                throw RemoteCreateAgentError("\(key) isn't one of the server's variables or headers.")
            }
        }
        if env != entry.env { entry.env = env }
        if headers != entry.headers { entry.headers = headers }
        return entry
    }

    /// `$NAME` names a variable the login shell sets; anything else is the key itself.
    static func keyInput(_ key: String) throws -> PiKeyInput {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 8192 else { throw RemoteCreateAgentError("Enter a key.") }
        if trimmed.hasPrefix("$"), trimmed.dropFirst().range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil {
            return .variable(String(trimmed.dropFirst()))
        }
        return .literal(trimmed)
    }

    static func requireProvider(_ provider: String) throws {
        guard provider.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil else {
            throw RemoteCreateAgentError("Not a provider.")
        }
    }
}

/// Sign-ins a remote client drives on this Mac: a provider's (pi's login, with the code the
/// provider's page shows sent back) and an MCP server's (`pi mcp login`, with the address the
/// browser was sent back to relayed to pi's loopback listener). Bounded: a few at once, each
/// gone five and a half minutes after it started, and nothing resumes after a restart.
@MainActor
final class RemoteSignIns {
    static let limit = 4
    static let lifetime: Duration = .seconds(330)

    final class Run {
        var progress: HostSignInProgress
        let key: String
        /// pi's open question, a provider's.
        var promptID: String?
        var complete: (String) async throws -> Void = { _ in }
        var cancel: () -> Void = {}
        var expiry: Task<Void, Never>?
        init(progress: HostSignInProgress, key: String) {
            self.progress = progress
            self.key = key
        }
        var isLive: Bool { progress.phase == .starting || progress.phase == .waiting }
    }

    private var runs: [UUID: Run] = [:]

    var liveCount: Int { runs.values.filter(\.isLive).count }

    private func begin(key: String, name: String) throws -> Run {
        guard liveCount < Self.limit else { throw RemoteCreateAgentError("Too many sign-ins are running. Finish one and try again.") }
        if let running = runs.values.first(where: { $0.key == key && $0.isLive }) {
            running.cancel()
            runs[running.progress.id] = nil
        }
        let run = Run(progress: HostSignInProgress(id: UUID(), phase: .starting, name: name), key: key)
        runs[run.progress.id] = run
        let id = run.progress.id
        run.expiry = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            self?.runs[id]?.cancel()
            self?.runs[id] = nil
        }
        return run
    }

    func act(_ id: UUID, _ action: HostSignInAction) async throws -> HostSignInProgress {
        guard let run = runs[id] else { throw RemoteCreateAgentError("This sign-in is no longer available. Try again.") }
        switch action {
        case .poll: break
        case .complete(let code, let promptID):
            guard run.isLive else { break }
            guard code.utf8.count <= 8192 else { throw RemoteCreateAgentError("That's too long to be a sign-in answer.") }
            if let promptID, promptID != run.promptID { throw RemoteCreateAgentError("That question has closed. Answer the current question.") }
            if let prompt = run.progress.prompt, prompt.kind != .manualCode, promptID == nil {
                throw RemoteCreateAgentError("Update Shepherd on this device to answer this provider’s question.")
            }
            try await run.complete(code)
        case .cancel:
            run.cancel()
            run.expiry?.cancel()
            runs[id] = nil
            var ended = run.progress
            ended.phase = .failed
            ended.message = "Cancelled."
            return ended
        }
        return run.progress
    }

    /// pi's account login for `subscription`, its page opened on the client: a pasted code, or a
    /// device code to enter.
    func startProvider(_ subscription: PiSignInCatalog.Subscription, auth: PiAuthStore,
                       method: PiSignInMethod = .oauth) throws -> HostSignInProgress {
        let run = try begin(key: "provider:" + subscription.id, name: subscription.name)
        let bridge: PiSignInBridge
        do { bridge = try auth.bridge() } catch {
            runs[run.progress.id] = nil
            throw RemoteCreateAgentError(String(describing: error))
        }
        let reader = Task { @MainActor [weak run] in
            for await reply in bridge.replies {
                guard let run else { return }
                switch reply {
                case .authURL(let url, _):
                    run.progress.authorizationURL = url.absoluteString
                    run.progress.phase = .waiting
                case .deviceCode(let code, let uri, _):
                    run.progress.deviceCode = code
                    run.progress.authorizationURL = uri
                    run.progress.phase = .waiting
                case .prompt(let prompt):
                    run.promptID = prompt.id
                    run.progress.prompt = prompt
                    run.progress.wantsCode = prompt.kind == .manualCode || prompt.kind == .text
                    run.progress.phase = .waiting
                case .promptClosed(let id) where id == run.promptID:
                    run.promptID = nil
                    run.progress.prompt = nil
                    run.progress.wantsCode = false
                case .done(let provider, _):
                    _ = auth.landed(provider)
                    run.progress = HostSignInProgress(id: run.progress.id, phase: .done, name: run.progress.name)
                    bridge.close()
                case .failed(let failure):
                    run.progress = HostSignInProgress(id: run.progress.id, phase: .failed, name: run.progress.name, message: failure.reason)
                    auth.stopAdding(subscription.id)
                    bridge.close()
                default: break
                }
            }
            if let run, run.isLive {
                run.progress = HostSignInProgress(id: run.progress.id, phase: .failed, name: run.progress.name,
                                                  message: "The sign-in stopped before it finished.")
                auth.stopAdding(subscription.id)
            }
        }
        run.cancel = {
            bridge.send(.cancel)
            bridge.close()
            reader.cancel()
            auth.stopAdding(subscription.id)
        }
        run.complete = { [weak run] value in
            guard let run, let promptID = run.promptID, let prompt = run.progress.prompt else {
                throw RemoteCreateAgentError("The host isn't waiting for an answer yet. Try again in a moment.")
            }
            let answer = prompt.kind == .manualCode ? value.trimmingCharacters(in: .whitespacesAndNewlines) : value
            if prompt.kind == .select, !prompt.options.contains(where: { $0.id == answer }) {
                throw RemoteCreateAgentError("Choose one of the provider’s options.")
            }
            run.promptID = nil
            run.progress.prompt = nil
            run.progress.wantsCode = false
            run.progress.phase = .starting
            bridge.send(.answer(id: promptID, value: answer))
        }
        // A pasted code: nothing listens on, or opens a browser on, this Mac for a client's sign-in.
        bridge.send(.login(provider: subscription.id, method: method, flow: subscription.flow == .device ? .device : .paste))
        return run.progress
    }

    /// `pi mcp login` for one server. pi listens on this Mac's loopback for the browser's return;
    /// the client sends the address its browser ended on, and this Mac makes that one request.
    /// `--no-browser` runs it through pi's `openUrl` option (`PiMCPCLI.line`), so nothing opens
    /// in this Mac's browser; the Mac's own Sign in still opens it.
    func startMCP(_ name: String, store: MCPStore) throws -> HostSignInProgress {
        let run = try begin(key: "mcp:" + name, name: name)
        let task = Task { @MainActor [weak run, weak store] in
            let result = await store?.runCLI(["login", name, "--timeout", String(Int(MCPSignInFlow.timeout)), PiMCPCLI.noBrowser],
                                             timeout: MCPSignInFlow.timeout + 10) { line in
                let text = line.trimmingCharacters(in: .whitespaces)
                guard text.hasPrefix("http"), URL(string: text)?.host != nil else { return }
                Task { @MainActor in
                    guard let run, run.progress.authorizationURL == nil else { return }
                    run.progress.authorizationURL = text
                    run.progress.wantsCode = true
                    run.progress.phase = .waiting
                }
            }
            guard let run, !Task.isCancelled else { return }
            if result?.status == 0 {
                run.progress = HostSignInProgress(id: run.progress.id, phase: .done, name: name)
                store?.refresh()
            } else {
                let said = [result?.stderr ?? "", result?.stdout ?? ""].first { !$0.isEmpty }?
                    .split(whereSeparator: \.isNewline).last.map(String.init)
                run.progress = HostSignInProgress(id: run.progress.id, phase: .failed, name: name,
                                                  message: said ?? "Shepherd's pi isn't ready to sign in.")
            }
        }
        run.cancel = { task.cancel() }
        run.complete = { [weak run] address in
            guard let run, let authorization = run.progress.authorizationURL.flatMap(URL.init(string:)),
                  let callback = RemoteSignIns.callback(address, for: authorization) else {
                throw RemoteCreateAgentError("Paste the whole address the browser ended on, starting http://127.0.0.1 or http://localhost.")
            }
            run.progress.wantsCode = false
            var request = URLRequest(url: callback, timeoutInterval: 15)
            request.httpMethod = "GET"
            _ = try? await URLSession.shared.data(for: request)
        }
        return run.progress
    }

    /// The address a browser ended on, when it is the loopback redirect `authorization` asked
    /// for (same host, port and path, and its `state`): nothing else is ever requested.
    nonisolated static func callback(_ address: String, for authorization: URL) -> URL? {
        let asked = URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let redirect = asked.first(where: { $0.name == "redirect_uri" })?.value.flatMap(URLComponents.init(string:)),
              let state = asked.first(where: { $0.name == "state" })?.value, !state.isEmpty,
              let got = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              got.scheme == "http", redirect.scheme == "http",
              let host = got.host, ["127.0.0.1", "localhost", "::1"].contains(host), host == redirect.host,
              got.port != nil, got.port == redirect.port, got.path == redirect.path,
              got.user == nil, got.password == nil,
              got.queryItems?.first(where: { $0.name == "state" })?.value == state else { return nil }
        return got.url
    }
}
