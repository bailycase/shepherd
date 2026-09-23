import Darwin
import Foundation
import Testing
import ShepherdCore
@testable import ShepherdSessions
import ShepherdTestSupport

/// Host-side terminal cost baselines — opt-in, never part of the normal run. Each test prints
/// one `BENCH name=… value=… unit=…` line and only asserts the work completed:
///
///     SHEPHERD_BENCHMARK=1 swift test -c release -Xswiftc -enable-testing \
///         --filter TerminalBenchmarks 2>&1 | grep BENCH
///
/// Results are recorded in docs/benchmarks/. Ghostty surface cost is measured in-app.
@Suite("Terminal benchmarks", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_BENCHMARK"] != nil))
struct TerminalBenchmarks {
    private func report(_ name: String, _ value: Double, _ unit: String) {
        print(String(format: "BENCH name=%@ value=%.3f unit=%@", name, value, unit))
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let elapsed = ContinuousClock().measure(body)
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
    private func repaint(cols: Int, rows: Int, frames: Int) -> Data {
        var out = ""
        for frame in 0..<frames {
            for row in 1...rows {
                out += "\u{1b}[\(row);1H\u{1b}[2K\u{1b}[3\(row % 7 + 1)m" + String(repeating: "x", count: min(cols - 12, 60))
                out += " \u{1b}[0m\u{1b}[1m\(frame):\(row)\u{1b}[0m"
            }
        }
        return Data(out.utf8)
    }

    @Test func screenFeedThroughput() {
        for (cols, rows) in [(80, 24), (200, 60)] {
            let screen = SessionScreen(cols: cols, rows: rows)
            let burst = repaint(cols: cols, rows: rows, frames: 400)
            let ms = milliseconds { for _ in 0..<5 { screen.feed(burst) } }
            report("screen.feed.\(cols)x\(rows)", Double(burst.count * 5) / 1_048_576 / (ms / 1000), "MiB/s")
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
            let ms = milliseconds { for _ in 0..<10 { size = screen.snapshot().count } }
            report("screen.snapshot.\(cols)x\(rows)", ms / 10, "ms")
            report("screen.snapshot.\(cols)x\(rows).bytes", Double(size), "bytes")
            #expect(size > 0)
        }
    }

    @Test func stateUpdateCostByFleetSize() throws {
        let dir = try uniqueDirectory("bench")
        defer { try? FileManager.default.removeItem(at: dir) }
        for agentCount in [10, 50, 200] {
            let store = StateStore(url: dir.appendingPathComponent("state-\(agentCount).json"))
            let space = Space(name: "s", path: "/tmp/s")
            let agents = (0..<agentCount).map { _ in Fixture.agent(in: space) }
            try store.update { $0 = Fixture.workspace(agents, space: space) }
            let iterations = 50
            let ms = milliseconds {
                for i in 0..<iterations {
                    try? store.update { $0.agents[i % agentCount].status = i % 2 == 0 ? .working : .idle }
                }
            }
            report("state.update.\(agentCount)agents", ms / Double(iterations), "ms")
            #expect(store.state.agents.count == agentCount)
        }
    }

    /// Host memory per live session: PTY plus a screen with full scrollback.
    @Test func hostMemoryPerSession() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let count = 20
        let lines = SessionScreen.defaultScrollbackLines + 24
        let before = residentBytes()
        var ids: [SessionID] = []
        for _ in 0..<count {
            let info = try await h.shell(
                "awk 'BEGIN{for(i=1;i<=\(lines);i++)print \"\\033[32mline \" i \"\\033[0m ------------------------------\"}'; sleep 60",
                cols: 120, rows: 40)
            ids.append(info.id)
        }
        for id in ids { try await h.waitForScreen(id, toContain: "line \(lines) ", timeout: .seconds(30)) }
        report("host.memory.perSession", (residentBytes() - before) / Double(count) / 1_048_576, "MiB")
        #expect(ids.count == count)
    }
}
