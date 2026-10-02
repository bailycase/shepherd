import Foundation
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The `zsh` command `MCPPiConfig` writes for a stdio server, run for real: pi hands a server its
/// whole environment, so the wrapper must leave a server the secrets its own `env` named (pi expands
/// them into other variables) and none of the others', and must expand a reference in its arguments
/// before it drops them. `/usr/bin/env` is the server: it prints what it was started with.
@Suite("MCP stdio wrapper", .integrationTimeLimit)
struct MCPStdioWrapperTests {
    private struct Started {
        var arguments: [String]
        var environment: [String: String]
    }

    /// Derives `servers`, then starts the entry called `name` the way pi would: with its own
    /// environment (secrets included) plus the `env` entries it expanded.
    private func run(_ servers: [String: [String: JSONValue]], name: String, piEnvironment: [String: String], expanded: [String: String] = [:]) throws -> Started {
        let document = MCPConfigDocument(root: [MCPConfigDocument.serversKey: .object(servers.mapValues(JSONValue.object))], order: servers.keys.sorted())
        let derived = MCPPiConfig.derive(document, home: "/Users/test")
        guard case .success(.object(let root)) = MCPJSON.parse(derived.json), case .object(let all)? = root["mcpServers"],
              case .object(let entry)? = all[name], let command = entry["command"]?.stringValue else {
            throw Failure("\(name) is not in the derived file")
        }
        let arguments = (entry["args"]?.arrayValue ?? []).compactMap(\.stringValue)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.environment = piEnvironment.merging(expanded) { _, new in new }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var environment: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            environment[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return Started(arguments: arguments, environment: environment)
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private let piEnvironment = [
        "PATH": "/usr/bin:/bin", "HOME": "/Users/test",
        "SHEPHERD_MCP_SECRET_ONE_T": "secret-one", "SHEPHERD_MCP_SECRET_TWO_T": "secret-two", "FROM_LOGIN_SHELL": "ok",
    ]

    @Test func aServerKeepsOnlyWhatItsOwnEnvAskedFor() throws {
        let started = try run([
            "one": ["command": .string("/usr/bin/env"), "env": .object(["T": .string("${keychain:one/T}")])],
            "two": ["command": .string("/usr/bin/env"), "env": .object(["T": .string("${keychain:two/T}")])],
        ], name: "one", piEnvironment: piEnvironment, expanded: ["T": "secret-one"])
        #expect(started.environment["T"] == "secret-one")
        #expect(started.environment["FROM_LOGIN_SHELL"] == "ok", "the rest of pi's environment is untouched")
        #expect(started.environment.keys.filter { $0.hasPrefix("SHEPHERD_MCP_SECRET_") }.isEmpty, "no secret variable reaches the server")
        #expect(!started.environment.values.contains("secret-two"), "another server's secret never does")
    }

    @Test func aReferenceInAnArgumentIsExpandedBeforeTheSecretsAreDropped() throws {
        let started = try run([
            "one": ["command": .string("/usr/bin/env"), "args": .array([.string("URI=${keychain:one/T}"), .string("LOGIN=${FROM_LOGIN_SHELL}"), .string("DEFAULT=${NOT_SET:-fallback}"),
                                                                        .string("QUOTE=it's \"fine\" $5")])],
        ], name: "one", piEnvironment: piEnvironment)
        #expect(started.environment["URI"] == "secret-one")
        #expect(started.environment["LOGIN"] == "ok")
        #expect(started.environment["DEFAULT"] == "fallback")
        #expect(started.environment["QUOTE"] == "it's \"fine\" $5", "what is not a reference reaches the server as written")
        #expect(started.environment.keys.filter { $0.hasPrefix("SHEPHERD_MCP_SECRET_") }.isEmpty)
    }

    @Test func aHomeFolderInAnArgumentIsTheUsersHome() throws {
        let started = try run([
            "one": ["command": .string("/bin/sh"), "args": .array([.string("-c"), .string("echo DIR=$0"), .string("~/data")]),
                    "env": .object(["T": .string("${keychain:one/T}")])],
        ], name: "one", piEnvironment: piEnvironment)
        #expect(started.environment["DIR"] == "/Users/test/data")
    }

    @Test func withNoSecretInPlayTheEntryIsLeftToPi() throws {
        // No wrapper at all: the entry is pi's to start, unchanged.
        let derived = MCPPiConfig.derive(MCPConfigDocument(root: [MCPConfigDocument.serversKey: .object(["plain": .object(["command": .string("/usr/bin/env")])])], order: ["plain"]),
                                         home: "/Users/test")
        #expect(derived.secrets.isEmpty)
        #expect(String(decoding: derived.json, as: UTF8.self).contains("\"command\": \"/usr/bin/env\""))
    }
}
