import Foundation
import Observation
import ShepherdUI

/// One OAuth sign-in, as the sign-in sheet shows it: find the sign-in server, register Shepherd
/// (or use the client ID from Advanced), wait for the user in the browser on a one-shot
/// loopback redirect, exchange the code, save the token, and probe the server.
@MainActor
@Observable
final class MCPSignInFlow: Identifiable {
    let id = UUID()
    let server: String
    private(set) var model: MCPSignInSheetModel
    /// Finished and signed in: the sheet closes a moment later.
    private(set) var succeeded = false

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let oauth: MCPOAuthSettings
    @ObservationIgnored private let challenge: String?
    @ObservationIgnored private let previous: MCPOAuthToken?
    @ObservationIgnored private let missingScopes: [String]
    @ObservationIgnored private let service: MCPOAuthService
    @ObservationIgnored private let dependencies: MCPStore.Dependencies
    @ObservationIgnored private let complete: (MCPOAuthToken) async throws -> MCPProbeResult?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var listener: MCPLoopbackListener?
    @ObservationIgnored private(set) var authorizationURL: URL?
    @ObservationIgnored private var provider: String
    @ObservationIgnored private var domain: String

    init(server: String, url: URL, oauth: MCPOAuthSettings, challenge: String?, previous: MCPOAuthToken?, missingScopes: [String],
         service: MCPOAuthService, dependencies: MCPStore.Dependencies,
         complete: @escaping (MCPOAuthToken) async throws -> MCPProbeResult?) {
        self.server = server
        self.url = url
        self.oauth = oauth
        self.challenge = challenge
        self.previous = previous
        self.missingScopes = missingScopes
        self.service = service
        self.dependencies = dependencies
        self.complete = complete
        provider = Self.providerName(server: server, host: url.host)
        domain = Self.domain(url.host) ?? url.host ?? server
        model = MCPSignInSheetModel(title: "Sign in to \(provider)", subtitle: "Finish signing in on \(domain).", steps: [],
                                    phase: .waiting)
        model.steps = Self.steps(provider: provider, domain: domain, registration: nil)
    }

    /// "Notion" from mcp.notion.com, else the server's own name capitalized.
    nonisolated static func providerName(server: String, host: String?) -> String {
        if let domain = domain(host), let label = domain.split(separator: ".").first, !domain.hasPrefix("127."),
           domain != "localhost" {
            return label.prefix(1).uppercased() + label.dropFirst()
        }
        return server.prefix(1).uppercased() + server.dropFirst()
    }

    /// The last two labels of a host: notion.com from mcp.notion.com.
    nonisolated static func domain(_ host: String?) -> String? {
        guard let host, !host.isEmpty else { return nil }
        if host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return host }
        let labels = host.split(separator: ".")
        return labels.count <= 2 ? host : labels.suffix(2).joined(separator: ".")
    }

    private static func steps(provider: String, domain: String, registration: String?) -> [MCPSignInSheetModel.Step] {
        [
            .init(id: "found", title: "Finding \(provider)’s sign-in server", state: .live),
            .init(id: "registered", title: "Registering Shepherd with \(provider)", note: registration, state: .pending),
            .init(id: "browser", title: "Waiting for you in the browser",
                  note: "Approve access on \(domain); this closes by itself.", state: .pending),
        ]
    }

    func start() {
        task?.cancel()
        succeeded = false
        model = MCPSignInSheetModel(title: "Sign in to \(provider)", subtitle: "Finish signing in on \(domain).",
                                    steps: Self.steps(provider: provider, domain: domain, registration: nil), phase: .waiting)
        task = Task { [weak self] in await self?.run() }
    }

    func tryAgain() { start() }

    func cancel() {
        task?.cancel()
        listener?.cancel()
    }

    func openBrowserAgain() {
        if let authorizationURL { dependencies.openURL(authorizationURL) }
    }

    func copyLink() {
        if let authorizationURL { dependencies.copy(authorizationURL.absoluteString) }
    }

    private func set(_ id: String, _ state: MCPSignInSheetModel.Step.State, title: String? = nil, note: String?? = nil) {
        guard let index = model.steps.firstIndex(where: { $0.id == id }) else { return }
        model.steps[index].state = state
        if let title { model.steps[index].title = title }
        if let note { model.steps[index].note = note }
    }

    private var live: String? { model.steps.first { $0.state == .live }?.id }

    private func run() async {
        do {
            // 1. Where to sign in.
            let discovery = try await service.discover(server: url, challenge: MCPAuthChallenge.bearer(in: challenge))
            let authHost = URL(string: discovery.metadata.authorizationEndpoint)?.host
            provider = Self.providerName(server: server, host: authHost ?? url.host)
            domain = Self.domain(authHost) ?? domain
            model.title = "Sign in to \(provider)"
            model.subtitle = "Finish signing in on \(domain)."
            set("found", .done, title: "Found \(provider)’s sign-in server",
                note: .some("\((discovery.resourceMetadataURL ?? url).host ?? domain) pointed the way"))
            set("registered", .live, title: "Registering Shepherd with \(provider)")
            set("browser", .pending, note: .some("Approve access on \(domain); this closes by itself."))
            try Task.checkCancellation()

            // 2. A client, and the redirect it answers on.
            let state = MCPPKCE.randomString()
            let reuse = previous.flatMap { $0.issuer == discovery.issuer ? $0 : nil }
            let preferred = reuse.flatMap { URL(string: $0.redirectURI)?.port }.map(UInt16.init) ?? 0
            let listener = MCPLoopbackListener(state: state, preferredPort: preferred)
            self.listener = listener
            try await listener.start()
            let client: MCPOAuthClient
            let registration: String
            if let clientID = oauth.clientID, !clientID.isEmpty {
                client = MCPOAuthClient(clientID: clientID, clientSecret: oauth.clientSecret, authMethod: nil,
                                        redirectURI: listener.redirectURI, registeredDynamically: false)
                registration = "Client ID from Advanced"
            } else if let reuse, reuse.redirectURI == listener.redirectURI {
                client = MCPOAuthClient(clientID: reuse.clientID, clientSecret: reuse.clientSecret, authMethod: nil,
                                        redirectURI: reuse.redirectURI, registeredDynamically: true)
                registration = "Dynamic client registration"
            } else {
                client = try await service.register(discovery.metadata, redirectURI: listener.redirectURI, provider: provider)
                registration = "Dynamic client registration"
            }
            set("registered", .done, title: "Registered Shepherd with \(provider)", note: .some(registration))
            set("browser", .live)
            try Task.checkCancellation()

            // 3. The browser.
            let verifier = MCPPKCE.verifier()
            let wanted = MCPScopes.union(discovery.scopes(configured: oauth.scopes).isEmpty ? previous?.scopes ?? []
                                            : discovery.scopes(configured: oauth.scopes), missingScopes)
            guard let authorize = MCPOAuthService.authorizationURL(discovery, client: client, scopes: wanted, state: state,
                                                                   challenge: MCPPKCE.challenge(for: verifier)) else {
                throw MCPOAuthError.badResponse("The sign-in server’s authorize address isn’t valid.")
            }
            authorizationURL = authorize
            dependencies.openURL(authorize)
            let outcome = try await listener.wait()
            let code: String
            switch outcome {
            case .code(let value): code = value
            case .denied(let error, let description): throw MCPOAuthError.denied(error: error, description: description)
            }

            // 4. The token.
            let token = try await service.exchange(code: code, verifier: verifier, discovery: discovery, client: client,
                                                   requestedScopes: wanted, nowMs: MCPStore.ms(dependencies.now()))
            set("browser", .done, title: token.account.map { "Signed in as \($0)" } ?? "Signed in",
                note: .some(token.scopes.isEmpty ? nil : "Access: " + token.scopes.joined(separator: ", ")))
            model.subtitle = "Checking \(server)…"
            let result = try await complete(token)
            switch result {
            case .connected(_, _, let tools)?:
                model.subtitle = "\(server) is connected: \(tools.count) tool\(tools.count == 1 ? "" : "s")."
            default:
                model.subtitle = "Signed in. \(server) connects when an agent uses it."
            }
            model.phase = .done
            succeeded = true
        } catch is CancellationError {
            return
        } catch MCPOAuthError.cancelled {
            return
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        let failing = live ?? "browser"
        let text = (error as? MCPOAuthError)?.description ?? error.localizedDescription
        switch (failing, error as? MCPOAuthError) {
        case (_, .denied(let code, let description)?):
            set(failing, .failed, title: "\(provider) didn’t allow access",
                note: .some("\(code): \(description ?? "you chose Cancel on \(domain).")"))
        case ("found", _):
            set(failing, .failed, title: "Couldn’t find \(provider)’s sign-in server", note: .some(text))
        case ("registered", _):
            set(failing, .failed, title: "Couldn’t register Shepherd with \(provider)", note: .some(text))
        default:
            set(failing, .failed, title: "Signing in didn’t finish", note: .some(text))
        }
        model.subtitle = "Nothing was saved."
        model.details = String(describing: error)
        model.phase = .failed
    }
}
