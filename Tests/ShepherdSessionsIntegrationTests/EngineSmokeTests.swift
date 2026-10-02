import Foundation
import Testing
@testable import ShepherdSessions
import ShepherdTestSupport

/// The engine Shepherd ships, run for real: its node and pi against a scratch pi home, with the
/// child's HOME, TMPDIR and working directory scratch too, so it reads and writes nothing of
/// this machine's. It never reaches a model: the home's one provider points at a closed port
/// and no prompt is sent. Opt-in, because it needs a built app (or a staged engine):
///
///     python3 scripts/pi_engine.py stage
///     xcodebuild -scheme 'Shepherd (Dev)' … build
///     SHEPHERD_ENGINE_SMOKE=<DerivedData>/Build/Products/Debug/Shepherd.app \
///         swift test --filter EngineSmokeTests
///
/// `SHEPHERD_ENGINE_SMOKE` may also name `.build/pi-engine`, the staged tree.
@Suite("The bundled pi engine, run", .integrationTimeLimit,
       .enabled(if: EngineSmoke.engine != nil, "set SHEPHERD_ENGINE_SMOKE to a built Shepherd.app or a staged engine"))
struct EngineSmokeTests {
    @Test func itAnswersOverRPCLoadsATypeScriptExtensionAndRunsBashInItsOwnHome() async throws {
        let engine = try #require(EngineSmoke.engine)
        try await EngineSmoke.run(node: engine.node, engine: engine)
    }

    /// Through Shepherd's real launcher in a scratch Shepherd home: pi never sees the
    /// `NODE_OPTIONS` it was started with, and an RPC `bash` command finds `pi` at the launcher
    /// and gets that `NODE_OPTIONS` back (`restore-env.sh`, through `shellCommandPrefix`).
    @Test func throughTheLauncherBashFindsPiThereAndGetsTheStashedNodeOptionsBack() async throws {
        let engine = try #require(EngineSmoke.engine)
        try await EngineSmoke.runThroughLauncher(engine: engine)
    }

    /// The server binds an agent's browser connection to the pid of the pi it spawned
    /// (`SessionServer.helloBrowser`), which holds only while nothing between the shell and node
    /// forks: the extension's connection, made inside pi, is seen from the pid the app started.
    @Test func anExtensionInPiConnectsFromTheProcessTheAppStarted() async throws {
        let engine = try #require(EngineSmoke.engine)
        try await EngineSmoke.runPeerProcess(engine: engine)
    }

    /// An agent in the user's home folder, whose pi (`~/.pi/agent`) names packages and an
    /// extension and whose `~/.pi` is then the project's own config: Shepherd's pi loads none of
    /// their code, runs no npm, and leaves their pi byte-identical.
    @Test func anAgentInYourHomeLoadsNothingOfYourPi() async throws {
        let engine = try #require(EngineSmoke.engine)
        try await EngineSmoke.runInYourHome(engine: engine)
    }

    /// pi 1.0 loads its own MCP support (and codemode and tool search) in every session. In
    /// Shepherd's home it is off: the servers in the home's `mcp.json` (where pi reads user
    /// servers) are never started and `/mcp` is not offered, while llama.cpp, the built-in that
    /// stays, is. `+builtin:mcp` in the home's settings, the one switch pi documents, turns it on:
    /// the same file then starts the server and lists `/mcp`.
    @Test func piBuiltInMCPIsOffInShepherdsHomeUnlessSwitchedOn() async throws {
        let engine = try #require(EngineSmoke.engine)
        try await EngineSmoke.runBuiltIns(engine: engine)
    }

    /// What the bundle resolves from the engine's `node_modules`, with the engine's own node: the
    /// modules the keep-list ships, and codemode's QuickJS binary, which pi finds by name when a
    /// script runs (staged without it, a script fails with "Cannot find module").
    @Test func theBundleResolvesTheModulesTheEngineShips() throws {
        let engine = try #require(EngineSmoke.engine)
        let script = """
            const { createRequire } = require("node:module");
            const resolve = createRequire(process.argv[1]).resolve;
            for (const name of ["jiti", "@silvia-odwyer/photon-node", "quickjs-wasi/quickjs.wasm"]) console.log(resolve(name));
            """
        let result = try EngineSmoke.runTool(engine.node.path, ["-e", script, engine.entry.path], environment: [:])
        #expect(result.status == 0, "\(result.output)")
        let resolved = result.output.split(separator: "\n").map(String.init)
        let modules = engine.packageDirectory.appendingPathComponent("node_modules").standardizedFileURL.resolvingSymlinksInPath().path + "/"
        #expect(resolved.count == 3 && resolved.allSatisfy { $0.hasPrefix(modules) }, "each resolves inside the engine's node_modules: \(resolved)")
        #expect(resolved.last?.hasSuffix("/quickjs-wasi/quickjs.wasm") == true)
    }

    /// Skills come only from Shepherd's home: pi's own discovery of `$HOME/.agents/skills` is off
    /// (Shepherd's settings filter it out), so a skill there never reaches an agent, while one in
    /// the home's `skills/` does, and so do the ones copied from the user's pi and that folder.
    @Test func skillsComeOnlyFromShepherdsHomeNeverFromAgentsSkills() async throws {
        let engine = try #require(EngineSmoke.engine)
        try await EngineSmoke.runSkills(engine: engine)
    }

    /// The user's extensions, copied and switched on: one that throws as it loads stops pi with
    /// pi's own words, which switch it off with its reason; pi then starts without it, and the one
    /// that works loads from its copy in Shepherd's home.
    @Test func anExtensionOfYoursThatThrowsIsSwitchedOffAndTheOtherLoads() async throws {
        let engine = try #require(EngineSmoke.engine)
        try await EngineSmoke.runYourExtensions(engine: engine)
    }

    /// The sign-in bridge on the engine's own node and pi's own SDK (its bundle's `index.js`),
    /// against a scratch home: a key saved through pi's login lands in the home's auth.json as pi
    /// stores it, and pi's logout removes it. No network: a key's login asks nothing of the
    /// provider.
    @Test func theSignInBridgeSavesAndRemovesAKeyThroughPisOwnLogin() async throws {
        let engine = try #require(EngineSmoke.engine)
        let scratch = try makeScratchDirectory("engine-signin")
        let home = scratch.appendingPathComponent("pi", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let script = try PiSignInScript.install(in: scratch)
        let piHome = PiHome(directory: home, engine: PiEngine.bundled(engine))
        let sdk = engine.packageDirectory.appendingPathComponent(BundledPiEngine.libraryPath).path
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = scratch.path
        let bridge = PiSignInBridge(line: PiLaunch.signInBridge(node: .executable(engine.node.path), script: script.path, sdk: sdk, home: piHome),
                                   environment: environment)
        defer { bridge.close() }
        var replies = bridge.replies.makeAsyncIterator()
        func next(_ what: String, _ match: (PiSignInReply) -> Bool) async throws -> PiSignInReply {
            while let reply = await replies.next() {
                if match(reply) { return reply }
                if case .failed(let failure) = reply { throw CommandFailure(what, failure.reason) }
            }
            throw CommandFailure(what, "the bridge ended")
        }
        bridge.send(.login(provider: "deepseek", method: .apiKey, flow: .browser))
        guard case .prompt(let prompt) = try await next("pi's key prompt", { if case .prompt = $0 { true } else { false } }) else { return }
        #expect(prompt.kind == .secret)
        bridge.send(.answer(id: prompt.id, value: PiKeyInput.literal("sk-smoke-literal-0001").stored))
        _ = try await next("the key to land", { if case .done = $0 { true } else { false } })
        let auth = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("auth.json"))) as? [String: Any])
        #expect((auth["deepseek"] as? [String: Any])?["key"] as? String == "sk-smoke-literal-0001")

        bridge.send(.logout(provider: "deepseek"))
        _ = try await next("the sign-out", { $0 == .loggedOut(provider: "deepseek") })
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("auth.json"))) as? [String: Any]
        #expect(after?["deepseek"] == nil)
    }

    @Test func aCatalogReadsBuiltInAndExtensionCapabilitiesAndExitsOnInputEOF() throws {
        let engine = try #require(EngineSmoke.engine)
        let scratch = try makeScratchDirectory("engine-catalog")
        let home = PiHome(directory: scratch.appendingPathComponent("pi"), engine: .bundled(engine), userHome: scratch.path)
        try home.install()
        try Data(#"{"openai":{"type":"api_key","key":"fixture-only"}}"#.utf8).write(to: home.directory.appendingPathComponent("auth.json"))
        try Data(#"{"providers":{"fixture":{"baseUrl":"http://127.0.0.1:9/v1","apiKey":"fixture-only","api":"openai-responses","models":[{"id":"max","reasoning":true,"thinkingLevelMap":{"minimal":null,"xhigh":"xhigh","max":"max"}}]}}}"#.utf8)
            .write(to: home.directory.appendingPathComponent("models.json"))
        let connection = CLIProxyAPIStore.Connection(enabled: true, baseURL: "http://127.0.0.1:9/v1", apiKey: "fixture-only",
            models: [.init(id: "~openai/gpt-5.4", owned_by: "openai")], updatedAt: 1)
        try PiHome.write(JSONEncoder().encode(connection), to: home.directory.appendingPathComponent(CLIProxyAPIStore.fileName), mode: 0o600)
        let environment = ["HOME": scratch.path, "TMPDIR": scratch.path + "/", "ZDOTDIR": scratch.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let catalog = PiModelCatalog(home: home, timeout: 20, environment: environment, ready: { true })
        let entries = catalog.entries()
        let custom = try #require(entries.first { $0.id == "fixture/max" })
        #expect(custom.thinkingLevels == ["off", "low", "medium", "high", "xhigh", "max"])
        let builtIn = try #require(entries.first { $0.id == "openai/gpt-5.4" })
        let proxy = try #require(entries.first { $0.id == "cliproxyapi/~openai/gpt-5.4" })
        #expect(builtIn.thinkingLevels?.contains("xhigh") == true)
        #expect(proxy.thinkingLevels == builtIn.thinkingLevels && proxy.api == "openai-responses")
        let listing = catalog.listing()
        #expect(listing.defaultModel != nil, "pi supplies its automatic default when settings pin none")
        #expect(listing.offeredThinkingLevels("fixture/max").map(\.rawValue) == ["off", "low", "medium", "high", "xhigh", "max"])
        #expect(listing.offeredServiceTiers(proxy.id) == [.standard, .fast])
        #expect(!FileManager.default.fileExists(atPath: home.sessions.path), "reading capabilities creates no saved conversation")
    }

    @Test func managedProxyLoadsInIsolatedSessionsAndRefreshesWithoutRestarting() async throws {
        let engine = try #require(EngineSmoke.engine)
        let scratch = try makeScratchDirectory("engine-cpa")
        let files = FileManager.default
        let home = PiHome(directory: scratch.appendingPathComponent("pi"), engine: .bundled(engine), userHome: scratch.path)
        try home.install()
        let path = home.directory.appendingPathComponent(CLIProxyAPIStore.fileName)
        var connection = CLIProxyAPIStore.Connection(enabled: true, baseURL: "http://127.0.0.1:9/v1", apiKey: "!literal-$KEY",
            models: [.init(id: "fixture-model", owned_by: nil)], updatedAt: 1)
        try PiHome.write(JSONEncoder().encode(connection), to: path, mode: 0o600)
        let pi = try RPCProcess(executable: home.launcher.path,
            arguments: ["--mode", "rpc", "--no-session", "--no-extensions", "--model", "cliproxyapi/fixture-model"],
            directory: scratch, environment: ["HOME": scratch.path, "TMPDIR": scratch.path + "/", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        defer { pi.stop() }
        let state = try await pi.request(["type": "get_state"])
        #expect(state["success"] as? Bool == true, "\(pi.errors)")
        let model = (state["data"] as? [String: Any])?["model"] as? [String: Any]
        #expect(model?["provider"] as? String == "cliproxyapi")
        connection.models.append(.init(id: "second-model", owned_by: nil))
        connection.updatedAt = 2
        try PiHome.write(JSONEncoder().encode(connection), to: path, mode: 0o600)
        try await eventually("the existing runtime to adopt the new catalog") {
            let listing = try await pi.request(["type": "get_available_models"])
            let models = (listing["data"] as? [String: Any])?["models"] as? [[String: Any]] ?? []
            return models.contains { $0["provider"] as? String == "cliproxyapi" && $0["id"] as? String == "second-model" }
        }
        connection.enabled = false
        try PiHome.write(JSONEncoder().encode(connection), to: path, mode: 0o600)
        try await eventually("disabled proxy models to leave the existing runtime") {
            let listing = try await pi.request(["type": "get_available_models"])
            let models = (listing["data"] as? [String: Any])?["models"] as? [[String: Any]] ?? []
            return !models.contains { $0["provider"] as? String == "cliproxyapi" }
        }
        #expect(!pi.errors.contains("!literal-$KEY"))
        _ = try await pi.finish()
        #expect(!files.fileExists(atPath: scratch.appendingPathComponent(".pi").path))
    }

    /// Ad-hoc builds (the Dev scheme, CI's unsigned releases) run node without the hardened
    /// runtime. A Developer ID build turns it on, and V8 then needs the engine's entitlements:
    /// this signs a scratch copy the way `scripts/sign-app.sh` does, with the runtime, and runs it.
    @Test func theEngineEntitlementsAreEnoughUnderTheHardenedRuntime() async throws {
        let engine = try #require(EngineSmoke.engine)
        let scratch = try makeScratchDirectory("engine-sign")
        let node = scratch.appendingPathComponent("node")
        try FileManager.default.copyItem(at: engine.node, to: node)
        let scripts = EngineSmoke.repository.appendingPathComponent("scripts")
        let app = EngineSmoke.repository.appendingPathComponent("App")
        let signing = try EngineSmoke.runTool(scripts.appendingPathComponent("sign-engine.sh").path, [
            "--runtime", node.path, "-",
            app.appendingPathComponent("Engine.entitlements").path,
        ], environment: ["TMPDIR": scratch.path, "PATH": "/usr/bin:/bin"])
        #expect(signing.status == 0, "sign-engine.sh: \(signing.output)")
        let display = try EngineSmoke.runTool("/usr/bin/codesign", ["-dv", node.path], environment: [:])
        #expect(display.output.contains("runtime"), "the copy is signed with the hardened runtime: \(display.output)")

        try await EngineSmoke.run(node: node, engine: engine)
    }
}

enum EngineSmoke {
    static let engine: BundledPiEngine? = {
        guard let value = ProcessInfo.processInfo.environment["SHEPHERD_ENGINE_SMOKE"], !value.isEmpty else { return nil }
        let url = URL(fileURLWithPath: value)
        return url.pathExtension == "app" ? BundledPiEngine(app: url) : BundledPiEngine(contents: url)
    }()

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// A TypeScript extension (so jiti must compile it) that imports a value from pi's own
    /// package (so pi's virtual modules must resolve it) and registers a command whose
    /// description says which pi home it saw.
    static let fixtureExtension = """
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
        import { getAgentDir } from "@earendil-works/pi-coding-agent";

        const label: string = `smoke:${getAgentDir()}`;

        export default function (pi: ExtensionAPI): void {
          pi.registerCommand("engine-smoke", { description: label, handler: async () => {} });
        }

        """

    /// A provider pi can select without credentials of this machine's. Nothing calls it.
    static let models = """
        {"providers":{"fixture":{"baseUrl":"http://127.0.0.1:9/v1","api":"openai-completions",\
        "apiKey":"fixture-key","models":[{"id":"fixture-model"}]}}}
        """

    static func run(node: URL, engine: BundledPiEngine) async throws {
        let scratch = try makeScratchDirectory("engine-smoke")
        let files = FileManager.default
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let temporary = scratch.appendingPathComponent("tmp", isDirectory: true)
        let project = scratch.appendingPathComponent("project", isDirectory: true)
        let agent = scratch.appendingPathComponent("agent", isDirectory: true)
        for folder in [home, temporary, project, agent] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try models.write(to: agent.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)
        let fixture = scratch.appendingPathComponent("fixture.ts")
        try fixtureExtension.write(to: fixture, atomically: true, encoding: .utf8)

        let arguments = [engine.entry.path, "--mode", "rpc", "--no-session", "-e", fixture.path]
        let pi = try RPCProcess(executable: node.path, arguments: arguments, directory: project, environment: [
            "HOME": home.path,
            "TMPDIR": temporary.path + "/",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PI_CODING_AGENT_DIR": agent.path,
            "PI_PACKAGE_DIR": engine.packageDirectory.path,
            "PI_OFFLINE": "1",
            "PI_SKIP_VERSION_CHECK": "1",
            "PI_TELEMETRY": "0",
        ])
        defer { pi.stop() }

        let state = try await pi.request(["type": "get_state"])
        #expect(state["success"] as? Bool == true, "get_state: \(state) \(pi.errors)")
        let model = (state["data"] as? [String: Any])?["model"] as? [String: Any]
        #expect(model?["provider"] as? String == "fixture", "pi read the scratch home's models.json")

        let listing = try await pi.request(["type": "get_commands"])
        let commands = ((listing["data"] as? [String: Any])?["commands"] as? [[String: Any]]) ?? []
        let smoke = commands.first { $0["name"] as? String == "engine-smoke" }
        #expect(smoke?["description"] as? String == "smoke:\(agent.path)",
                "the TypeScript fixture loaded through jiti and saw the scratch home: \(commands) \(pi.errors)")

        let bash = try await pi.request(["type": "bash", "command": #"echo "smoke-$((6 * 7))"; echo "$PATH"; echo "$HOME""#])
        let output = ((bash["data"] as? [String: Any])?["output"] as? String) ?? ""
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.first == "smoke-42", "bash ran: \(bash)")
        #expect(lines.dropFirst().first?.hasPrefix(agent.appendingPathComponent("bin").path + ":") == true,
                "the pi home's bin leads the bash tool's PATH: \(output)")
        #expect(lines.dropFirst(2).first == home.path, "bash ran with the scratch HOME: \(output)")

        let status = try await pi.finish()
        #expect(status == 0, "pi exits cleanly when its input ends: \(pi.errors)")
        #expect(try files.contentsOfDirectory(atPath: home.path).isEmpty, "pi wrote nothing into HOME")
    }

    static func runThroughLauncher(engine: BundledPiEngine) async throws {
        let scratch = try makeScratchDirectory("engine-launcher")
        let files = FileManager.default
        let userHome = scratch.appendingPathComponent("home", isDirectory: true)
        let temporary = scratch.appendingPathComponent("tmp", isDirectory: true)
        let project = scratch.appendingPathComponent("project", isDirectory: true)
        for folder in [userHome, temporary, project] { try files.createDirectory(at: folder, withIntermediateDirectories: true) }
        let home = PiHome(directory: scratch.appendingPathComponent("support/pi", isDirectory: true), engine: .bundled(engine))
        try home.install()
        try models.write(to: home.directory.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)
        // Loaded by any node started with it: pi's must not be.
        let hook = scratch.appendingPathComponent("hook.cjs")
        let ran = scratch.appendingPathComponent("hook-ran")
        try "require('fs').appendFileSync(\(String(reflecting: ran.path)), 'ran\\n');\n".write(to: hook, atomically: true, encoding: .utf8)
        let nodeOptions = "--require=\(hook.path)"

        let pi = try RPCProcess(executable: home.launcher.path, arguments: ["--mode", "rpc", "--no-session"], directory: project, environment: [
            "HOME": userHome.path,
            "TMPDIR": temporary.path + "/",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "NODE_OPTIONS": nodeOptions,
            "PI_CODING_AGENT_DIR": scratch.appendingPathComponent("decoy").path,
        ])
        defer { pi.stop() }

        let state = try await pi.request(["type": "get_state"])
        #expect(state["success"] as? Bool == true, "get_state: \(state) \(pi.errors)")
        let model = (state["data"] as? [String: Any])?["model"] as? [String: Any]
        #expect(model?["provider"] as? String == "fixture", "pi read Shepherd's home, not the decoy")

        let bash = try await pi.request(["type": "bash", "command": #"command -v pi; printf '%s\n' "${NODE_OPTIONS-unset}" "${PI_CODING_AGENT_DIR-unset}""#])
        let output = ((bash["data"] as? [String: Any])?["output"] as? String) ?? ""
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.first == home.launcher.path, "a bare pi in an agent's shell is Shepherd's launcher: \(output) \(pi.errors)")
        #expect(lines.dropFirst().first == nodeOptions, "the stashed NODE_OPTIONS came back for the command: \(output)")
        #expect(lines.dropFirst(2).first == scratch.appendingPathComponent("decoy").path, "and so did the user's own pi folder")

        #expect(try await pi.finish() == 0, "pi exits cleanly when its input ends: \(pi.errors)")
        #expect(!files.fileExists(atPath: ran.path), "pi's own node never loaded NODE_OPTIONS")
        #expect(try files.contentsOfDirectory(atPath: userHome.path).isEmpty, "pi wrote nothing into HOME")
    }

    /// An extension that connects to the socket named in its environment and says hello, as the
    /// browser extension does.
    static let peerExtension = """
        import * as net from "node:net";

        export default function (): void {
          const socket = net.createConnection(process.env.SMOKE_PEER_SOCKET ?? "");
          socket.on("error", () => {});
          socket.write("hello\\n");
          socket.unref();
        }

        """

    /// Started the way the app starts an agent's pi (a login shell that `exec`s the launcher, which
    /// `exec`s node), an extension's connection comes from the pid the app spawned.
    static func runPeerProcess(engine: BundledPiEngine) async throws {
        let scratch = try makeScratchDirectory("engine-peer")
        let files = FileManager.default
        let userHome = scratch.appendingPathComponent("home", isDirectory: true)
        let temporary = scratch.appendingPathComponent("tmp", isDirectory: true)
        let project = scratch.appendingPathComponent("project", isDirectory: true)
        for folder in [userHome, temporary, project] { try files.createDirectory(at: folder, withIntermediateDirectories: true) }
        let home = PiHome(directory: scratch.appendingPathComponent("support/pi", isDirectory: true), engine: .bundled(engine))
        try home.install()
        try models.write(to: home.directory.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)
        let fixture = scratch.appendingPathComponent("peer.ts")
        try peerExtension.write(to: fixture, atomically: true, encoding: .utf8)

        let socketPath = scratch.appendingPathComponent("peer.sock").path
        let listener = try PeerListener(path: socketPath)
        defer { listener.close() }

        let command = "cd -- \(PiLaunch.quoted(project.path)) && exec \(PiLaunch.quoted(home.launcher.path)) --mode rpc --no-session -e \(PiLaunch.quoted(fixture.path))"
        let pi = try RPCProcess(executable: "/bin/zsh", arguments: ["-l", "-c", command], directory: project, environment: [
            "HOME": userHome.path,
            "TMPDIR": temporary.path + "/",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SMOKE_PEER_SOCKET": socketPath,
        ])
        defer { pi.stop() }

        let peer = await listener.peerProcess()
        #expect(peer != nil, "the extension connected and its pid could be read: \(pi.errors)")
        #expect(peer == pi.processIdentifier, "the extension connects from the process the app spawned: \(String(describing: peer)) vs \(pi.processIdentifier)")
        #expect(pi.isRunning, "pi kept running: \(pi.errors)")
    }

    static func runInYourHome(engine: BundledPiEngine) async throws {
        let scratch = try makeScratchDirectory("engine-your-home")
        let files = FileManager.default
        let userHome = scratch.appendingPathComponent("home", isDirectory: true)
        let temporary = scratch.appendingPathComponent("tmp", isDirectory: true)
        let bin = scratch.appendingPathComponent("bin", isDirectory: true)
        let yourPi = userHome.appendingPathComponent(".pi/agent", isDirectory: true)
        let marks = scratch.appendingPathComponent("marks", isDirectory: true)
        for folder in [temporary, bin, marks, yourPi.appendingPathComponent("extensions"), userHome.appendingPathComponent(".pi/extensions")] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // Code of the user's that marks it ran, wherever pi might find it.
        func marking(_ name: String) -> String {
            "import * as fs from \"node:fs\";\nfs.writeFileSync(\(String(reflecting: marks.appendingPathComponent(name).path)), \"ran\");\n"
                + "export default function () {}\n"
        }
        try marking("your-extension").write(to: yourPi.appendingPathComponent("extensions/theirs.ts"), atomically: true, encoding: .utf8)
        try marking("your-listed-extension").write(to: scratch.appendingPathComponent("listed.ts"), atomically: true, encoding: .utf8)
        try marking("project-extension").write(to: userHome.appendingPathComponent(".pi/extensions/project.ts"), atomically: true, encoding: .utf8)
        try #"{"packages":["npm:their-package"],"extensions":["\#(scratch.appendingPathComponent("listed.ts").path)"]}"#
            .write(to: yourPi.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try #"{"packages":["npm:project-package"]}"#.write(to: userHome.appendingPathComponent(".pi/settings.json"), atomically: true, encoding: .utf8)
        try models.write(to: yourPi.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)
        try "# Your instructions\n".write(to: yourPi.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        // npm, if anything ran it.
        let npm = bin.appendingPathComponent("npm")
        try "#!/bin/sh\necho \"$@\" >> \(String(reflecting: marks.appendingPathComponent("npm").path))\nexit 1\n"
            .write(to: npm, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npm.path)

        // Shepherd's home, with a package someone added to its settings by hand.
        let home = PiHome(directory: scratch.appendingPathComponent("support/pi", isDirectory: true), engine: .bundled(engine))
        try files.createDirectory(at: home.directory, withIntermediateDirectories: true)
        try #"{"packages":["npm:hand-added"]}"#.write(to: home.settings, atomically: true, encoding: .utf8)
        try home.install()
        try models.write(to: home.directory.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)
        let before = try tree(yourPi)

        let pi = try RPCProcess(executable: home.launcher.path, arguments: [
            "--mode", "rpc", "--session-dir", home.sessionDirectory(forCwd: userHome.path).path, "--session-id", "smoke-home",
        ], directory: userHome, environment: [
            "HOME": userHome.path,
            "TMPDIR": temporary.path + "/",
            "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
        ])
        defer { pi.stop() }

        let state = try await pi.request(["type": "get_state"])
        #expect(state["success"] as? Bool == true, "get_state: \(state) \(pi.errors)")
        _ = try await pi.request(["type": "get_commands"])
        #expect(try await pi.finish() == 0, "pi exits cleanly when its input ends: \(pi.errors)")

        #expect(try files.contentsOfDirectory(atPath: marks.path).isEmpty, "none of the user's code ran, and no npm")
        #expect(try tree(yourPi) == before, "your pi is byte-identical")
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: home.settings)) as? [String: Any])
        #expect(settings["packages"] == nil, "Shepherd's settings name no packages")
    }

    static func runBuiltIns(engine: BundledPiEngine) async throws {
        let scratch = try makeScratchDirectory("engine-builtins")
        let files = FileManager.default
        let userHome = scratch.appendingPathComponent("home", isDirectory: true)
        let temporary = scratch.appendingPathComponent("tmp", isDirectory: true)
        let project = scratch.appendingPathComponent("project", isDirectory: true)
        for folder in [userHome, temporary, project] { try files.createDirectory(at: folder, withIntermediateDirectories: true) }
        let home = PiHome(directory: scratch.appendingPathComponent("support/pi", isDirectory: true), engine: .bundled(engine),
                          userHome: userHome.path)
        try home.install()
        try models.write(to: home.directory.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)
        // A server in pi's own MCP file: starting it touches the marker.
        let marker = scratch.appendingPathComponent("mcp-server-started")
        let servers = ["mcpServers": ["probe": ["command": "/usr/bin/touch", "args": [marker.path]]]]
        try JSONSerialization.data(withJSONObject: servers).write(to: home.directory.appendingPathComponent("mcp.json"))
        let environment = ["HOME": userHome.path, "TMPDIR": temporary.path + "/", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

        func commandNames(_ pi: RPCProcess) async throws -> [String] {
            let listing = try await pi.request(["type": "get_commands"])
            #expect(listing["success"] as? Bool == true, "get_commands: \(listing) \(pi.errors)")
            let commands = ((listing["data"] as? [String: Any])?["commands"] as? [[String: Any]]) ?? []
            return commands.compactMap { $0["name"] as? String }
        }

        let off = try RPCProcess(executable: home.launcher.path, arguments: ["--mode", "rpc", "--no-session"], directory: project, environment: environment)
        defer { off.stop() }
        let offered = try await commandNames(off)
        #expect(offered.contains("llama") && !offered.contains("mcp"), "pi's MCP is off, llama.cpp is not: \(offered)")
        #expect(try await off.finish() == 0, "\(off.errors)")
        #expect(!files.fileExists(atPath: marker.path), "the server in the home's mcp.json was never started")

        try Data(#"{"extensions":["+builtin:mcp"]}"#.utf8).write(to: home.settings)
        try home.install()
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: home.settings)) as? [String: Any])
        #expect((settings["extensions"] as? [String])?.first == "+builtin:mcp", "a switch someone set is kept: \(settings)")
        let on = try RPCProcess(executable: home.launcher.path, arguments: ["--mode", "rpc", "--no-session"], directory: project, environment: environment)
        defer { on.stop() }
        #expect(try await commandNames(on).contains("mcp"))
        try await eventually("pi's MCP to start the server in the home's mcp.json") { files.fileExists(atPath: marker.path) }
        #expect(try await on.finish() == 0, "\(on.errors)")
    }

    static func runSkills(engine: BundledPiEngine) async throws {
        let scratch = try makeScratchDirectory("engine-skills")
        let files = FileManager.default
        let userHome = scratch.appendingPathComponent("home", isDirectory: true)
        let temporary = scratch.appendingPathComponent("tmp", isDirectory: true)
        let project = scratch.appendingPathComponent("project", isDirectory: true)
        for folder in [userHome, temporary, project] { try files.createDirectory(at: folder, withIntermediateDirectories: true) }
        func skill(_ folder: URL, _ name: String) throws {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: The \(name) fixture skill.\n---\nDo nothing.\n"
                .write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        // The user's pi, and a skill in ~/.agents/skills, both copied once into Shepherd's home.
        let yourPi = userHome.appendingPathComponent(".pi/agent", isDirectory: true)
        try skill(yourPi.appendingPathComponent("skills/yours"), "yours")
        try skill(userHome.appendingPathComponent(".agents/skills/agents-copied"), "agents-copied")
        let home = PiHome(directory: scratch.appendingPathComponent("support/pi", isDirectory: true), engine: .bundled(engine),
                          userHome: userHome.path)
        try home.install()
        try models.write(to: home.directory.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)
        try skill(home.directory.appendingPathComponent("skills/shepherds-own"), "shepherds-own")
        let report = YourPiImport(home: home, yourPi: YourPi(agentDirectory: yourPi), userHome: userHome.path, log: { _ in }).copyOnce()
        #expect(report.copied(.skills).map(\.name) == ["yours", "agents-copied"], "\(report.problems)")
        // Skills that reach ~/.agents/skills after the copy stay the user's.
        try skill(userHome.appendingPathComponent(".agents/skills/agents-only"), "agents-only")
        try skill(userHome.appendingPathComponent(".agents/skills/group/nested-agents"), "nested-agents")

        let names = try await skillNames(home: home, userHome: userHome, temporary: temporary, project: project)
        #expect(names == ["skill:agents-copied", "skill:shepherds-own", "skill:yours"],
                "Shepherd's own skills and the copies load, from its home: \(names)")
        #expect(!names.contains("skill:agents-only") && !names.contains("skill:nested-agents"),
                "no skill in $HOME/.agents/skills loads: \(names)")

        // A trusted project inside the home folder, outside any repository: pi also looks for
        // `.agents/skills` in every folder above it, and passes over the home folder's only when
        // that is `HOME` as written. A folder's path is its real one (getcwd), so HOME is too, as a
        // Mac's is (the scratch folder's isn't: /var is a link).
        let realHome = URL(fileURLWithPath: PiHome.canonical(userHome.path), isDirectory: true)
        let inside = realHome.appendingPathComponent("work/app", isDirectory: true)
        try skill(inside.appendingPathComponent(".agents/skills/project-own"), "project-own")
        let trust = try JSONSerialization.data(withJSONObject: [inside.path: true])
        try trust.write(to: home.directory.appendingPathComponent("trust.json"))
        let fromInside = try await skillNames(home: home, userHome: realHome, temporary: temporary, project: inside)
        #expect(fromInside.contains("skill:project-own"), "the trusted project's own skill loads: \(fromInside)")
        #expect(!fromInside.contains("skill:agents-only") && !fromInside.contains("skill:nested-agents"),
                "the home folder's never does, from a project inside it: \(fromInside)")
        try files.removeItem(at: home.directory.appendingPathComponent("trust.json"))

        // The control: with the filter naming another home, pi's own discovery finds that folder.
        try PiHome(directory: home.directory, engine: home.engine, userHome: scratch.appendingPathComponent("elsewhere").path).install()
        let unfiltered = try await skillNames(home: home, userHome: userHome, temporary: temporary, project: project)
        #expect(unfiltered.contains("skill:agents-only") && unfiltered.contains("skill:nested-agents"), "the fixture is found unfiltered: \(unfiltered)")
    }

    static func runYourExtensions(engine: BundledPiEngine) async throws {
        let scratch = try makeScratchDirectory("engine-ext")
        let files = FileManager.default
        let userHome = scratch.appendingPathComponent("home", isDirectory: true)
        let temporary = scratch.appendingPathComponent("tmp", isDirectory: true)
        let project = scratch.appendingPathComponent("project", isDirectory: true)
        let yourPi = userHome.appendingPathComponent(".pi/agent", isDirectory: true)
        for folder in [temporary, project, yourPi.appendingPathComponent("extensions/works")] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "throw new Error(\"fixture refuses to load\");\nexport default function () {}\n"
            .write(to: yourPi.appendingPathComponent("extensions/breaks.ts"), atomically: true, encoding: .utf8)
        try fixtureExtension.write(to: yourPi.appendingPathComponent("extensions/works/index.ts"), atomically: true, encoding: .utf8)
        let home = PiHome(directory: scratch.appendingPathComponent("support/pi", isDirectory: true), engine: .bundled(engine),
                          userHome: userHome.path)
        try home.install()
        try models.write(to: home.directory.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)
        let imports = YourPiImport(home: home, yourPi: YourPi(agentDirectory: yourPi), userHome: userHome.path, log: { _ in })
        let copies = imports.copyOnce().copied(.extensions)
        #expect(copies.map(\.name) == ["breaks", "works"])
        for copy in copies { try imports.setExtension(copy.destination, on: true) }
        let environment = ["HOME": userHome.path, "TMPDIR": temporary.path + "/", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

        let failing = try RPCProcess(executable: home.launcher.path, arguments: ["--mode", "rpc", "--no-session"], directory: project,
                                     environment: environment)
        defer { failing.stop() }
        try await eventually("pi to stop on the extension that throws") { !failing.isRunning }
        let lines = failing.errors.split(separator: "\n").map { PiStartRecord.plain(String($0)) }
        let failures = YourPiImport.extensionFailures(in: lines)
        #expect(failures.count == 1 && failures.first?.reason.contains("fixture refuses to load") == true, "\(failing.errors)")
        #expect(PiStartRecord.classify(lines: lines, exitCode: 1, resumedAsNew: false).kind == .extensionFailed)
        for failure in failures { #expect(try imports.extensionFailed(path: failure.path, reason: failure.reason) == "breaks") }

        let pi = try RPCProcess(executable: home.launcher.path, arguments: ["--mode", "rpc", "--no-session"], directory: project,
                                environment: environment)
        defer { pi.stop() }
        let listing = try await pi.request(["type": "get_commands"])
        let commands = ((listing["data"] as? [String: Any])?["commands"] as? [[String: Any]]) ?? []
        #expect(commands.contains { $0["name"] as? String == "engine-smoke" }, "the working one loads from its copy: \(pi.errors)")
        #expect(try await pi.finish() == 0, "pi starts without the one that threw: \(pi.errors)")
        #expect(imports.state()?.extensionFailures.values.first?.reason.contains("fixture refuses to load") == true)
    }

    /// The skills an agent's pi, started through the launcher in `project`, offers as commands.
    static func skillNames(home: PiHome, userHome: URL, temporary: URL, project: URL) async throws -> [String] {
        let pi = try RPCProcess(executable: home.launcher.path, arguments: ["--mode", "rpc", "--no-session"], directory: project, environment: [
            "HOME": userHome.path,
            "TMPDIR": temporary.path + "/",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ])
        defer { pi.stop() }
        let listing = try await pi.request(["type": "get_commands"])
        #expect(listing["success"] as? Bool == true, "get_commands: \(listing) \(pi.errors)")
        let commands = ((listing["data"] as? [String: Any])?["commands"] as? [[String: Any]]) ?? []
        #expect(try await pi.finish() == 0, "pi exits cleanly when its input ends: \(pi.errors)")
        return commands.compactMap { $0["name"] as? String }.filter { $0.hasPrefix("skill:") }.sorted()
    }

    /// Every path under `root`, with its bytes (a folder as empty).
    static func tree(_ root: URL) throws -> [String: Data] {
        var tree: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            tree[path] = FileManager.default.contents(atPath: root.appendingPathComponent(path).path) ?? Data()
        }
        return tree
    }

    struct ToolResult { let status: Int32; let output: String }

    static func runTool(_ path: String, _ arguments: [String], environment: [String: String]) throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if !environment.isEmpty { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ToolResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

/// pi over RPC: one JSON object per line each way.
final class RPCProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let lines = Locked<(buffer: Data, records: [[String: Any]])>((Data(), []))
    private let stderr = Locked(Data())
    private var nextID = 0

    init(executable: String, arguments: [String], directory: URL, environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = input
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [lines] handle in
            let chunk = handle.availableData
            lines.withValue { state in
                state.buffer.append(chunk)
                while let newline = state.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = state.buffer[state.buffer.startIndex..<newline]
                    state.buffer = Data(state.buffer[state.buffer.index(after: newline)...])
                    if let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                        state.records.append(record)
                    }
                }
            }
            if chunk.isEmpty { handle.readabilityHandler = nil }
        }
        errors.fileHandleForReading.readabilityHandler = { [stderr] handle in
            let chunk = handle.availableData
            stderr.withValue { $0.append(chunk) }
            if chunk.isEmpty { handle.readabilityHandler = nil }
        }
        try process.run()
    }

    var errors: String { String(decoding: stderr.current, as: UTF8.self) }
    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }

    func request(_ command: [String: Any]) async throws -> [String: Any] {
        nextID += 1
        let id = "smoke-\(nextID)"
        var command = command
        command["id"] = id
        var line = try JSONSerialization.data(withJSONObject: command)
        line.append(UInt8(ascii: "\n"))
        try input.fileHandleForWriting.write(contentsOf: line)
        var response: [String: Any]?
        try await eventually("pi's response to \(command["type"] ?? "?")") {
            response = lines.current.records.first { $0["type"] as? String == "response" && $0["id"] as? String == id }
            return response != nil || !process.isRunning
        }
        guard let response else { throw CommandFailure("pi \(command["type"] ?? "?")", "exited before answering: \(errors)") }
        return response
    }

    /// Ends pi's input and waits for it to exit.
    func finish() async throws -> Int32 {
        try input.fileHandleForWriting.close()
        try await eventually("pi exits") { !process.isRunning }
        return process.terminationStatus
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }
}


/// A Unix socket that takes one connection and reports which process made it.
final class PeerListener: @unchecked Sendable {
    private let fd: Int32

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CommandFailure("socket", String(cString: strerror(errno))) }
        var address = try SessionServer.socketAddress(for: path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            throw CommandFailure("bind \(path)", reason)
        }
    }

    /// The pid of the next connection's process, or nil after `timeout` seconds.
    func peerProcess(timeout: Int32 = 60) async -> pid_t? {
        await Task.detached { [fd] in
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, timeout * 1000) > 0 else { return nil }
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { return nil }
            defer { Darwin.close(connection) }
            return SessionServer.peerProcessID(of: connection)
        }.value
    }

    func close() { Darwin.close(fd) }
}
