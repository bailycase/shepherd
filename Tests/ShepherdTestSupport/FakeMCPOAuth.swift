import Foundation

/// `Resources/fake-mcp-oauth.py`: a protected MCP server and its authorization server on
/// 127.0.0.1 (resource metadata, authorization-server metadata, dynamic registration, PKCE,
/// refresh). It serves until `stop()`.
public final class FakeMCPOAuth: @unchecked Sendable {
    public let port: Int
    private let process: Process
    private let input: Pipe

    public var base: String { "http://127.0.0.1:\(port)" }
    public var mcpURL: URL { URL(string: base + "/mcp")! }

    /// `deny` makes the authorize page answer `error=access_denied`, as if the user chose Cancel.
    /// `seed` is a sign-in already done: the access and refresh tokens it holds are valid.
    public init(deny: Bool = false, seed: (access: String, refresh: String, scope: String)? = nil) throws {
        let path = Bundle.module.url(forResource: "fake-mcp-oauth", withExtension: "py")!.path
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", path]
        var environment = ProcessInfo.processInfo.environment
        environment["FAKE_OAUTH_DENY"] = deny ? "1" : "0"
        environment["FAKE_OAUTH_SEED"] = seed.map { "\($0.access) \($0.refresh) \($0.scope)" }
        process.environment = environment
        input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // The first line is the port.
        var line = Data()
        while true {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty || byte == Data("\n".utf8) { break }
            line.append(byte)
        }
        guard let port = Int(String(decoding: line, as: UTF8.self)) else {
            process.terminate()
            throw CommandFailure("fake-mcp-oauth.py", "no port on its first line")
        }
        self.port = port
    }

    /// Every request the fake saw: method, path, body and Authorization header.
    public func log() async throws -> [[String: String]] {
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: URL(string: base + "/log")!)
        return (try JSONSerialization.jsonObject(with: data) as? [[String: String]]) ?? []
    }

    /// The 401 a request without a token gets, as `WWW-Authenticate`.
    public func challenge() async throws -> String? {
        var request = URLRequest(url: mcpURL)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate")
    }

    public func stop() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}
