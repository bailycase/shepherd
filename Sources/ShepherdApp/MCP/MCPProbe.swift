import Foundation
import ShepherdProtocol
import ShepherdSessions

/// What one probe of a server found.
enum MCPProbeResult: Equatable, Sendable {
    case connected(transport: MCPTransportKind?, serverName: String?, tools: [MCPToolInfo])
    case failed(MCPServerStatus, challenge: String?)

    /// Reads the client's one line: `{ok, transport, serverName, tools}` or
    /// `{ok: false, status: {state, scopes, message}, challenge?}`.
    static func parse(_ data: Data) -> MCPProbeResult {
        let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        struct Answer: Decodable {
            var ok: Bool
            var transport: MCPTransportKind?
            var serverName: String?
            var tools: [MCPToolInfo]?
            var status: MCPServerStatus?
            var challenge: String?
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: Data(line.utf8)) else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(MCPServerStatus(state: .error, message: text.isEmpty ? "The MCP client said nothing." : String(text.suffix(400))),
                           challenge: nil)
        }
        if answer.ok { return .connected(transport: answer.transport, serverName: answer.serverName, tools: answer.tools ?? []) }
        return .failed(answer.status ?? MCPServerStatus(state: .error, message: "The server didn’t answer."), challenge: answer.challenge)
    }
}

/// Runs the MCP client's `probe` for one entry. Injected, so unit tests don't need node.
protocol MCPProbeRunner: Sendable {
    /// `input` is one JSON object on stdin; the answer is the client's stdout.
    func run(input: Data, timeout: TimeInterval) async -> Data
}

/// The real runner: the same client agents use, run with the engine's node in a login shell, so
/// it finds exactly what an agent would: `/bin/zsh -l -c 'exec node "$0" probe' <client.mjs>`
/// (`PiLaunch.mcpProbe`).
struct NodeProbeRunner: MCPProbeRunner {
    /// Whose node runs the client.
    var engine: PiEngine
    /// The installed `shepherd-mcp-client.mjs`, or nil when it isn't there.
    var clientPath: @Sendable () -> URL?

    func run(input: Data, timeout: TimeInterval) async -> Data {
        guard let client = clientPath() else {
            return Self.failure("Shepherd couldn’t install its MCP client in its support folder.")
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runSync(line: PiLaunch.mcpProbe(engine: engine, client: client.path),
                                                            input: input, timeout: timeout))
            }
        }
    }

    private static func runSync(line: PiLaunch.Line, input: Data, timeout: TimeInterval) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: line.argv[0])
        process.arguments = Array(line.argv.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("SHEPHERD_") && key != "SHEPHERD_SUPPORT_DIR" { environment[key] = nil }
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let output = PipeBuffer(Data())
        let errors = PipeBuffer(Data())
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            output.withLock { $0.append(chunk) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            errors.withLock { $0.append(chunk); if $0.count > 8192 { $0 = $0.suffix(4096) } }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return failure("Couldn’t run node: \(error.localizedDescription)")
        }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); exited.wait() }
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return failure("The server didn’t answer within \(Int(timeout)) s.")
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        output.withLock { $0.append(stdout.fileHandleForReading.readDataToEndOfFile()) }
        let out = output.withLock { $0 }
        if process.terminationStatus == 127 {
            return failure("node isn’t on your login shell’s PATH, so Shepherd can’t check MCP servers. Agents are unaffected.")
        }
        if out.isEmpty {
            let text = String(decoding: errors.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return failure(text.isEmpty ? "The MCP client exited with status \(process.terminationStatus)." : String(text.suffix(400)))
        }
        return out
    }

    static func failure(_ message: String) -> Data {
        let object: [String: Any] = ["ok": false, "status": ["state": "error", "message": message]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

/// A lock around a value, for the runner's pipe handlers.
private final class PipeBuffer<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&value) }
    }
}

/// Probes an entry: its secrets and bearer are already resolved by the caller.
struct MCPProbe: Sendable {
    let runner: MCPProbeRunner

    func probe(name: String, entry: [String: JSONValue], timeoutSeconds: Int) async -> MCPProbeResult {
        let input: JSONValue = .object([
            "name": .string(name),
            "entry": .object(entry),
            "timeoutSeconds": .number(Double(timeoutSeconds)),
        ])
        let data = (try? JSONEncoder().encode(input)) ?? Data()
        return MCPProbeResult.parse(await runner.run(input: data, timeout: TimeInterval(timeoutSeconds + 5)))
    }
}

/// The Add sheet's check of a pasted URL: one unauthenticated `initialize`, which is also how
/// OAuth discovery starts. It says whether the server answered, over what, and whether it wants
/// a sign-in (the 401's challenge). The tools are listed by the probe after Add.
enum MCPURLCheck {
    enum Result: Equatable, Sendable {
        case answered(serverName: String?, transport: MCPTransportKind)
        case needsSignIn(challenge: String?)
        case failed(String)
    }

    static func check(_ url: URL, http: MCPHTTP, timeout: TimeInterval = 10) async -> Result {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                       "clientInfo": ["name": "shepherd", "version": "1"]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: initialize)
        do {
            let (data, response) = try await http.send(request)
            switch response.statusCode {
            case 200..<300:
                if let session = response.value(forHTTPHeaderField: "Mcp-Session-Id") {
                    var close = URLRequest(url: url, timeoutInterval: 5)
                    close.httpMethod = "DELETE"
                    close.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
                    _ = try? await http.send(close)
                }
                return .answered(serverName: serverName(in: data), transport: .streamableHTTP)
            case 401:
                return .needsSignIn(challenge: response.value(forHTTPHeaderField: "WWW-Authenticate"))
            case 400, 404, 405:
                var get = URLRequest(url: url, timeoutInterval: timeout)
                get.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                if let sse = try? await http.headers(get) {
                    if sse.statusCode == 401 { return .needsSignIn(challenge: sse.value(forHTTPHeaderField: "WWW-Authenticate")) }
                    if (sse.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
                        return .answered(serverName: nil, transport: .sse)
                    }
                }
                return .failed("\(url.host ?? "The server") answered HTTP \(response.statusCode).")
            default:
                return .failed("\(url.host ?? "The server") answered HTTP \(response.statusCode).")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// `serverInfo.title ?? name` from a JSON body or the first SSE `data:` line.
    static func serverName(in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        let candidates = [text] + text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            line.hasPrefix("data:") ? String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) : nil
        }
        for candidate in candidates {
            guard let object = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? [String: Any],
                  let result = object["result"] as? [String: Any],
                  let info = result["serverInfo"] as? [String: Any] else { continue }
            return (info["title"] as? String) ?? (info["name"] as? String)
        }
        return nil
    }
}
