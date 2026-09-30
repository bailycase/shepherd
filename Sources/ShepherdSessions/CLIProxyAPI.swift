import Foundation

/// One optional connection, owned by Shepherd rather than an imported pi extension. The whole
/// connection is replaced atomically, so agents never read a new key with the old server URL.
public actor CLIProxyAPIStore {
    public static let provider = "cliproxyapi"
    public static let fileName = "shepherd-cliproxyapi.json"

    public struct Model: Codable, Equatable, Sendable {
        public var id: String
        public var owned_by: String?
    }

    struct Connection: Codable, Sendable {
        var enabled: Bool
        var baseURL: String
        var apiKey: String
        var models: [Model]
        var updatedAt: Double
    }

    /// Credentials never leave the store when Settings asks for its current state.
    public struct Snapshot: Equatable, Sendable {
        public var enabled: Bool
        public var baseURL: String
        public var modelCount: Int
        public var updatedAt: Date

        public init(enabled: Bool, baseURL: String, modelCount: Int, updatedAt: Date) {
            self.enabled = enabled
            self.baseURL = baseURL
            self.modelCount = modelCount
            self.updatedAt = updatedAt
        }
    }

    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let description: String
        init(_ message: String) { description = message }
    }

    private let pi: PiSetup
    private let session: URLSession
    private var busy = false

    public init(pi: PiSetup) {
        self.pi = pi
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }

    public func snapshot() throws -> Snapshot? {
        try load().map(Self.snapshot)
    }

    static func configured(in home: PiHome) -> Bool {
        let file = home.directory.appendingPathComponent(fileName)
        guard home.contains(file.path),
              let data = try? Data(contentsOf: file),
              let connection = try? JSONDecoder().decode(Connection.self, from: data) else { return false }
        return connection.enabled && !connection.apiKey.isEmpty && !connection.models.isEmpty
    }

    /// Connect and Refresh only replace a known-good connection after discovery succeeds.
    /// An empty key reuses the saved key only for the very same normalized address.
    public func connect(server: String, key: String) async throws -> Snapshot {
        guard !busy else { throw Failure("A connection check is already running.") }
        busy = true
        defer { busy = false }
        let url = try Self.baseURL(server)
        var key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty, let previous = try load(), previous.baseURL == url.absoluteString { key = previous.apiKey }
        guard !key.isEmpty else { throw Failure("Enter the API key for this server.") }
        guard Self.sendable(key) else {
            // The proxy's model list may not check keys, so a key pi can't send passes discovery.
            throw Failure("This key has a character a request can't carry, often a curly quote or \u{2026} from pasting. Paste the plain key.")
        }
        var request = URLRequest(url: url.appendingPathComponent("models"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data: Data
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw Failure("The server didn't return an HTTP response.") }
            switch response.statusCode {
            case 200: break
            case 401, 403: throw Failure("The server refused this API key. Check the key and try again.")
            case 300..<400: throw Failure("The server redirected the request. Enter its final address; Shepherd won't forward your key.")
            case 404: throw Failure("No model endpoint was found. Check the server address and its /v1 path.")
            default: throw Failure("The server couldn't list models (HTTP \(response.statusCode)). Try again later.")
            }
            var body = Data()
            for try await byte in bytes {
                guard body.count < 4 << 20 else { throw Failure("The server's model list is too large.") }
                body.append(byte)
            }
            data = body
        } catch let failure as Failure { throw failure }
        catch is CancellationError { throw CancellationError() }
        catch {
            // Never display an arbitrary server body, URLSession diagnostic or supplied key.
            throw Failure("Couldn't reach the server. Check its address, network connection and TLS certificate.")
        }
        let models = try Self.models(data)
        try Task.checkCancellation()
        let connection = Connection(enabled: true, baseURL: url.absoluteString, apiKey: key,
                                    models: models, updatedAt: Date().timeIntervalSince1970)
        try save(connection)
        return Self.snapshot(connection)
    }

    public func refresh() async throws -> Snapshot {
        guard let connection = try load() else { throw Failure("Set up a server first.") }
        return try await connect(server: connection.baseURL, key: "")
    }

    public func disable() throws -> Snapshot {
        guard !busy else { throw Failure("Wait for the connection check to finish.") }
        guard var connection = try load() else { throw Failure("Set up a server first.") }
        connection.enabled = false
        try save(connection)
        return Self.snapshot(connection)
    }

    public func forget() throws {
        guard !busy else { throw Failure("Wait for the connection check to finish.") }
        try ready()
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        pi.catalog.invalidate()
    }

    /// Whether pi can send `key` in an Authorization header: printable ASCII only. Node's fetch
    /// throws before connecting on anything else, which pi reports as a connection error.
    nonisolated static func sendable(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }

    public nonisolated static func baseURL(_ server: String) throws -> URL {
        let text = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = text.contains("://") ? text : "https://" + text
        guard !text.isEmpty, var parts = URLComponents(string: address),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw Failure("Enter an HTTP or HTTPS server address, without a login, query or fragment.")
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path.isEmpty { parts.path = "/v1" }
        guard let url = parts.url else { throw Failure("Enter a valid server address.") }
        return url
    }

    static func models(_ data: Data) throws -> [Model] {
        struct Response: Decodable { var data: [Model] }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              !response.data.isEmpty, response.data.count <= 10_000,
              response.data.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.id.utf8.count <= 1024
                  && !$0.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
            throw Failure("The server didn't return a valid, nonempty model list. The previous connection is unchanged.")
        }
        var seen = Set<String>()
        return response.data.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
    }

    private var file: URL { pi.home.appendingPathComponent(Self.fileName) }

    private func load() throws -> Connection? {
        guard pi.files.contains(file.path) else { throw Failure("The connection file leads outside Shepherd's pi home.") }
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let connection = try? JSONDecoder().decode(Connection.self, from: Data(contentsOf: file)) else {
            throw Failure("Shepherd couldn't read its CLIProxyAPI connection file.")
        }
        return connection
    }

    private func ready() throws {
        if let problem = pi.prepare() { throw Failure(problem.message) }
        guard pi.files.contains(file.path) else { throw Failure("The connection file leads outside Shepherd's pi home.") }
    }

    private func save(_ connection: Connection) throws {
        try ready()
        try PiHome.write(JSONEncoder().encode(connection), to: file, mode: 0o600)
        pi.catalog.invalidate()
    }

    private static func snapshot(_ connection: Connection) -> Snapshot {
        Snapshot(enabled: connection.enabled, baseURL: connection.baseURL, modelCount: connection.models.count,
                 updatedAt: Date(timeIntervalSince1970: connection.updatedAt))
    }
}

/// Even same-host redirects can change transport or request routing. Discovery only trusts the
/// exact address the user entered, and never sends the bearer key to a redirect destination.
private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
