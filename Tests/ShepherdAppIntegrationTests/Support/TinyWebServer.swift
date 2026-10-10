import Foundation
import Network
import ShepherdTestSupport

/// A web server on 127.0.0.1 and an ephemeral port, for pages a real web view loads: fixtures by
/// path, a handler for anything dynamic. It never leaves the machine and stops with the test.
final class TinyWebServer: @unchecked Sendable {
    struct Request {
        var method: String
        var path: String
        var query: String
        var headers: [String: String]
    }

    struct Response {
        var status = 200
        var contentType = "text/html; charset=utf-8"
        var headers: [String: String] = [:]
        var body = Data()

        static func html(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers, body: Data(text.utf8))
        }
    }

    typealias Handler = @Sendable (Request) -> Response

    private let listener: NWListener
    private let connections = Locked<[NWConnection]>([])
    private let handler: Locked<Handler>
    /// Every path requested, in order.
    let requested = Locked<[String]>([])
    private(set) var port: UInt16 = 0

    init(_ handler: @escaping Handler = { _ in Response.html("<html><body>not found</body></html>", status: 404) }) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.handler = Locked(handler)
    }

    /// Serves `pages` by path; anything else is a 404.
    convenience init(pages: [String: String]) throws {
        try self.init { request in
            pages[request.path].map { Response.html($0) } ?? Response.html("<html><body>not found</body></html>", status: 404)
        }
    }

    func setHandler(_ handler: @escaping Handler) {
        self.handler.withValue { $0 = handler }
    }

    var origin: String { "http://127.0.0.1:\(port)" }

    func url(_ path: String) -> URL { URL(string: origin + path)! }

    func start(diagnostic: (@Sendable (String) -> Void)? = nil) async throws {
        listener.newConnectionHandler = { [self] connection in
            connections.withValue { $0.append(connection) }
            connection.start(queue: .global())
            receive(connection, bytes: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    diagnostic?("web-listener.ready")
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    diagnostic?("web-listener.failed")
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .setup: diagnostic?("web-listener.setup")
                case .waiting: diagnostic?("web-listener.waiting")
                case .cancelled: diagnostic?("web-listener.cancelled")
                @unknown default: diagnostic?("web-listener.unknown")
                }
            }
            diagnostic?("web-listener.start.before")
            listener.start(queue: .global())
            diagnostic?("web-listener.start.after")
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
        for connection in connections.current { connection.cancel() }
    }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, _ in
            let bytes = bytes + (data ?? Data())
            let text = String(decoding: bytes, as: UTF8.self)
            guard text.contains("\r\n\r\n") else {
                if !done { receive(connection, bytes: bytes) }
                return
            }
            respond(to: text, on: connection)
        }
    }

    private func respond(to text: String, on connection: NWConnection) {
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let target = parts.count > 1 ? String(parts[1]) : "/"
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = Request(method: parts.first.map(String.init) ?? "GET", path: String(pieces[0]),
                              query: pieces.count > 1 ? String(pieces[1]) : "", headers: headers)
        requested.withValue { $0.append(request.path) }
        let response = handler.current(request)
        var head = "HTTP/1.1 \(response.status) Test\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
