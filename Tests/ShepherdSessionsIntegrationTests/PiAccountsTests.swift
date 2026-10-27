import Foundation
import Testing
@testable import ShepherdSessions
import ShepherdTestSupport

/// Several accounts per provider: auth.json holds the active one, switching saves it back first,
/// and rotation on a limit stops once every account has hit one. Every credential is a fake.
@Suite("Saved accounts", .integrationTimeLimit)
struct PiAccountsTests {
    let dir: URL
    let accounts: PiAccounts

    init() throws {
        dir = try makeScratchDirectory("acct")
        accounts = PiAccounts(directory: dir)
    }

    func signIn(_ token: String) throws {
        _ = try PiSettingsFile(url: dir.appendingPathComponent("auth.json")).update { auth in
            auth["anthropic"] = ["type": "oauth", "refresh": token]
            return []
        }
    }

    func activeToken() throws -> String? {
        let data = try Data(contentsOf: dir.appendingPathComponent("auth.json"))
        let auth = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (auth["anthropic"] as? [String: Any])?["refresh"] as? String
    }

    /// Two accounts signed in through Add account, A first.
    func twoAccounts() throws -> (a: String, b: String) {
        try signIn("A1")
        try accounts.beginAdding("anthropic")
        try signIn("B1")
        try accounts.landed("anthropic", adding: true)
        let list = try #require(accounts.lists()["anthropic"])
        return (list.accounts[0].id, list.accounts[1].id)
    }

    @Test("Adding keeps the first account, and switching saves the refreshed token back")
    func switching() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let (a, b) = try twoAccounts()
        #expect(accounts.lists()["anthropic"]?.accounts.map(\.name) == ["Account 1", "Account 2"])
        #expect(accounts.lists()["anthropic"]?.active == b)
        #expect(try activeToken() == "B1")

        // pi rotates B's refresh token while it is active.
        try signIn("B2")
        try accounts.activate("anthropic", a)
        #expect(try activeToken() == "A1")
        try accounts.activate("anthropic", b)
        #expect(try activeToken() == "B2")

        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(PiAccounts.fileName).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("Removing the active account switches to the next; removing the last signs out")
    func removing() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let (a, b) = try twoAccounts()
        try accounts.remove("anthropic", b)
        #expect(try activeToken() == "A1")
        #expect(accounts.lists()["anthropic"]?.active == a)
        try accounts.remove("anthropic", a)
        #expect(try activeToken() == nil)
        #expect(accounts.lists()["anthropic"] == nil)
    }

    @Test("Rotation moves past limited accounts and stops when all have hit a limit")
    func rotation() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let (a, b) = try twoAccounts()
        let now = Date()
        // Off by default.
        #expect(try accounts.rotate("anthropic", now: now) == nil)
        #expect(try activeToken() == "B1")

        try accounts.setRotate("anthropic", true)
        let first = try #require(try accounts.rotate("anthropic", now: now))
        #expect(first.from == "Account 2" && first.to == "Account 1")
        #expect(accounts.lists()["anthropic"]?.active == a)

        // Another agent's error from the old account moments later doesn't switch again.
        #expect(try accounts.rotate("anthropic", now: now.addingTimeInterval(5)) == nil)

        // A hits its limit too: B still sits out, so nothing switches.
        #expect(try accounts.rotate("anthropic", now: now.addingTimeInterval(PiAccounts.grace + 1)) == nil)
        #expect(accounts.lists()["anthropic"]?.active == a)
        #expect(accounts.lists()["anthropic"]?.accounts.allSatisfy { $0.limitedUntil != nil } == true)

        // Once B's cooldown passes, it is back in rotation.
        let later = now.addingTimeInterval(PiAccounts.cooldown + PiAccounts.grace + 2)
        #expect(try accounts.rotate("anthropic", now: later)?.to == "Account 2")
        #expect(accounts.lists()["anthropic"]?.active == b)
    }
}
