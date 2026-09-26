import Foundation
import ShepherdProtocol
import ShepherdTestKit

/// One agent's bundled MCP extension, run on node by `Resources/mcp-agent.mjs` with pi's API stood
/// in: it connects to a real Shepherd socket as the agent its environment names, asks the app for
/// credentials and reports each server. `run` makes tool calls; `stop()` ends the session, which
/// stops every server the extension started.
public final class MCPAgentHarness: @unchecked Sendable {
    /// One tool call: the tool's name and its parameters.
    public struct Step: Encodable, Sendable {
        public var tool: String
        public var params: JSONValue

        public init(tool: String, params: JSONValue) {
            self.tool = tool
            self.params = params
        }

        /// A call of the `mcp` tool.
        public static func mcp(_ params: [String: JSONValue]) -> Step { Step(tool: "mcp", params: .object(params)) }
    }

    /// What one call returned: its text, or the error it threw.
    public struct Outcome: Decodable, Equatable, Sendable {
        public var ok: Bool
        public var text: String?
        public var error: String?
    }

    public struct Run: Decodable, Sendable {
        /// The tools the extension registered and left active.
        public var tools: [String]
        public var results: [Outcome]
    }

    private let process: Process
    private let input: Pipe
    private let output: Pipe
    public let stderrURL: URL

    /// The node the extension runs on, when it can strip TypeScript's types (22.6 or later).
    public static let node: URL? = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let places = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        guard let node = places.map({ URL(fileURLWithPath: $0).appendingPathComponent("node") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }
        let process = Process()
        process.executableURL = node
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let version = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().split(separator: ".").compactMap { Int($0) }
        guard version.count >= 2, version[0] > 22 || (version[0] == 22 && version[1] >= 6) else { return nil }
        return node
    }()

    /// `Tests/Extensions/fixtures/fake-mcp-stdio.mjs`, the scripted stdio server the node tests use.
    public static var stdioFixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Extensions/fixtures/fake-mcp-stdio.mjs")
    }

    /// Writes the extension and its client to `directory` and starts the session. `environment`
    /// holds the extension's variables (`SHEPHERD_EXT_MCP` is set here).
    public init(directory: URL, extensionSource: String, clientSource: String, environment: [String: String]) throws {
        guard let node = Self.node else { throw CommandFailure("node", "node 22.6 or later isn't on PATH") }
        let extensionURL = directory.appendingPathComponent("shepherd-mcp.ts")
        try Data(extensionSource.utf8).write(to: extensionURL)
        try Data(clientSource.utf8).write(to: directory.appendingPathComponent("shepherd-mcp-client.mjs"))
        let script = Bundle.module.url(forResource: "mcp-agent", withExtension: "mjs")!
        process = Process()
        process.executableURL = node
        process.arguments = ["--experimental-strip-types", "--no-warnings", script.path, extensionURL.path, directory.path]
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        env["SHEPHERD_EXT_MCP"] = extensionURL.path
        process.environment = env
        input = Pipe()
        output = Pipe()
        stderrURL = directory.appendingPathComponent("mcp-agent.stderr")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        try process.run()
    }

    /// Makes the calls in order and returns what each gave, without blocking the caller's thread.
    public func run(_ steps: [Step]) async throws -> Run {
        var line = try JSONEncoder().encode(steps)
        line.append(UInt8(ascii: "\n"))
        try input.fileHandleForWriting.write(contentsOf: line)
        let reader = output.fileHandleForReading
        let answer: Data = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var data = Data()
                while true {
                    let byte = reader.readData(ofLength: 1)
                    if byte.isEmpty || byte == Data("\n".utf8) { break }
                    data.append(byte)
                }
                continuation.resume(returning: data)
            }
        }
        guard let run = try? JSONDecoder().decode(Run.self, from: answer) else {
            let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
            throw CommandFailure("mcp-agent.mjs", "no results: \(String(decoding: answer, as: UTF8.self)) \(stderr)")
        }
        return run
    }

    /// Ends the session (the extension stops its servers) and waits for node to exit.
    public func stop() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}
