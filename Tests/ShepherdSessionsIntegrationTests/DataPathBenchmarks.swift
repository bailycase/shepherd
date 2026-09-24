import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// What the server's data path costs: decoding pi's records, projecting and snapshotting a
/// thread, status reports, and how long the server queue stalls meanwhile. Opt-in, and prints
/// `BENCH` lines rather than asserting (timings depend on the machine):
///
///     swift build -c release -Xswiftc -enable-testing --build-tests
///     SHEPHERD_BENCHMARK=1 swift test -c release --skip-build --filter DataPathBenchmarks
@Suite("Data path benchmarks", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_BENCHMARK"] != nil))
struct DataPathBenchmarks {
    // MARK: Decoding a history

    /// get_messages as the session reads it: the record's decode, then the projection.
    @Test(arguments: [1, 4, 12])
    func historyDecodeAndProjection(megabytes: Int) throws {
        let line = try Bench.responseLine(Bench.history(targetBytes: megabytes << 20))
        var decode: [Double] = [], project: [Double] = [], release: [Double] = []
        var count = 0
        for _ in 0..<5 {
            var messages: [RPCMessage] = []
            decode.append(try Bench.time {
                guard case .response(let response) = try NDJSON.decode(RPCIncoming.self, from: line) else { return }
                messages = response.messages ?? []
            })
            count = messages.count
            project.append(Bench.time {
                _ = messages.enumerated().map { RPCThreadState.project(entryID: "m:\($0.offset)", message: $0.element) }
            })
            release.append(Bench.time { messages = [] })
        }
        let mib = String(format: "%.1fMiB", Double(line.count) / 1_048_576)
        Bench.report("history.\(mib).decode", Bench.median(decode), "ms", "messages=\(count)")
        Bench.report("history.\(mib).project", Bench.median(project), "ms")
        Bench.report("history.\(mib).release", Bench.median(release), "ms")
        Bench.report("history.\(mib).total", Bench.median(decode) + Bench.median(project), "ms")
    }

    // MARK: Streaming

    @Test func streamingDeltaCost() throws {
        let delta = Data(#"{"type":"message_update",\#(Bench.usageJSON),"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"token streaming text, "}}"#.utf8)
        var decode: [Double] = []
        for _ in 0..<3 {
            decode.append(try Bench.time { for _ in 0..<5_000 { _ = try NDJSON.decode(RPCIncoming.self, from: delta) } } * 1000 / 5_000)
        }
        Bench.report("stream.decodeDelta", Bench.median(decode), "us/event")

        let queue = DispatchQueue(label: "bench.rpc")
        let session = try RPCSession(params: CreateSessionParams(cwd: "/tmp", command: ["/bin/sleep", "600"], runtime: .rpc), queue: queue)
        defer { queue.sync { session.shutdown() } }
        let body = String(repeating: "line of build output 00\n", count: 16_384 / 24)
        let bodyJSON = try String(decoding: JSONEncoder().encode(body), as: UTF8.self)
        func event(_ json: String) throws -> RPCEvent {
            guard case .event(let event) = try NDJSON.decode(RPCIncoming.self, from: Data(json.utf8)) else { throw BenchError("not an event") }
            return event
        }
        let deltaEvent = try event(String(decoding: delta, as: UTF8.self))
        for tools in [0, 10, 50] {
            var perEvent: [Double] = []
            for _ in 0..<3 {
                let thread = RPCThreadState(session: session, queue: queue)
                var events = [try event(#"{"type":"agent_start"}"#)]
                for i in 0..<tools {
                    events.append(try event(#"{"type":"tool_execution_start","toolCallId":"c\#(i)","toolName":"bash","args":{"command":"make"}}"#))
                    events.append(try event(#"{"type":"tool_execution_end","toolCallId":"c\#(i)","toolName":"bash","result":{"content":[{"type":"text","text":\#(bodyJSON)}]},"isError":false}"#))
                }
                events.append(try event(#"{"type":"message_start","message":{"role":"assistant","content":[]}}"#))
                events.append(try event(#"{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":0}}"#))
                perEvent.append(queue.sync {
                    events.forEach(thread.handle)
                    return Bench.time { for _ in 0..<2_000 { thread.handle(deltaEvent) } } * 1000 / 2_000
                })
            }
            Bench.report("stream.handleDelta.tools\(tools)", Bench.median(perEvent), "us/event")
        }
    }

    // MARK: Snapshots

    /// A snapshot of a changed revision near the budget: 50 history rows and a streaming reply.
    @Test func snapshotBuildCost() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let file = h.dir.appendingPathComponent("history.json")
        try JSONSerialization.data(withJSONObject: Bench.history(targetBytes: 4 << 20)).write(to: file)
        let agent = try await h.benchAgents(1, history: file)[0]
        let ready = try await h.readySnapshot(agent)
        var fresh: [Double] = [], unchanged: [Double] = []
        var bytes = 0
        for _ in 0..<15 {
            let start = ContinuousClock.now
            let result = try await h.server.nativeThread(agentID: agent.agentID, request: .snapshot())
            fresh.append(Bench.ms(ContinuousClock.now - start))
            if case .snapshot(let value) = result { bytes = try JSONEncoder().encode(value).count }
            let again = ContinuousClock.now
            _ = try await h.server.nativeThread(agentID: agent.agentID, request: .snapshot(expectedSessionID: ready.piSessionID, afterRevision: ready.revision))
            unchanged.append(Bench.ms(ContinuousClock.now - again))
        }
        Bench.report("snapshot.fresh.roundTrip", Bench.median(fresh), "ms", "bytes=\(bytes) messages=\(ready.messages.count)")
        Bench.report("snapshot.unchanged.roundTrip", Bench.median(unchanged), "ms")
    }

    // MARK: Status reports

    @Test(arguments: [30, 100, 300])
    func statusReportCost(agents count: Int) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let agents = (0..<count).map { _ in Fixture.agent(in: space) }
        try await h.seed(Fixture.workspace(agents, space: space))
        let client = try ExtensionClient(path: h.socketPath)
        defer { client.closeConnection() }
        let reports = 60
        let statuses = Callbacks(h.server)
        let written = Bench.modified(h.stateURL)
        let before = Bench.cpu()
        for i in 0..<reports {
            try client.send(.setAgentStatus(agentID: agents[i % 10].agent.id, status: (i / 10) % 2 == 0 ? .working : .done))
        }
        try await eventually("\(reports) status reports", timeout: .seconds(60)) { statuses.statuses.current.count >= reports }
        let cpu = (Bench.cpu() - before) * 1000 / Double(reports)
        Bench.report("status.\(count)agents.cpu", cpu, "ms/report", "state.json rewritten: \(Bench.modified(h.stateURL) != written)")
    }

    // MARK: The server queue while histories decode

    /// How long other work waits for the queue while one agent's long history reloads at the
    /// end of each turn: a probe asks the queue for something trivial every millisecond.
    @Test(arguments: [4, 12])
    func queueLatencyDuringHistoryReload(megabytes: Int) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let file = h.dir.appendingPathComponent("history.json")
        try JSONSerialization.data(withJSONObject: Bench.history(targetBytes: megabytes << 20)).write(to: file)
        let agent = try await h.benchAgents(1, history: file)[0]
        let ready = try await h.readySnapshot(agent)
        let probe = QueueProbe(h.server)
        for turn in 0..<3 {
            let previous = try await h.readySnapshot(agent).revision
            _ = try await h.server.nativeThread(agentID: agent.agentID, request: .send(
                expectedSessionID: ready.piSessionID, generation: ready.generation, operationID: UUID(),
                text: "stream 10 0", delivery: .followUp))
            try await eventually("turn \(turn) to settle and reload", timeout: .seconds(120)) {
                guard case .snapshot(let s) = try await h.server.nativeThread(agentID: agent.agentID, request: .snapshot()) else { return false }
                return !s.running && s.revision > previous + 2 && s.provisional.isEmpty
            }
        }
        let latency = probe.stop()
        Bench.report("queue.reload\(megabytes)MiB.worst", latency.worst, "ms",
                     String(format: "over16ms=%d of %d probes, p99=%.1fms", latency.over16, latency.count, latency.p99))
    }

    /// A relaunch of `agents` agents each resuming a 4 MiB history, with their extensions
    /// dialling the socket meanwhile (5 connects per agent over the first 2 s).
    @Test(arguments: [8, 30])
    func relaunchWithLongHistories(agents count: Int) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let file = h.dir.appendingPathComponent("history.json")
        try JSONSerialization.data(withJSONObject: Bench.history(targetBytes: 4 << 20)).write(to: file)
        let stalls = StateReadSampler(h.server)
        let probe = QueueProbe(h.server)
        let refused = Locked(0)
        let socketPath = h.socketPath
        let connects = count * 5
        Thread.detachNewThread {
            var held: [ExtensionClient] = []
            for _ in 0..<connects {
                if let client = try? ExtensionClient(path: socketPath) { held.append(client) } else { refused.withValue { $0 += 1 } }
                usleep(useconds_t(2_000_000 / connects))
            }
            Thread.sleep(forTimeInterval: 5)
            held.forEach { $0.closeConnection() }
        }
        let start = ContinuousClock.now
        let agents = try await h.benchAgents(count, history: file)
        var firstReady: Double?
        for agent in agents {
            _ = try await h.readySnapshot(agent, minMessages: 10, timeout: .seconds(600))
            if firstReady == nil { firstReady = Bench.ms(ContinuousClock.now - start) }
        }
        let loaded = Bench.ms(ContinuousClock.now - start)
        let reads = stalls.stop()
        let queue = probe.stop()
        Bench.report("relaunch.\(count)x4MiB.firstReady", firstReady ?? .nan, "ms")
        Bench.report("relaunch.\(count)x4MiB.allReady", loaded, "ms")
        Bench.report("relaunch.\(count)x4MiB.queueWorst", queue.worst, "ms", String(format: "over16ms=%d of %d", queue.over16, queue.count))
        Bench.report("relaunch.\(count)x4MiB.stateReadWorst", reads.worst, "ms", String(format: "total blocked %.0fms over %d reads", reads.total, reads.count))
        Bench.report("relaunch.\(count)x4MiB.connectsRefused", Double(refused.current), "connects", "of \(connects)")
    }
}

// MARK: - Support

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum Bench {
    static let usageJSON = #""usage":{"input":100,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":101,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}"#

    static func report(_ name: String, _ value: Double, _ unit: String, _ note: String = "") {
        print(String(format: "BENCH name=%@ value=%.3f unit=%@ %@", name, value, unit, note))
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    static func time(_ body: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try body()
        return ms(ContinuousClock.now - start)
    }

    static func median(_ xs: [Double]) -> Double {
        let sorted = xs.sorted()
        return sorted.isEmpty ? .nan : sorted[sorted.count / 2]
    }

    /// Process CPU seconds, user and system.
    static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Deterministic text of about `bytes`: words, newlines, quotes and paths, so escaping and
    /// decoding see what real tool output looks like.
    static func text(_ bytes: Int, seed: inout UInt64) -> String {
        let words = ["let", "value", "func", "return", "\"quoted\"", "src/app/main.swift:42:", "error:", "the", "{", "}",
                     "if", "self.state", "0x7ff3", "->", "import", "Foundation", "// comment", "\\n", "path/to/file.ts", "=="]
        var out = ""
        out.reserveCapacity(bytes + 32)
        while out.utf8.count < bytes {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            out += words[Int((seed >> 33) % UInt64(words.count))]
            out += (seed >> 20) % 11 == 0 ? "\n" : " "
        }
        return out
    }

    /// pi-shaped messages (a user turn, assistant steps with thinking, text, a tool call and
    /// usage, tool results) of about `targetBytes` of JSON.
    static func history(targetBytes: Int) -> [[String: Any]] {
        var seed: UInt64 = 42
        var messages: [[String: Any]] = []
        var size = 0
        var time: Double = 1_760_000_000_000
        let outputs = [300, 2_500, 9_000, 24_000]
        let usage: [String: Any] = ["input": 18234, "output": 812, "cacheRead": 120_332, "cacheWrite": 2211, "totalTokens": 141_589,
                                    "cost": ["input": 0.054, "output": 0.012, "cacheRead": 0.036, "cacheWrite": 0.008, "total": 0.11]]
        var turn = 0
        while size < targetBytes {
            messages.append(["role": "user", "content": [["type": "text", "text": text(300, seed: &seed)]], "timestamp": time])
            size += 400
            for step in 0..<3 {
                time += 1000
                let id = "toolu_\(turn)_\(step)"
                messages.append(["role": "assistant", "content": [
                    ["type": "thinking", "thinking": text(800, seed: &seed), "thinkingSignature": String(repeating: "Eq", count: 150)],
                    ["type": "text", "text": text(400, seed: &seed)],
                    ["type": "toolCall", "id": id, "name": "bash", "arguments": ["command": "rg -n \"state\" Sources/ | head -80", "timeout": 120]],
                ], "api": "anthropic-messages", "provider": "anthropic", "model": "claude-opus-4-5", "usage": usage,
                   "stopReason": "toolUse", "timestamp": time])
                let output = text(outputs[(turn + step) % outputs.count], seed: &seed)
                messages.append(["role": "toolResult", "toolCallId": id, "toolName": "bash",
                                 "content": [["type": "text", "text": output]], "details": ["exitCode": 0, "truncated": false],
                                 "isError": false, "timestamp": time + 500])
                size += 2_300 + output.utf8.count
            }
            messages.append(["role": "assistant", "content": [["type": "text", "text": text(1_200, seed: &seed)]],
                             "api": "anthropic-messages", "provider": "anthropic", "model": "claude-opus-4-5", "usage": usage,
                             "stopReason": "stop", "timestamp": time + 900])
            size += 1_600
            turn += 1
        }
        return messages
    }

    static func responseLine(_ messages: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "response", "id": "req-1", "command": "get_messages", "success": true, "data": ["messages": messages],
        ] as [String: Any])
    }

    /// A pi stand-in that serves a history from `BENCH_PI_HISTORY` and streams a turn on
    /// `stream <deltas> <tools> [tool bytes]`.
    static let benchPi = #"""
import json, os, sys, threading
out = sys.stdout.buffer
lock = threading.Lock()
def emit(o):
    with lock:
        out.write(json.dumps(o, separators=(",", ":")).encode() + b"\n"); out.flush()
MESSAGES = []
path = os.environ.get("BENCH_PI_HISTORY")
if path:
    with open(path) as f: MESSAGES = json.load(f)
SID = "bench-%d" % os.getpid()
USAGE = {"input": 100, "output": 1, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 101,
         "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0}}
def respond(cmd, data=None):
    r = {"type": "response", "command": cmd.get("type"), "success": True}
    if "id" in cmd: r["id"] = cmd["id"]
    if data is not None: r["data"] = data
    emit(r)
def turn(deltas, tools, tool_bytes):
    emit({"type": "agent_start"}); emit({"type": "turn_start"})
    for i in range(tools):
        tid = "call_%d" % i
        emit({"type": "tool_execution_start", "toolCallId": tid, "toolName": "bash", "args": {"command": "make test"}})
        body = ("line of build output %d\n" % i) * (tool_bytes // 24)
        emit({"type": "tool_execution_end", "toolCallId": tid, "toolName": "bash",
              "result": {"content": [{"type": "text", "text": body}]}, "isError": False})
    emit({"type": "message_start", "message": {"role": "assistant", "content": []}})
    emit({"type": "message_update", "usage": USAGE, "assistantMessageEvent": {"type": "text_start", "contentIndex": 0}})
    text = ""
    for i in range(deltas):
        d = "token%05d streaming, " % i
        text += d
        emit({"type": "message_update", "usage": USAGE, "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": d}})
    emit({"type": "message_update", "usage": USAGE, "assistantMessageEvent": {"type": "text_end", "contentIndex": 0, "content": text}})
    final = {"role": "assistant", "content": [{"type": "text", "text": text}], "stopReason": "stop", "usage": USAGE}
    emit({"type": "message_end", "message": final})
    MESSAGES.append(final)
    emit({"type": "turn_end", "message": final, "toolResults": []})
    emit({"type": "agent_end", "messages": [final], "willRetry": False})
    emit({"type": "agent_settled"})
for raw in sys.stdin.buffer:
    line = raw.strip()
    if not line: continue
    cmd = json.loads(line); t = cmd.get("type")
    if t == "get_state":
        respond(cmd, {"sessionId": SID, "model": {"provider": "anthropic", "id": "claude"}, "thinkingLevel": "medium", "isStreaming": False})
    elif t == "get_messages": respond(cmd, {"messages": MESSAGES})
    elif t == "get_commands": respond(cmd, {"commands": []})
    elif t == "get_session_stats": respond(cmd, {"contextUsage": {"tokens": 1, "contextWindow": 200000, "percent": 1}, "tokens": {"total": 1}, "cost": 0})
    elif t == "prompt":
        respond(cmd)
        parts = cmd.get("message", "").split()
        if parts and parts[0] == "stream":
            threading.Thread(target=turn, args=(int(parts[1]), int(parts[2]), int(parts[3]) if len(parts) > 3 else 16384), daemon=True).start()
    else:
        respond(cmd)
"""#
}

struct BenchAgent {
    let agentID: AgentID
    let sessionID: SessionID
}

extension ScratchServer {
    /// `count` bench pis, each bound to its own agent the way the app binds a thread pane.
    func benchAgents(_ count: Int, history: URL?) async throws -> [BenchAgent] {
        let script = dir.appendingPathComponent("bench-pi.py")
        if !FileManager.default.fileExists(atPath: script.path) { try Data(Bench.benchPi.utf8).write(to: script) }
        let env = history.map { ["BENCH_PI_HISTORY": $0.path] } ?? [:]
        let space = Fixture.space("bench", path: dir.path)
        var tabs: [ShepherdCore.Tab] = [], agents: [Agent] = [], result: [BenchAgent] = []
        for index in 0..<count {
            let info = try await server.createSession(params: CreateSessionParams(cwd: dir.path, command: ["python3", script.path], env: env, runtime: .rpc))
            let agentID = AgentID()
            let pane = LeafPane(sessionID: info.id, cwd: dir.path, agentID: agentID)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: index, layout: .leaf(pane))
            tabs.append(tab)
            agents.append(Agent(id: agentID, name: "a\(index)", spaceID: space.id, tabID: tab.id, paneID: pane.id))
            result.append(BenchAgent(agentID: agentID, sessionID: info.id))
        }
        try await server.putState(ShepherdState(spaces: [space], tabs: tabs, agents: agents))
        return result
    }

    func readySnapshot(_ agent: BenchAgent, minMessages: Int = 1, timeout: Duration = .seconds(120)) async throws -> NativeThreadSnapshot {
        var latest: NativeThreadSnapshot?
        try await eventually("bench agent ready", timeout: timeout) {
            guard case .snapshot(let s) = try await server.nativeThread(agentID: agent.agentID, request: .snapshot()) else { return false }
            latest = s
            return !s.piSessionID.isEmpty && s.messages.count >= minMessages
        }
        return try #require(latest)
    }
}

/// Asks the server queue for something trivial every millisecond and records how long each
/// answer took: what a keystroke echo or an extension report waits behind.
final class QueueProbe: @unchecked Sendable {
    private let samples = Locked<[Double]>([])
    private let running = Locked(true)
    private let done = DispatchSemaphore(value: 0)

    init(_ server: SessionServer) {
        let samples = samples, running = running, done = done
        Task.detached {
            while running.current {
                let start = ContinuousClock.now
                _ = await server.sessionInfo(sessionID: SessionID())
                let elapsed = Bench.ms(ContinuousClock.now - start)
                samples.withValue { $0.append(elapsed) }
                try? await Task.sleep(for: .milliseconds(1))
            }
            done.signal()
        }
    }

    func stop() -> (worst: Double, p99: Double, over16: Int, count: Int) {
        running.withValue { $0 = false }
        done.wait()
        let sorted = samples.current.sorted()
        guard let worst = sorted.last else { return (0, 0, 0, 0) }
        return (worst, sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))], sorted.filter { $0 > 16 }.count, sorted.count)
    }
}

/// How long a synchronous `server.state` read takes (what the main thread pays in `ownsPane`,
/// `persistBinding`, and reconciling), sampled every 2 ms on a thread of its own.
final class StateReadSampler: @unchecked Sendable {
    private let samples = Locked<[Double]>([])
    private let running = Locked(true)
    private let done = DispatchSemaphore(value: 0)

    init(_ server: SessionServer) {
        let samples = samples, running = running, done = done
        Thread.detachNewThread {
            while running.current {
                let start = ContinuousClock.now
                _ = server.state
                samples.withValue { $0.append(Bench.ms(ContinuousClock.now - start)) }
                usleep(2_000)
            }
            done.signal()
        }
    }

    func stop() -> (worst: Double, total: Double, count: Int) {
        running.withValue { $0 = false }
        done.wait()
        let values = samples.current
        return (values.max() ?? 0, values.reduce(0, +), values.count)
    }
}
