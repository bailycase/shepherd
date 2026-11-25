import Foundation
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A custom sign-in provider, end to end on the engine Shepherd ships: an OAuth extension added in
/// Settings ▸ Tools ▸ Extensions, listed in Sign-in as coming from it, signed in through the app's
/// own store and sheet session with its browser flow really completed (the "browser" is a request
/// that follows the extension's redirect to its callback), then signed out. No network: the
/// extension's authorization server is its own, on loopback.
///
/// Opt in: SHEPHERD_ENGINE_SMOKE=$PWD/.build/pi-engine swift test --filter ExtensionSignInEngineTests
@Suite("A custom sign-in extension on the bundled engine", .mainActorExclusive,
       .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_ENGINE_SMOKE"] != nil,
                "set SHEPHERD_ENGINE_SMOKE to a staged engine or disposable app"))
@MainActor
struct ExtensionSignInEngineTests {
    /// A provider whose login is a real authorization-code flow against a server it runs itself.
    static let extensionSource = #"""
    import * as http from "node:http";

    export default pi => {
      pi.registerProvider({
        id: "acme", name: "Acme",
        auth: { oauth: {
          name: "Acme account",
          async login(interaction) {
            const state = Math.random().toString(36).slice(2);
            let finish, fail;
            const code = new Promise((resolve, reject) => { finish = resolve; fail = reject; });
            const server = http.createServer((request, response) => {
              const url = new URL(request.url, "http://127.0.0.1");
              const port = server.address().port;
              if (url.pathname === "/authorize") {
                response.writeHead(302, { location: `http://127.0.0.1:${port}/callback?code=acme-code&state=${url.searchParams.get("state")}` });
                return response.end();
              }
              if (url.pathname === "/callback") {
                response.end("Signed in to Acme. You can close this tab.");
                return url.searchParams.get("state") === state ? finish(url.searchParams.get("code")) : fail(new Error("State mismatch"));
              }
              response.writeHead(404).end();
            });
            await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
            interaction.signal?.addEventListener("abort", () => fail(new Error("Login cancelled")));
            interaction.notify({ type: "auth_url", url: `http://127.0.0.1:${server.address().port}/authorize?state=${state}`, instructions: "Sign in to Acme" });
            try {
              if (await code !== "acme-code") throw new Error("Unexpected code");
              return { type: "oauth", access: "acme-access-not-a-secret", refresh: "acme-refresh-not-a-secret", expires: Date.now() + 3600000 };
            } finally {
              server.close();
            }
          },
          async refresh(credential) { return credential; },
          async toAuth(credential) { return { apiKey: credential.access }; },
        } },
        async usage(auth) {
          if (auth.apiKey !== "acme-access-not-a-secret") throw new Error("wrong token");
          return { windows: [{ name: "Month", usedPercent: 42 }], balance: { amount: 18.4, currency: "USD", label: "Credit" } };
        },
        getModels() { return []; },
        stream() { throw new Error("Sign-in must not request a completion"); },
        streamSimple() { throw new Error("Sign-in must not request a completion"); },
      });
      pi.registerCommand("acme-usage", { description: "Acme usage", handler() {} });
      // A balance for a built-in provider this extension doesn't own (as a DeepSeek balance extension would).
      pi.events.emit("shepherd:usage", { provider: "deepseek", async usage(auth) {
        return auth.apiKey === "sk-fixture-deepseek" ? { balance: { amount: 110, currency: "CNY" } } : undefined;
      } });
    };
    """#

    @Test func anAddedOAuthExtensionSignsInAndOutThroughTheApp() async throws {
        let location = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SHEPHERD_ENGINE_SMOKE"]))
        let engine = try #require(BundledPiEngine(contents: location) ?? BundledPiEngine(app: location))
        let root = try makeScratchDirectory("ext-signin")
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        let pi = PiSetup(engine: .bundled(engine), home: root.appendingPathComponent("support/pi", isDirectory: true),
                         yourPi: YourPiLocator(.fixed(nil)), userHome: user.path)
        #expect(pi.prepare() == nil)

        // Added in Settings ▸ Tools ▸ Extensions, as the Add… menu's File or folder does.
        let source = root.appendingPathComponent("acme-login.ts")
        try Data(Self.extensionSource.utf8).write(to: source)
        let copy = try pi.importedState().addExtension(from: source)

        let script = try PiSignInScript.install(in: root)
        let sdk = engine.packageDirectory.appendingPathComponent(BundledPiEngine.libraryPath).path
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = user.path
        let files = pi.files
        let auth = PiAuthStore(pi: pi, bridge: { _ in
            PiSignInBridge(line: PiLaunch.signInBridge(node: .executable(engine.node.path), script: script.path, sdk: sdk, home: files),
                           environment: environment)
        })
        // The browser: follows the authorization page's redirect to the extension's callback.
        auth.openURL = { url in Task.detached { _ = try? await URLSession.shared.data(from: url) } }
        auth.copy = { _ in }
        var landed: [String] = []
        auth.onSignedIn = { landed.append($0); return 0 }

        // Sign-in lists it, from the extension that registered it, with what else that extension adds.
        await auth.refreshProviders()
        #expect(auth.providersProblem == nil)
        #expect(auth.providers?.first { $0.id == "acme" }?.oauth == "Acme account")
        #expect(auth.providerOwners["acme"]?.destination == copy.destination)
        let inventory = try #require(auth.extensionInventory[copy.destination])
        #expect(PiExtensionSupport.make(inventory, scanned: []).adds == ["/acme-usage"])
        let survey = pi.importedState().survey()
        let page = PiSignInPage.make(survey: survey, providers: auth.providers, owners: auth.providerOwners)
        let row = try #require(page.subscriptions.first { $0.id == "acme" })
        #expect(row.source == "acme-login" && row.signInAvailable)

        // Signed in through the sheet's session, its browser flow completed.
        auth.signIn("acme")
        let session = try #require(auth.session)
        try await eventuallyOnMain("the Acme sign-in to land") {
            if case .failed(let reason) = session.phase { throw CommandFailure("acme sign-in", reason) }
            if case .done = session.phase { return true }
            return false
        }
        await auth.landing?.value
        #expect(landed == ["acme"])
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: pi.home.appendingPathComponent("auth.json"))) as? [String: Any]
        let credential = try #require(stored?["acme"] as? [String: Any])
        #expect(credential["type"] as? String == "oauth" && credential["access"] as? String == "acme-access-not-a-secret")
        auth.closeSheet()

        // Usage and balance from the extension's hooks: its own provider's, and DeepSeek's by its key.
        var stored2 = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: pi.home.appendingPathComponent("auth.json"))) as? [String: Any])
        stored2["deepseek"] = ["type": "api_key", "key": "sk-fixture-deepseek"]
        try JSONSerialization.data(withJSONObject: stored2).write(to: pi.home.appendingPathComponent("auth.json"))
        await auth.refreshUsage()
        #expect(auth.usage["acme"] == [PiUsageWindow(name: "Month", usedPercent: 42, resetsAt: nil)])
        #expect(auth.balances["acme"] == PiBalance(amount: 18.4, currency: "USD", label: "Credit"))
        #expect(auth.balances["deepseek"] == PiBalance(amount: 110, currency: "CNY"))
        #expect(PiSignInWords.balance(try #require(auth.balances["acme"]), locale: Locale(identifier: "en_US")) == "Credit $18.40")

        // Signed out of Shepherd's pi again.
        await auth.signOut("acme")
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: pi.home.appendingPathComponent("auth.json"))) as? [String: Any]
        #expect(after?["acme"] == nil)
    }
}
