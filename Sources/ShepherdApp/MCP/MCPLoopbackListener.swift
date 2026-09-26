import Foundation
import Network

/// The OAuth redirect's one-shot listener: 127.0.0.1 only, `http://127.0.0.1:<port>/callback`.
/// It accepts the single GET whose `state` matches, answers anything else with 400 or 404 and
/// keeps waiting, and gives up after `timeout` or `cancel()`.
final class MCPLoopbackListener: @unchecked Sendable {
    enum Outcome: Equatable, Sendable {
        case code(String)
        /// The provider said no (`error=access_denied`), with its own words when it gave some.
        case denied(error: String, description: String?)
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "shepherd.mcp.loopback")
    private let expectedState: String
    private let preferredPort: UInt16
    private var continuation: CheckedContinuation<Outcome, Error>?
    private var result: Result<Outcome, Error>?
    private var timeoutWork: DispatchWorkItem?

    /// The bound port, once `start` returns.
    private(set) var port: UInt16 = 0

    var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    /// Listens on 127.0.0.1 at `preferredPort` (a registered redirect's); with 0, or when that
    /// port is taken, on a random one.
    init(state: String, preferredPort: UInt16 = 0) {
        expectedState = state
        self.preferredPort = preferredPort
    }

    /// Starts listening; returns once the port is known.
    func start() async throws {
        if preferredPort != 0, (try? await listen(on: preferredPort)) != nil { return }
        try await listen(on: 0)
    }

    private func listen(on port: UInt16) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            // State updates arrive on `queue`, one at a time.
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue ?? 0
                    if resumed.claim() { ready.resume() }
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    if resumed.claim() { ready.resume(throwing: error) } else { self.finish(.failure(error)) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
        queue.sync { self.listener = listener }
    }

    /// Waits for the redirect.
    func wait(timeout: TimeInterval = 600) async throws -> Outcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result {
                        continuation.resume(with: result)
                        return
                    }
                    self.continuation = continuation
                    let work = DispatchWorkItem { self.finish(.failure(MCPOAuthError.timedOut)) }
                    self.timeoutWork = work
                    self.queue.asyncAfter(deadline: .now() + timeout, execute: work)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(MCPOAuthError.cancelled)) }
    }

    private func finish(_ outcome: Result<Outcome, Error>) {
        guard result == nil else { return }
        result = outcome
        timeoutWork?.cancel()
        listener?.cancel()
        continuation?.resume(with: outcome)
        continuation = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil || complete || error != nil || buffer.count > 16_384 {
                self.respond(connection, request: String(decoding: buffer, as: UTF8.self))
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let line = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              var components = URLComponents(string: "http://127.0.0.1" + parts[1]), components.path == "/callback" else {
            send(connection, status: "404 Not Found", body: "Not found.")
            return
        }
        // The redirect's query is form-encoded: a raw `+` is a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard result == nil, query["state"] == expectedState else {
            send(connection, status: "400 Bad Request", body: "This sign-in link doesn’t match the one Shepherd opened.")
            return
        }
        if let error = query["error"] {
            send(connection, status: "200 OK", body: "Shepherd didn’t get access. You can close this tab.")
            finish(.success(.denied(error: error, description: query["error_description"])))
        } else if let code = query["code"], !code.isEmpty {
            send(connection, status: "200 OK", body: "Signed in. You can close this tab and go back to Shepherd.")
            finish(.success(.code(code)))
        } else {
            send(connection, status: "400 Bad Request", body: "The sign-in answer had no code.")
        }
    }

    private func send(_ connection: NWConnection, status: String, body: String) {
        let html = "<!doctype html><meta charset=utf-8><title>Shepherd</title><p style=\"font:15px -apple-system;margin:40px\">\(body)</p>"
        let bytes = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Whether a continuation was resumed, touched only on the listener's queue.
private final class ResumeOnce: @unchecked Sendable {
    private var done = false

    func claim() -> Bool {
        defer { done = true }
        return !done
    }
}
