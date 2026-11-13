import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// Sign-ins as units: which keys of pi's two files are units, that a write touches one key under pi's
/// lock and leaves every other as it is, and what a half written file or a kept out provider does.
/// Only fake values: no real provider, no real token.
@Suite("Fleet sign-in units")
struct FleetCredentialsSourceTests {
    struct Home {
        let dir: URL
        var auth: URL { dir.appendingPathComponent("auth.json") }
        var mcpAuth: URL { dir.appendingPathComponent("mcp-auth.json") }
        var exclusions: URL { dir.appendingPathComponent("credentials-excluded.json") }

        init() throws { dir = try makeTempDirectory() }
        func remove() { try? FileManager.default.removeItem(at: dir) }

        func providers() -> FleetCredentialsSource { FleetCredentialsSource(file: auth, kind: .providers, exclusions: exclusions) }
        func servers() -> FleetCredentialsSource { FleetCredentialsSource(file: mcpAuth, kind: .mcpServers, exclusions: exclusions) }

        func json(_ url: URL) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        }
    }

    static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    static let oauth = #"{"type":"oauth","access":"fake-access-1","refresh":"fake-refresh-1","expires":1790003600000}"#
    static let key = #"{"type":"api_key","key":"fake-key"}"#
    static let notionKey = "mcp__notion|https://mcp.notion.com/mcp"

    @Test func everyProviderOfAuthJSONIsAUnitCarryingItsEntryAsPiStoresIt() throws {
        let home = try Home()
        defer { home.remove() }
        try Data(#"{"acme-ai": \#(Self.oauth), "widgets": \#(Self.key), "odd": "not an object"}"#.utf8).write(to: home.auth)
        let source = home.providers()
        let values = source.read()
        #expect(Set(values.keys) == ["credential:acme-ai", "credential:widgets"])
        let raw = try #require(values["credential:acme-ai"])
        let entry = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(entry["refresh"] as? String == "fake-refresh-1" && entry["expires"] as? Int == 1_790_003_600_000)
        #expect(source.isCredential && source.owns("credential:anything") && !source.owns("mcpAuth:x") && !source.owns("setting:pi.theme"))
        #expect(!source.storesBlob("credential:acme-ai"), "a sign-in is a few hundred bytes: inline")
        #expect(source.watchedFiles == [home.auth])
        // The same entry reads the same on every Mac: keys sorted, so a hash of it is one value.
        let widgets = try #require(values["credential:widgets"])
        #expect(String(decoding: widgets, as: UTF8.self) == #"{"key":"fake-key","type":"api_key"}"#)
    }

    @Test func aServersSignInIsAUnitOnlyOnceItHasTokens() throws {
        let home = try Home()
        defer { home.remove() }
        let signedIn = #"{"tokens":{"access_token":"fake-a","refresh_token":"fake-r"},"clientInfo":{"client_id":"fake-client"}}"#
        // A sign-in under way holds a verifier and no tokens: not shared, so another Mac's flow is never overwritten with it.
        try Data(#"{"\#(Self.notionKey)": \#(signedIn), "mcp__linear|https://mcp.linear.app/mcp": {"codeVerifier":"fake-v"}}"#.utf8).write(to: home.mcpAuth)
        let source = home.servers()
        #expect(Set(source.read().keys) == ["mcpAuth:" + Self.notionKey])
        #expect(source.owns("mcpAuth:" + Self.notionKey) && !source.owns("credential:acme-ai"))
    }

    @Test func aWriteChangesOneKeyUnderPisLockAndLeavesTheRestAndTheModeAlone() throws {
        let home = try Home()
        defer { home.remove() }
        try Data(#"{"widgets": \#(Self.key)}"#.utf8).write(to: home.auth)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: home.auth.path)
        let source = home.providers()

        try source.write("credential:acme-ai", Data(Self.oauth.utf8), origin: "Mac mini")
        var object = try home.json(home.auth)
        #expect(Set(object.keys) == ["acme-ai", "widgets"], "the other provider is as it was")
        #expect((object["acme-ai"] as? [String: Any])?["access"] as? String == "fake-access-1")
        #expect(try Self.mode(home.auth) == 0o600, "a sign-in file is private")

        // A refresh is the same unit with a new value; a sign-out is its deletion.
        try source.write("credential:acme-ai", Data(#"{"type":"oauth","access":"fake-access-2","refresh":"fake-refresh-2","expires":1790007200000}"#.utf8), origin: "Mac mini")
        object = try home.json(home.auth)
        #expect((object["acme-ai"] as? [String: Any])?["refresh"] as? String == "fake-refresh-2")
        try source.write("credential:acme-ai", nil, origin: "Mac mini")
        #expect(Set(try home.json(home.auth).keys) == ["widgets"])
        #expect(!FileManager.default.fileExists(atPath: home.auth.path + ".lock"), "pi's lock is let go")
    }

    @Test func aDeletionWithNoFileMakesNoFileAndAValueThatIsNotASignInIsRefused() throws {
        let home = try Home()
        defer { home.remove() }
        let source = home.providers()
        try source.write("credential:acme-ai", nil, origin: "Mac mini")
        #expect(!FileManager.default.fileExists(atPath: home.auth.path))
        #expect(throws: FleetUnitRefused.self) { try source.write("credential:acme-ai", Data("[1]".utf8), origin: "Mac mini") }
        #expect(throws: FleetUnitRefused.self) { try source.write("credential:acme-ai", Data("{}".utf8), origin: "Mac mini") }
        #expect(!FileManager.default.fileExists(atPath: home.auth.path))
        // A first sign-in creates the file, private.
        try source.write("credential:acme-ai", Data(Self.oauth.utf8), origin: "Mac mini")
        #expect(try Self.mode(home.auth) == 0o600)
    }

    @Test func aFileThatIsBeingWrittenIsWaitedOutNeverReadAsEveryoneSignedOut() throws {
        let home = try Home()
        defer { home.remove() }
        let source = home.providers()
        #expect(source.isReady, "no file is no sign-ins")
        try Data(#"{"acme-ai": {"type":"oa"#.utf8).write(to: home.auth)
        #expect(!source.isReady, "half of a write")
        try Data().write(to: home.auth)
        #expect(!source.isReady, "a file just truncated")
        try Data("[]".utf8).write(to: home.auth)
        #expect(!source.isReady, "not an object")
        try Data("{}".utf8).write(to: home.auth)
        #expect(source.isReady && source.read().isEmpty, "a real sign out of everything is an empty object")
    }

    @Test func aProviderKeptOutIsNeitherReadNorWritten() throws {
        let home = try Home()
        defer { home.remove() }
        try Data(#"{"acme-ai": \#(Self.oauth), "widgets": \#(Self.key)}"#.utf8).write(to: home.auth)
        try Data(#"["acme-ai", "notion"]"#.utf8).write(to: home.exclusions)
        let source = home.providers()
        #expect(Set(source.read().keys) == ["credential:widgets"])
        do { try source.write("credential:acme-ai", Data(Self.oauth.utf8), origin: "Mac mini"); Issue.record("a kept out provider was written") }
        catch let refused as FleetUnitRefused { #expect(refused.quiet, "steady: not worth a log line at every pass") }

        // By the server's name, as a person spells it: pi's key swaps "-" for "_".
        try Data(#"{"\#(Self.notionKey)": {"tokens":{"access_token":"fake"}}}"#.utf8).write(to: home.mcpAuth)
        #expect(home.servers().read().isEmpty)
    }
}
