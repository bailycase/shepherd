import Darwin
import Foundation
import Testing
import ShepherdCore
@testable import ShepherdSessions

/// Host-side terminal cost baselines. Not pass/fail: each test prints one
/// `BENCH name=… value=… unit=…` line and only asserts the work completed.
/// Runs only with `SHEPHERD_BENCH=1` so the ordinary suite stays fast:
///
///     SHEPHERD_BENCH=1 swift test -c release -Xswiftc -enable-testing \
///         --filter TerminalBenchmarkTests 2>&1 | grep BENCH
///
/// Results are recorded in docs/benchmarks/. Ghostty surface cost cannot be
/// measured here (no AppKit in `swift test`); see that document for the
/// in-app procedure.
@Suite("Terminal benchmarks", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_BENCH"] == "1"))
struct TerminalBenchmarkTests {
    private func report(_ name: String, _ value: Double, _ unit: String) {
        print(String(format: "BENCH name=%@ value=%.3f unit=%@", name, value, unit))
    }

    private func timed(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private func residentBytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) : .nan
    }

    /// Output shaped like a TUI repaint: cursor moves, SGR runs, line clears.
    private func tuiBurst(cols: Int, rows: Int, frames: Int) -> Data {
        var out = ""
        for frame in 0..<frames {
            for row in 1...rows {
                out += "\u{1b}[\(row);1H\u{1b}[2K\u{1b}[3\(row % 7 + 1)m"
                out += String(repeating: "x", count: min(cols - 12, 60))
                out += " \u{1b}[0m\u{1b}[1m\(frame):\(row)\u{1b}[0m"
            }
        }
        return Data(out.utf8)
    }

    @Test func screenFeedThroughput() {
        for (cols, rows) in [(80, 24), (200, 60)] {
            let screen = SessionScreen(cols: cols, rows: rows)
            let burst = tuiBurst(cols: cols, rows: rows, frames: 400)
            let ms = timed {
                for _ in 0..<5 { screen.feed(burst) }
            }
            let bytes = Double(burst.count * 5)
            report("screen.feed.\(cols)x\(rows)", bytes / 1_048_576 / (ms / 1000), "MiB/s")
            #expect(screen.rows == rows)
        }
    }

    @Test func snapshotCostWithFullScrollback() {
        for (cols, rows) in [(80, 24), (200, 60)] {
            let screen = SessionScreen(cols: cols, rows: rows)
            for i in 0..<(SessionScreen.defaultScrollbackLines + rows) {
                screen.feed(Data("\u{1b}[3\(i % 7 + 1)mline \(i) \u{1b}[0m\(String(repeating: "-", count: cols / 2))\r\n".utf8))
            }
            var size = 0
            let ms = timed {
                for _ in 0..<10 { size = screen.snapshot().count }
            }
            report("screen.snapshot.\(cols)x\(rows)", ms / 10, "ms")
            report("screen.snapshot.\(cols)x\(rows).bytes", Double(size), "bytes")
            #expect(size > 0)
        }
    }

    /// Every agent status report goes through this path today (A2 removes it
    /// for unchanged statuses).
    @Test func stateUpdateCostByFleetSize() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for agentCount in [10, 50, 200] {
            let store = StateStore(url: dir.appendingPathComponent("state-\(agentCount).json"))
            let space = Space(name: "s", path: "/tmp/s")
            var tabs: [ShepherdCore.Tab] = []
            var agents: [Agent] = []
            for i in 0..<agentCount {
                let agentID = AgentID()
                let pane = LeafPane(cwd: "/tmp/s", agentID: agentID)
                let tab = ShepherdCore.Tab(spaceID: space.id, order: i, layout: .leaf(pane))
                tabs.append(tab)
                agents.append(Agent(id: agentID, name: "agent \(i)", spaceID: space.id, tabID: tab.id, paneID: pane.id))
            }
            try store.update { $0 = ShepherdState(spaces: [space], tabs: tabs, agents: agents) }
            let iterations = 50
            let ms = timed {
                for i in 0..<iterations {
                    try? store.update { $0.agents[i % agentCount].status = i % 2 == 0 ? .working : .idle }
                }
            }
            report("state.update.\(agentCount)agents", ms / Double(iterations), "ms")
            #expect(store.state.agents.count == agentCount)
        }
    }

    /// Host-side memory retained per live session: PTY + SessionScreen with
    /// full scrollback. The Ghostty surface per pane is measured in-app.
    @Test func hostMemoryPerSession() async throws {
        let dir = try makeScratchDirectory()
        let server = SessionServer(
            socketPath: dir.appendingPathComponent("d.sock").path,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        let count = 20
        let lines = SessionScreen.defaultScrollbackLines + 24
        let before = residentBytes()
        var ids: [SessionID] = []
        for _ in 0..<count {
            let info = try await server.createSession(params: CreateSessionParams(
                cwd: "/tmp",
                command: ["/bin/sh", "-c", "awk 'BEGIN{for(i=1;i<=\(lines);i++)print \"\\033[32mline \" i \"\\033[0m ------------------------------\"}'; sleep 60"],
                cols: 120, rows: 40, env: nil
            ))
            ids.append(info.id)
        }
        // Wait until every screen holds full scrollback.
        for id in ids {
            let deadline = ContinuousClock.now + .seconds(20)
            while ContinuousClock.now < deadline {
                let rows = await server.screenText(sessionID: id) ?? []
                if rows.contains(where: { $0.contains("line \(lines) ") }) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await Task.sleep(for: .seconds(1))
        let after = residentBytes()
        report("host.memory.perSession", (after - before) / Double(count) / 1_048_576, "MiB")
        for id in ids { server.killSession(id) }
        #expect(ids.count == count)
    }
}
