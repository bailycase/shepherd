import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
@testable import ShepherdApp

/// An agent's thread as the app has it, fed by a real server and a stub pi: the host's own
/// snapshots (its pending row for a send, the queue, pushed revisions) arriving in the host's time,
/// in the workspace view, over a long history of rows that differ in height. What `FlowHost` plays
/// back by hand, a real host does in its own order and its own timing, which is where a thread's
/// layout has to hold.
///
/// pi's history comes from `STUB_PI_MESSAGES_FILE`. A turn the stub runs for a prompt that starts
/// with `tools:N` makes N calls that each wait for the file `tool-<k>` (`release(_:)`), then replies.
@MainActor
final class RealThreadRig {
    typealias Fx = ThreadBlankScreenTests

    let app: AppHarness
    let vm: ShepherdViewModel
    let window: OffscreenWindow
    let store: NativeThreadStore
    let trace: ScrollTrace

    /// Opens the workspace on one agent whose history holds `turns` turns, with the thread loaded and
    /// laid out. `mix` says how tall the long answers run.
    init(size: CGSize, turns: Int = 40, mix: ThreadTailFlowTests.Mix) async throws {
        let app = try AppHarness()
        let file = app.dir.appendingPathComponent("history.json")
        try JSONSerialization.data(withJSONObject: Self.history(turns: turns, mix: mix)).write(to: file)
        let space = Fixture.space(path: app.dir.path)
        let info = try await app.server.createSession(params: CreateSessionParams(
            cwd: space.path, command: StubPi.command, env: ["STUB_PI_MESSAGES_FILE": file.path], runtime: .rpc))
        let agent = Fixture.agent("agent", in: space, piSession: info.id)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.changesEngineOverride = { _, _ in .fixed([ListFixtures.diffFile("Sources/A.swift", lines: 12)]) }
        vm.selectAgent(agent.agent.id)
        let window = OffscreenWindow(size: size, dark: true, WorkspaceView(vm: vm))
        let store = vm.threadStores.store(for: agent.agent.id)
        try await eventuallyOnMain("the thread to load", timeout: .seconds(60)) { store.ready && !store.messages.isEmpty }
        try await Task.sleep(for: .milliseconds(500))
        window.layout()
        guard let scroll = ListPerf.scrollView(in: window) else { throw TimedOut(what: "the thread's scroll view") }
        self.app = app
        self.vm = vm
        self.window = window
        self.store = store
        trace = ScrollTrace(scroll)
    }

    func close() {
        trace.stop()
        store.stop()
        window.close()
        app.stop()
    }

    /// Lets the pi's tool call number `k` finish.
    func release(_ k: Int) {
        FileManager.default.createFile(atPath: app.dir.appendingPathComponent("tool-\(k)").path, contents: nil)
    }

    func wait(_ duration: Duration) async throws { try await Task.sleep(for: duration) }

    /// pi's own message format: user turns, tool calls and their results, and an answer with prose and
    /// a code block, every `mix.every`th turn a long one.
    static func history(turns: Int, mix: ThreadTailFlowTests.Mix) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for n in 0..<turns {
            let at = Int(Fx.base) + n * 60_000
            out.append(["role": "user", "content": [["type": "text", "text": "Question \(n): please do the thing and explain it."]], "timestamp": at])
            for k in 0..<(1 + n % 4) {
                let id = "c\(n)-\(k)"
                let read = k.isMultiple(of: 2)
                let arguments: [String: Any] = read ? ["path": "Sources/File\(n)\(k).swift"] : ["command": "swift test --filter T\(k)"]
                out.append(["role": "assistant", "content": [["type": "toolCall", "id": id, "name": read ? "read" : "bash", "arguments": arguments]],
                            "stopReason": "toolUse", "timestamp": at + 1000])
                out.append(["role": "toolResult", "toolCallId": id, "toolName": read ? "read" : "bash",
                            "content": [["type": "text", "text": (0..<(3 + (n + k) % 12)).map { "output line \($0)" }.joined(separator: "\n")]],
                            "isError": false, "timestamp": at + 1500])
            }
            let long = n % mix.every == 3
            let text = long ? Fx.prose(mix.paragraphs, n) + "\n\n" + Fx.code(n) + "\n\n" + Fx.prose(12, n) + "\n\n" + Fx.code(n + 5)
                : Fx.prose(1 + n % 5, n) + "\n\n" + Fx.code(n)
            out.append(["role": "assistant", "content": [["type": "text", "text": text]], "stopReason": "stop", "timestamp": at + 5000])
        }
        return out
    }
}
