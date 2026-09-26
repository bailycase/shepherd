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

    @Test(.enabled(if: EngineSmoke.rosettaRunsX86, "needs an arm64 Mac with Rosetta and an x86_64 slice"))
    func itsX86SliceRunsUnderRosetta() async throws {
        let engine = try #require(EngineSmoke.engine)
        try await EngineSmoke.run(node: engine.node, engine: engine, arch: "x86_64")
    }

    /// Ad-hoc builds (the Dev scheme, CI's unsigned releases) run node without the hardened
    /// runtime. A Developer ID build turns it on, and V8 then needs the engine's entitlements:
    /// this signs a scratch copy the way `scripts/sign-app.sh` does, with the runtime, and runs
    /// every slice this Mac can.
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
            app.appendingPathComponent("Engine-x86_64.entitlements").path,
        ], environment: ["TMPDIR": scratch.path, "PATH": "/usr/bin:/bin"])
        #expect(signing.status == 0, "sign-engine.sh: \(signing.output)")
        let display = try EngineSmoke.runTool("/usr/bin/codesign", ["-dv", node.path], environment: [:])
        #expect(display.output.contains("runtime"), "the copy is signed with the hardened runtime: \(display.output)")

        try await EngineSmoke.run(node: node, engine: engine)
        if EngineSmoke.rosettaRunsX86 {
            try await EngineSmoke.run(node: node, engine: engine, arch: "x86_64")
        }
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

    /// An arm64 Mac that can run x86_64 code, and a node with an x86_64 slice.
    static let rosettaRunsX86: Bool = {
        guard let engine else { return false }
        #if arch(arm64)
        guard let archs = try? runTool("/usr/bin/lipo", ["-archs", engine.node.path], environment: [:]),
              archs.output.split(separator: " ").contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "x86_64" }),
              let rosetta = try? runTool("/usr/bin/arch", ["-x86_64", "/usr/bin/true"], environment: [:])
        else { return false }
        return rosetta.status == 0
        #else
        return false
        #endif
    }()

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

    static func run(node: URL, engine: BundledPiEngine, arch: String? = nil) async throws {
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

        var arguments = [engine.entry.path, "--mode", "rpc", "--no-session", "-e", fixture.path]
        let executable: String
        if let arch {
            executable = "/usr/bin/arch"
            arguments = ["-\(arch)", node.path] + arguments
        } else {
            executable = node.path
        }
        let pi = try RPCProcess(executable: executable, arguments: arguments, directory: project, environment: [
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
