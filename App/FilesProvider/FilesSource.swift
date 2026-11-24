import FileProvider
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The extension's way to the paired Macs: one connection per Mac, opened on first use with the app's record and token
/// (`FilesShared`, `HostKeychain`), kept while it lives, opened again once it drops. It reads and writes only through
/// `files.v1`, so a Mac serves the extension exactly what it serves the app's Files pane.
actor FilesSource {
    static let shared = FilesSource()

    /// One live connection and the Mac's threads as it last said.
    final class Link: @unchecked Sendable {
        let client: RemoteHostClient
        /// The pairing and token it was opened with: one the app changed or forgot is not used again.
        let pairing: FilesSharedHost
        let token: String
        private let lock = NSLock()
        private var latest: ShepherdState
        private var dropped = false

        init(client: RemoteHostClient, pairing: FilesSharedHost, token: String, state: ShepherdState) {
            self.client = client
            self.pairing = pairing
            self.token = token
            latest = state
        }

        /// The Mac takes saves and new files, and lists modification times (`files.create.v1`): without them, Files
        /// can neither see every change nor keep a conflicting save, so its files are read only.
        var writable: Bool { client.supports(.filesCreate) }

        var state: ShepherdState {
            get { lock.withLock { latest } }
            set { lock.withLock { latest = newValue } }
        }

        var isDropped: Bool {
            get { lock.withLock { dropped } }
            set { lock.withLock { dropped = newValue } }
        }
    }

    private var links: [UUID: Link] = [:]
    private var opening: [UUID: Task<Link, Error>] = [:]

    func hosts() -> [FilesSharedHost] { FilesShared.read() }

    func link(_ host: UUID) async throws -> Link {
        let pairing = FilesShared.read().first { $0.record.id == host }
        let token = try? HostKeychain.read(account: HostKeychain.account(host))
        if let link = links[host] {
            if !link.isDropped, link.pairing == pairing, link.token == token { return link }
            link.client.disconnect()
            links[host] = nil
        }
        guard let pairing else { throw NSFileProviderError(.noSuchItem) }
        guard let token, !token.isEmpty else { throw NSFileProviderError(.notAuthenticated) }
        if let pending = opening[host] { return try await pending.value }
        let task = Task { try await Self.open(pairing, token: token) }
        opening[host] = task
        defer { opening[host] = nil }
        let link = try await task.value
        links[host] = link
        return link
    }

    func closeAll() {
        for link in links.values { link.client.disconnect() }
        links = [:]
    }

    /// The first of the Mac's routes that answers, as the app tries them (`MobileHosts.connect`).
    private static func open(_ host: FilesSharedHost, token: String) async throws -> Link {
        var failure = RemoteHostFailure(kind: .unreachable, detail: "no route")
        for route in host.record.routes {
            let client = RemoteHostClient()
            do {
                let state = try await client.connect(host: route.host, port: route.port, token: token, clientName: "Shepherd Files",
                                                     capabilities: [RemoteProtocol.filesCapability], expectingHostID: host.expecting)
                let link = Link(client: client, pairing: host, token: token, state: state)
                client.onStateChanged = { [weak link] in link?.state = $0 }
                client.onDisconnected = { [weak link] _ in link?.isDropped = true }
                return link
            } catch {
                client.disconnect()
                failure = RemoteHostFailure(error)
                if !failure.retries { break }
            }
        }
        switch failure.kind {
        case .tokenRefused, .sharedTokenRetired, .tokenMissing, .tokenUnreadable: throw NSFileProviderError(.notAuthenticated)
        default: throw NSFileProviderError(.serverUnreachable)
        }
    }

    // MARK: Reading the Macs

    /// The Mac's threads with their folder names.
    func threads(_ host: UUID) async throws -> [(agent: AgentID, name: String)] {
        FilesNames.threads(try await link(host).state.agents)
    }

    func writable(_ host: UUID) async throws -> Bool { try await link(host).writable }

    func list(_ host: UUID, _ agent: AgentID, _ path: String) async throws -> ThreadFileListing {
        try await run(host) { try await $0.listFiles(agentID: agent, path: path, showHidden: false) }
    }

    func read(_ host: UUID, _ agent: AgentID, _ path: String) async throws -> Data {
        try await run(host) { try await $0.readFile(agentID: agent, path: path) }
    }

    func write(_ host: UUID, _ agent: AgentID, _ path: String, text: String, expected: String) async throws -> ThreadFileSaveResult {
        try await run(host) { try await $0.writeFile(agentID: agent, path: path, text: text, expected: expected) }
    }

    func create(_ host: UUID, _ agent: AgentID, _ path: String, text: String) async throws -> ThreadFileSaveResult {
        try await run(host) { try await $0.createFile(agentID: agent, path: path, text: text) }
    }

    /// One request, its errors in the domains Files takes.
    private func run<T: Sendable>(_ host: UUID, _ body: @Sendable (RemoteHostClient) async throws -> T) async throws -> T {
        let link = try await link(host)
        do {
            return try await body(link.client)
        } catch let error as RemoteHostClientError {
            switch error {
            case .rejected(let code, let message):
                switch code {
                case "not_found", "no_such_agent": throw NSFileProviderError(.noSuchItem)
                case "not_directory": throw NotFolder()
                default: throw Self.failure(message)
                }
            default:
                link.isDropped = true
                throw NSFileProviderError(.serverUnreachable)
            }
        }
    }

    /// A file listed as a folder: a document's own enumerator, not a folder gone.
    struct NotFolder: Error {}

    /// An error Files shows as `message` (it takes only its own and Cocoa's domain).
    static func failure(_ message: String) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
