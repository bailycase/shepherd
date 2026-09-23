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
    /// The child once reset signals with a Swift `for` loop, which in unoptimised builds took the
    /// runtime's metadata lock: about half of 150 forks died pre-exec. The child side is now C
    /// (ShepherdPTYSpawn).
    @Test func freshSessionsSurviveForkingWhileOtherThreadsUseTheSwiftRuntime() async throws {
        let h = try ScratchServer(dir: makeScratchDirectory("fork"))
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
