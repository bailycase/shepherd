import Combine
import Foundation
import ShepherdCore
import ShepherdRemote

@MainActor
final class HostConnection: ObservableObject {
    struct Configuration: Codable, Equatable {
        var name: String
        var host: String
        var port: UInt16
    }

    enum Phase: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: return "disconnected"
            case .connecting: return "connecting"
            case .connected: return "connected"
            case .failed(let reason): return "disconnected: \(reason)"
            }
        }
    }

    static let defaultsKey = "shepherd.ios.host"
    @Published private(set) var configuration: Configuration?
    @Published private(set) var phase: Phase = .disconnected
    @Published private(set) var state = ShepherdState()
    private(set) var client: RemoteHostClient?
    private let defaults: UserDefaults
    private var connectionTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryDelay = 1
    private var foreground = false
    private var generation = UUID()
    private var stateRevision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey) {
            configuration = try? JSONDecoder().decode(Configuration.self, from: data)
        }
    }

    func save(name: String, host: String, port: String, token: String) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              let port = UInt16(port), port > 0, !token.isEmpty else {
            throw NSError(domain: "ShepherdIOS", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Enter a hostname or IP address, a port from 1 to 65535, and a bearer token.",
            ])
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = Configuration(name: name.isEmpty ? host : name, host: host, port: port)
        let data = try JSONEncoder().encode(config)
        try HostTokenStore.save(token)
        stop()
        configuration = config
        state = ShepherdState()
        defaults.set(data, forKey: Self.defaultsKey)
        reconnect()
    }

    func forget() throws {
        try HostTokenStore.remove()
        stop()
        configuration = nil
        state = ShepherdState()
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    func setForeground(_ active: Bool) {
        guard active != foreground else { return }
        foreground = active
        if active { reconnect() } else { stop() }
    }

    func reconnect() {
        stop()
        retryDelay = 1
        if foreground { connect() }
    }

    func stop() {
        generation = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        retryTask?.cancel()
        retryTask = nil
        let previous = client
        client = nil
        previous?.disconnect()
        phase = .disconnected
    }

    private func connect() {
        guard foreground, let configuration else { return }
        let token: String
        do {
            guard let saved = try HostTokenStore.read(), !saved.isEmpty else {
                phase = .failed("host token is missing; edit the connection")
                return
            }
            token = saved
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        generation = UUID()
        let attempt = generation
        let client = RemoteHostClient()
        self.client = client
        phase = .connecting
        let revision = stateRevision
        client.onStateChanged = { [weak self] state in
            guard let self, self.generation == attempt else { return }
            self.stateRevision &+= 1
            self.state = state
        }
        client.onDisconnected = { [weak self] reason in
            guard let self, self.generation == attempt else { return }
            self.failed(reason, attempt: attempt)
        }
        connectionTask = Task { [weak self] in
            do {
                let state = try await client.connect(
                    host: configuration.host, port: configuration.port,
                    token: token, clientName: "Shepherd iOS"
                )
                guard let self, !Task.isCancelled, self.generation == attempt else {
                    client.disconnect()
                    return
                }
                // A push can arrive before the initial fetch resumes on the main actor.
                if self.stateRevision == revision { self.state = state }
                self.phase = .connected
                self.retryDelay = 1
            } catch {
                client.disconnect()
                guard !Task.isCancelled else { return }
                self?.failed(String(describing: error), attempt: attempt)
            }
        }
    }

    private func failed(_ reason: String, attempt: UUID) {
        guard generation == attempt else { return }
        stop()
        phase = .failed(reason)
        guard foreground else { return }
        let retryGeneration = generation
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.generation == retryGeneration else { return }
            self.connect()
        }
    }
}
