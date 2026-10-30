import Foundation
import Observation
import ShepherdProtocol

/// Each host's MCP servers, subagent profiles and provider sign-ins as a client's Settings shows
/// and changes them (`hostInventory.v1` to read, `hostConfig.v1` to change). Every answer lands
/// in one place, so a page shows the host as it is after the last change. A secret the person
/// types goes out in one request and is never kept here.
@MainActor
@Observable
public final class ClientHostConfig {
    public enum Page: Hashable, Sendable {
        case mcp, subagents, providers
    }

    public private(set) var mcp: [UUID: HostMCPInventory] = [:]
    public private(set) var profiles: [UUID: [HostSubagentProfile]] = [:]
    public private(set) var providers: [UUID: [HostProviderStatus]] = [:]
    /// The sign-in a host runs for this client, while it shows.
    public private(set) var signIns: [UUID: HostSignInProgress] = [:]
    /// What failed last, per host and page, in words.
    public private(set) var problems: [UUID: String] = [:]
    public private(set) var busy: Set<UUID> = []
    @ObservationIgnored private var forgotten: Set<UUID> = []

    /// How often a sign-in under way is asked about, and for how long at most.
    @ObservationIgnored public var pollInterval: Duration = .milliseconds(1500)
    public static let pollLimit = 220

    public init() {}

    public func forget(host: UUID) {
        forgotten.insert(host)
        mcp[host] = nil
        profiles[host] = nil
        providers[host] = nil
        signIns[host] = nil
        problems[host] = nil
    }

    /// The host takes changes here; an older one is read-only.
    public func canEdit(_ host: SettingsHost) -> Bool { host.serves(RemoteProtocol.hostConfigCapability) }

    public func canRead(_ host: SettingsHost) -> Bool { host.serves(RemoteProtocol.hostInventoryCapability) }

    public func dismissProblem(on host: SettingsHost) { problems[host.id] = nil }

    /// Reads a page of the host afresh.
    public func refresh(_ page: Page, on host: SettingsHost) async {
        guard canRead(host), let client = host.client, !forgotten.contains(host.id) else { return }
        let request: RemoteHostInventoryRequest = switch page {
        case .mcp: .mcp
        case .subagents: .subagents
        case .providers: .providers
        }
        do {
            let result = try await client.hostInventory(request)
            guard !forgotten.contains(host.id) else { return }
            switch result {
            case .mcp(let value): mcp[host.id] = value
            case .subagents(let value): profiles[host.id] = value
            case .providers(let value): providers[host.id] = value
            case .subagent: break
            }
        } catch {
            guard !forgotten.contains(host.id) else { return }
            problems[host.id] = settingsProblem(error)
        }
    }

    /// One profile's Markdown and fingerprint, for its editor.
    public func profile(_ file: String, on host: SettingsHost) async -> HostSubagentProfileText? {
        guard canRead(host), let client = host.client else { return nil }
        do {
            if case .subagent(let text) = try await client.hostInventory(.subagent(file: file)) { return text }
        } catch {
            problems[host.id] = settingsProblem(error)
        }
        return nil
    }

    /// Sends one change and keeps what the host answers. Returns the answer, nil when it failed
    /// (the reason is in `problems`) or the host can't take it.
    @discardableResult
    public func perform(_ request: RemoteHostConfigRequest, on host: SettingsHost) async -> RemoteHostConfigResult? {
        guard canEdit(host), let client = host.client, !forgotten.contains(host.id) else { return nil }
        busy.insert(host.id)
        problems[host.id] = nil
        defer { busy.remove(host.id) }
        do {
            let result = try await client.hostConfig(request)
            guard !forgotten.contains(host.id) else { return nil }
            switch result {
            case .mcp(let value): mcp[host.id] = value
            case .subagents(let value): profiles[host.id] = value
            case .providers(let value): providers[host.id] = value
            case .signIn(let value): signIns[host.id] = value
            case .mcpEntry, .subagent: break
            }
            return result
        } catch {
            guard !forgotten.contains(host.id) else { return nil }
            problems[host.id] = settingsProblem(error)
            return nil
        }
    }

    /// Asks about the host's sign-in until it ends (or `pollLimit` asks), then reads the page it
    /// changes again. Cancelled with the task that runs it.
    public func follow(signInOn host: SettingsHost, page: Page) async {
        for _ in 0..<Self.pollLimit {
            guard let progress = signIns[host.id], progress.phase == .starting || progress.phase == .waiting else { break }
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled, signIns[host.id]?.id == progress.id else { return }
            guard await perform(.signIn(id: progress.id, action: .poll), on: host) != nil else {
                signIns[host.id] = nil
                return
            }
        }
        if signIns[host.id]?.phase == .done { await refresh(page, on: host) }
    }

    /// Sends the code or address the person pasted for the sign-in under way.
    public func complete(signInOn host: SettingsHost, with code: String) async {
        guard let progress = signIns[host.id] else { return }
        await perform(.signIn(id: progress.id, action: .complete(code)), on: host)
    }

    /// Ends the sign-in under way, and forgets it.
    public func cancelSignIn(on host: SettingsHost) async {
        guard let progress = signIns[host.id] else { return }
        signIns[host.id] = nil
        if progress.phase == .starting || progress.phase == .waiting {
            _ = try? await host.client?.hostConfig(.signIn(id: progress.id, action: .cancel))
        }
    }

    /// Drops a finished sign-in from the page.
    public func clearSignIn(on host: SettingsHost) { signIns[host.id] = nil }
}
