import Foundation
import ShepherdProtocol

/// HTTP for the Add sheet's check of a pasted URL; tests hand in a session pointed at a fake server on 127.0.0.1.
protocol MCPHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// The response's head only, for a stream that never ends (a legacy SSE endpoint).
    func headers(_ request: URLRequest) async throws -> HTTPURLResponse
}

extension MCPHTTP {
    func headers(_ request: URLRequest) async throws -> HTTPURLResponse {
        try await send(request).1
    }
}

struct URLSessionHTTP: MCPHTTP {
    var session: URLSession = URLSession(configuration: .ephemeral)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    func headers(_ request: URLRequest) async throws -> HTTPURLResponse {
        let (bytes, response) = try await session.bytes(for: request)
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return http
    }
}

/// The Add sheet's check of a pasted URL: one unauthenticated `initialize`. It says whether the
/// server answered, over what, and whether it wants a sign-in (the 401). pi lists the tools once
/// the server is added.
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
                        return .failed("\(url.host ?? "The server") only speaks the legacy SSE transport, which pi’s MCP doesn’t support. "
                            + "Use its Streamable HTTP address.")
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
