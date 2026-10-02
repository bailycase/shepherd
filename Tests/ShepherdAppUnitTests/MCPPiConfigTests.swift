import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdApp

/// pi's mcp.json, derived from the user's file (docs/mcp.md › How Shepherd maps onto it): the
/// servers pi can run, how their tools reach the model, and where each secret comes from.
@Suite("MCP config for pi")
struct MCPPiConfigTests {
    private func document(_ servers: [String: [String: JSONValue]], order: [String]? = nil) -> MCPConfigDocument {
        MCPConfigDocument(root: [MCPConfigDocument.serversKey: .object(servers.mapValues(JSONValue.object))], order: order ?? servers.keys.sorted())
    }

    private func derive(_ servers: [String: [String: JSONValue]], order: [String]? = nil) -> MCPPiConfig.Derived {
        MCPPiConfig.derive(document(servers, order: order), home: "/Users/test")
    }

    private func entries(_ derived: MCPPiConfig.Derived) throws -> [String: [String: JSONValue]] {
        guard case .success(.object(let root)) = MCPJSON.parse(derived.json), case .object(let servers)? = root["mcpServers"] else {
            Issue.record("not an mcpServers file")
            return [:]
        }
        return servers.compactMapValues { value in
            if case .object(let object) = value { return object }
            return nil
        }
    }

    private func args(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    // MARK: Exposure

    @Test func aServerWithNoChoiceIsSearchedNeverPisDefault() throws {
        let derived = derive(["files": ["command": .string("npx"), "args": .array([.string("-y"), .string("files")])]])
        let files = try #require(try entries(derived)["files"])
        #expect(files["exposure"] == .string("deferred"))
        #expect(files["command"] == .string("npx"))
        #expect(args(files["args"]) == ["-y", "files"])
        #expect(files["enabled"] == nil)
        #expect(files["timeout"] == nil)
    }

    @Test(arguments: [("direct", "direct"), ("proxy", "deferred"), ("unknown", "deferred")])
    func shepherdsExposureMapsToPis(stored: String, written: String) throws {
        let derived = derive(["s": ["command": .string("x"), "shepherd": .object(["exposure": .string(stored)])]])
        #expect(try entries(derived)["s"]?["exposure"] == .string(written))
    }

    @Test func chosenToolsHideTheServerAndExposeOnlyThoseInItsMode() throws {
        for (mode, expected) in [("proxy", "deferred"), ("direct", "direct")] {
            let derived = derive(["s": ["command": .string("x"), "shepherd": .object(["exposure": .string(mode), "tools": .array([.string("search"), .string("get")])])]])
            let s = try #require(try entries(derived)["s"])
            #expect(s["exposure"] == .string("hidden"))
            #expect(s["toolExposure"] == .object(["search": .string(expected), "get": .string(expected)]))
        }
    }

    @Test func aSwitchedOffServerStaysListedAsDisabledAndAnExplicitTimeoutIsKept() throws {
        let derived = derive(["s": ["command": .string("x"), "shepherd": .object(["enabled": .bool(false), "timeoutSeconds": .number(90)])]])
        let s = try #require(try entries(derived)["s"])
        #expect(s["enabled"] == .bool(false))
        #expect(s["timeout"] == .number(90))
    }

    @Test func shepherdsStartModesAndOtherToolsKeysAreNotCarriedOver() throws {
        let derived = derive(["s": ["command": .string("x"), "disabled": .bool(true), "autoApprove": .array([.string("a")]),
                                    "shepherd": .object(["start": .string("alwaysOn"), "idleMinutes": .number(3), "note": .string("n")])]])
        let s = try #require(try entries(derived)["s"])
        #expect(Set(s.keys) == ["command", "exposure"])
        #expect(!String(decoding: derived.json, as: UTF8.self).contains("shepherd"))
    }

    // MARK: Remote servers

    @Test func aRemoteServerSignsInAsShepherdUnlessItsOwnHeaderCarriesTheToken() throws {
        let derived = derive([
            "oauth": ["type": .string("http"), "url": .string("https://mcp.example.com/mcp")],
            "header": ["url": .string("https://mcp.example.com/other"), "headers": .object(["Authorization": .string("Bearer ${EXAMPLE_TOKEN}")])],
        ])
        let all = try entries(derived)
        #expect(all["oauth"]?["url"] == .string("https://mcp.example.com/mcp"))
        #expect(all["oauth"]?["type"] == nil)
        #expect(all["oauth"]?["oauth"] == .object(["clientName": .string("Shepherd")]))
        #expect(all["header"]?["oauth"] == nil)
        #expect(all["header"]?["headers"] == .object(["Authorization": .string("Bearer ${EXAMPLE_TOKEN}")]))
        #expect(derived.secrets.isEmpty)
    }

    @Test func addsAdvancedClientSettingsAreWhatPiRegistersWith() throws {
        let derived = derive(["s": ["url": .string("https://mcp.example.com/mcp"), "shepherd": .object(["oauth": .object([
            "clientId": .string("abc"), "clientSecret": .string("${keychain:s/OAUTH_CLIENT_SECRET}"), "scopes": .array([.string("read"), .string("write")]),
        ])])]])
        let oauth = try #require(try entries(derived)["s"]?["oauth"])
        #expect(oauth["clientName"] == .string("Shepherd"))
        #expect(oauth["clientId"] == .string("abc"))
        #expect(oauth["clientSecret"] == .string("${SHEPHERD_MCP_SECRET_S_OAUTH_CLIENT_SECRET}"))
        #expect(oauth["scope"] == .string("read write"))
        #expect(derived.secrets == [.init(variable: "SHEPHERD_MCP_SECRET_S_OAUTH_CLIENT_SECRET", server: "s", name: "OAUTH_CLIENT_SECRET")])
    }

    // MARK: Secrets

    @Test func aKeychainReferenceBecomesAVariableAndNoValueIsEverInTheFile() throws {
        let derived = derive([
            "github": ["url": .string("https://api.example.com/mcp"), "headers": .object(["Authorization": .string("Bearer ${keychain:github/Authorization}")])],
            "db": ["command": .string("uvx"), "args": .array([.string("postgres-mcp")]), "env": .object(["DATABASE_URI": .string("${keychain:db/DATABASE_URI}"), "MODE": .string("restricted")])],
        ])
        #expect(Set(derived.secrets.map(\.variable)) == ["SHEPHERD_MCP_SECRET_GITHUB_AUTHORIZATION", "SHEPHERD_MCP_SECRET_DB_DATABASE_URI"])
        let all = try entries(derived)
        #expect(all["github"]?["headers"] == .object(["Authorization": .string("Bearer ${SHEPHERD_MCP_SECRET_GITHUB_AUTHORIZATION}")]))
        #expect(all["db"]?["env"] == .object(["DATABASE_URI": .string("${SHEPHERD_MCP_SECRET_DB_DATABASE_URI}"), "MODE": .string("restricted")]))
        #expect(!String(decoding: derived.json, as: UTF8.self).contains("keychain"))
        #expect(Set(derived.secrets.map(\.account)) == ["secret/github/Authorization", "secret/db/DATABASE_URI"])
    }

    @Test func anotherServersItemIsReachedByItsOwnReference() throws {
        let derived = derive(["a": ["command": .string("x"), "env": .object(["T": .string("${keychain:b/TOKEN}")])]])
        #expect(try entries(derived)["a"]?["env"] == .object(["T": .string("${SHEPHERD_MCP_SECRET_B_TOKEN}")]))
        #expect(derived.secrets.first?.account == "secret/b/TOKEN")
    }

    @Test func twoItemsThatSanitizeToOneVariableGetTwo() {
        let derived = derive(["s": ["command": .string("x"), "env": .object(["A": .string("${keychain:s/X-Y}"), "B": .string("${keychain:s/X_Y}")])]])
        #expect(Set(derived.secrets.map(\.variable)) == ["SHEPHERD_MCP_SECRET_S_X_Y", "SHEPHERD_MCP_SECRET_S_X_Y_2"])
        #expect(Set(derived.secrets.map(\.name)) == ["X-Y", "X_Y"])
    }

    // MARK: Shell forms

    @Test func aShellDefaultMakesTheValueACommandPiRunsWithTheShell() throws {
        let derived = derive(["s": ["url": .string("https://x.example.com/mcp"), "headers": .object([
            "X-Plain": .string("${TOKEN}"), "X-Default": .string("Bearer ${TOKEN:-none} $5 \"q\" `x`"),
        ])]])
        let headers = try #require(try entries(derived)["s"]?["headers"])
        #expect(headers["X-Plain"] == .string("${TOKEN}"))
        #expect(headers["X-Default"] == .string("!printf '%s' \"Bearer ${TOKEN:-none} \\$5 \\\"q\\\" \\`x\\`\""))
    }

    @Test func aReferenceInAnArgumentIsExpandedByTheShellThatStartsTheServer() throws {
        let derived = derive(["pg": ["command": .string("uvx"), "args": .array([.string("postgres-mcp"), .string("--uri=${keychain:pg/URI}"), .string("--user=${USER:-me}"), .string("it's")]),
                                     "env": .object(["MODE": .string("x")])]])
        let pg = try #require(try entries(derived)["pg"])
        #expect(pg["command"] == .string("/bin/zsh"))
        #expect(args(pg["args"]) == ["-f", "-c", "a=('uvx' 'postgres-mcp' '--uri='\"${SHEPHERD_MCP_SECRET_PG_URI}\" '--user='\"${USER:-me}\" 'it'\\''s'); unset -m 'SHEPHERD_MCP_SECRET_*'; exec \"${a[@]}\""])
        #expect(pg["env"] == .object(["MODE": .string("x")]))
    }

    @Test func withAnySecretInPlayEveryStdioServerStartsWithoutThem() throws {
        let derived = derive([
            "a": ["command": .string("tool-a"), "args": .array([.string("--x"), .string("~/data")]), "env": .object(["T": .string("${keychain:a/T}")])],
            "b": ["command": .string("tool-b")],
            "web": ["url": .string("https://x.example.com/mcp")],
        ])
        let all = try entries(derived)
        for name in ["a", "b"] {
            let server = try #require(all[name])
            #expect(server["command"] == .string("/bin/zsh"))
            #expect(args(server["args"]).prefix(4) == ["-f", "-c", "unset -m 'SHEPHERD_MCP_SECRET_*'; exec \"$@\"", "shepherd-mcp"])
        }
        #expect(args(all["a"]?["args"]).suffix(3) == ["tool-a", "--x", "/Users/test/data"], "a ~/ is the shell's to expand, so the app does")
        #expect(args(all["b"]?["args"]).suffix(1) == ["tool-b"])
        #expect(all["web"]?["command"] == nil)
    }

    @Test func withNoSecretAServerIsStartedByPiItself() throws {
        let derived = derive(["b": ["command": .string("tool-b"), "args": .array([.string("--x")]), "cwd": .string("~/work")]])
        let b = try #require(try entries(derived)["b"])
        #expect(b["command"] == .string("tool-b"))
        #expect(args(b["args"]) == ["--x"])
        #expect(b["cwd"] == .string("~/work"))
    }

    // MARK: What pi can't run

    @Test func whatPiCannotRunIsLeftOutWithTheReasonForItsRow() throws {
        let derived = derive([
            "sse": ["type": .string("sse"), "url": .string("https://x.example.com/sse")],
            "templated": ["url": .string("https://${HOST}/mcp")],
            "folder": ["command": .string("x"), "cwd": .string("${PROJECT}")],
            "bad.name": ["command": .string("x")],
            "empty": [:],
            "ftp": ["url": .string("ftp://x.example.com")],
            "fine": ["command": .string("x")],
        ])
        #expect(derived.servers == ["fine"])
        #expect(Set(derived.problems.keys) == ["sse", "templated", "folder", "bad.name", "empty", "ftp"])
        #expect(derived.problems["sse"]?.contains("Streamable HTTP") == true)
        #expect(derived.problems["templated"]?.contains("URL") == true)
        #expect(derived.problems["bad.name"]?.contains("letters, digits") == true)
        #expect(derived.problems["ftp"]?.contains("http or https") == true)
        #expect(try entries(derived).keys.sorted() == ["fine"])
    }

    @Test func namesPiTreatsAsOneServerKeepTheFirst() {
        let derived = derive(["a-b": ["command": .string("x")], "a_b": ["command": .string("y")]], order: ["a-b", "a_b"])
        #expect(derived.servers == ["a-b"])
        #expect(derived.problems["a_b"]?.contains("a-b") == true)
    }

    // MARK: The file

    @Test func theFileKeepsTheUsersOrderAndReadsVSCodesKeyToo() throws {
        var document = MCPConfigDocument(root: [
            "mcpServers": .object(["zeta": .object(["command": .string("z")]), "alpha": .object(["command": .string("a")])]),
            "servers": .object(["vscode": .object(["command": .string("v")])]),
            "other": .bool(true),
        ], order: ["zeta", "alpha", "vscode"])
        let derived = MCPPiConfig.derive(document, home: "/h")
        #expect(derived.servers == ["zeta", "alpha", "vscode"])
        let text = String(decoding: derived.json, as: UTF8.self)
        #expect(text.range(of: "\"zeta\"")!.lowerBound < text.range(of: "\"alpha\"")!.lowerBound)
        #expect(!text.contains("other"))
        document.root["mcpServers"] = nil
        #expect(MCPPiConfig.derive(document, home: "/h").servers == ["vscode"])
    }

    @Test func noServersIsAnEmptyFile() {
        let derived = MCPPiConfig.derive(MCPConfigDocument(), home: "/h")
        #expect(derived.servers.isEmpty)
        #expect(String(decoding: derived.json, as: UTF8.self).contains("mcpServers"))
    }

    @Test func theSameDocumentAlwaysGivesTheSameBytes() {
        let servers: [String: [String: JSONValue]] = [
            "a": ["command": .string("x"), "env": .object(["A": .string("${keychain:a/A}"), "B": .string("${keychain:a/B}")])],
            "b": ["url": .string("https://x.example.com/mcp")],
        ]
        #expect(derive(servers).json == derive(servers).json)
    }
}
