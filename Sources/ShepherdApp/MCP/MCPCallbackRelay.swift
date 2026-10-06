import Foundation
import Network

/// A remote OAuth callback only, never a general-purpose port proxy. Pi still verifies state and PKCE.
final class MCPCallbackRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "shepherd.mcp-callback")
    private let listener: NWListener
    private let callback: URL
    private let state: String
    private let complete: @Sendable (String) -> Void
    private var connections: [UUID: NWConnection] = [:]

    init(authorizationURL: URL, complete: @escaping @Sendable (String) -> Void) throws {
        let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let address = items.first(where: { $0.name == "redirect_uri" })?.value.flatMap(URL.init(string:)),
              address.scheme == "http", let host = address.host,
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host), address.user == nil, address.password == nil,
              let port = address.port, (1024...65535).contains(port),
              let state = items.first(where: { $0.name == "state" })?.value, !state.isEmpty else {
            throw MCPCallbackError("The server didn't provide a supported loopback OAuth callback.")
        }
        self.callback = address; self.state = state; self.complete = complete
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host == "localhost" ? "127.0.0.1" : host.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")), port: NWEndpoint.Port(rawValue: UInt16(port))!)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var resumed = false
                listener.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready: resumed = true; continuation.resume()
                    case .failed: resumed = true; continuation.resume(throwing: MCPCallbackError("The OAuth callback port is in use on this Mac. Free it and try again."))
                    case .cancelled: resumed = true; continuation.resume(throwing: CancellationError())
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
            }
        } onCancel: { self.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 4 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.close(id) }
        receive(connection, id: id, data: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, ended, error in
            guard let self, self.connections[id] != nil else { return }
            let data = data + (bytes ?? Data())
            guard data.count <= 8192, error == nil else { self.close(id); return }
            let text = String(decoding: data, as: UTF8.self)
            guard text.contains("\r\n\r\n") else {
                if ended { self.close(id) } else { self.receive(connection, id: id, data: data) }
                return
            }
            let parts = text.components(separatedBy: "\r\n")[0].split(separator: " ")
            var valid = false
            if parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/"),
               let url = URL(string: String(parts[1]), relativeTo: self.callback)?.absoluteURL,
               url.path == self.callback.path, url.host == self.callback.host, url.port == self.callback.port,
               URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value == self.state {
                self.complete(url.absoluteString)
                valid = true
            }
            let body = valid ? "Return to Shepherd to finish signing in. You may close this page." : "Invalid or expired OAuth callback."
            let response = "HTTP/1.1 \(valid ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in self?.queue.async { self?.close(id) } })
        }
    }
    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
    func cancel() {
        listener.cancel()
        queue.async { [self] in
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }
    deinit { listener.cancel() }
}

struct MCPCallbackError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
