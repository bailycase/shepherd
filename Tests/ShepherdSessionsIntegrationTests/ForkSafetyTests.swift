import Foundation
import Testing
import ShepherdCore
@testable import ShepherdSessions
import ShepherdTestSupport

/// Between fork and exec a PTY child may only make async-signal-safe calls (AGENTS.md: "PTY
/// children"). A child that touches the Swift runtime there can deadlock or crash whenever
/// another thread holds a runtime lock at the moment of the fork.
@Suite("PTY fork safety")
struct ForkSafetyTests {
    @Test(.disabled("""
        bug: PTYSession.init resets signal dispositions in the forked child with `for sig in 1..<NSIG`; \
        unoptimized builds (swift test, the Dev scheme) run that loop through IndexingIterator and \
        swift_getTupleTypeMetadata2, which takes the runtime's metadata-cache os_unfair_lock. If any \
        other thread held it at fork time the child aborts pre-exec ("crashed on child side of fork \
        pre-exec", EXC_BREAKPOINT → SIGKILL) and the new pane dies at once with an empty screen. \
        Reproduces in ~half of 150 forks when run alone; a C-style loop or a C helper would keep \
        the child in async-signal-safe code.
        """))
    func freshSessionsSurviveForkingWhileOtherThreadsUseTheSwiftRuntime() async throws {
        // Not `ScratchServer.fresh()`: that warms the child's metadata in this process, which masks
        // the bug. Run this test alone; any earlier warm-up in the same process hides it too.
        let h = try ScratchServer(dir: uniqueDirectory("fork"))
        defer { h.stop() }
        let exits = Locked<[SessionID: Int32?]>([:])
        h.server.onSessionExited = { id, code in exits.withValue { $0[id] = code } }
        // Other threads instantiating tuple metadata, as any generic code does on first use; each
        // instantiation holds the runtime's tuple-metadata lock the child's loop then needs.
        let stop = Locked(false)
        let busy = (0..<4).map { _ in
            Thread {
                while !stop.current { _ = freshTupleType(depth: 24) }
            }
        }
        busy.forEach { $0.start() }
        defer { stop.withValue { $0 = true } }

        var ids: [SessionID] = []
        for _ in 0..<150 { ids.append(try await h.shell("exit 0").id) }
        try await eventually("every session to exit", timeout: .seconds(30)) { exits.current.count == ids.count }
        let killed = exits.current.values.filter { $0 == nil }.count
        #expect(killed == 0, "\(killed) of \(ids.count) children died before exec")
    }
}

/// A tuple type nobody has instantiated yet: a random path through `(T, Int)` / `(Int, T)`.
private func freshTupleType(depth: Int) -> Any.Type {
    func grow<T>(_: T.Type, _ remaining: Int) -> Any.Type {
        guard remaining > 0 else { return T.self }
        return Bool.random() ? grow((T, Int).self, remaining - 1) : grow((Int, T).self, remaining - 1)
    }
    return grow(Int.self, depth)
}
