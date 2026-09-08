import Foundation
import Testing
import ShepherdCore
@testable import ShepherdSessions

/// A big repaint — `/resume` on a long pi transcript, a build, a log tail —
/// arrives as hundreds of 64 KiB reads in a burst. Delivering each separately
/// floods the main thread and freezes the whole app, so output is merged per
/// session. Merging must never reorder or lose a byte.
@Suite("Output coalescing", .serialized)
struct OutputCoalescingTests {
    private struct Harness {
        let dir: URL
        let server: SessionServer

        init() throws {
            dir = try makeScratchDirectory()
            server = SessionServer(
                socketPath: dir.appendingPathComponent("d.sock").path,
                stateURL: dir.appendingPathComponent("state.json")
            )
            try server.start()
        }

        func tearDown() {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// The exact bytes a child writes must reach the pane, in order, however
    /// they were chunked on the way.
    @Test func largeBurstArrivesCompleteAndInOrder() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        // ~2 MiB of numbered lines: big enough to span many PTY reads.
        let lineCount = 20_000
        let info = try await h.server.createSession(
            params: CreateSessionParams(
                cwd: "/tmp",
                command: [
                    "/bin/sh", "-c",
                    // One awk burst, not a shell loop: a slow runner's loop
                    // trickles lines out and there is no burst to coalesce.
                    "stty -echo -opost; IFS= read -r _; awk 'BEGIN{for(i=1;i<=\(lineCount);i++)print \"line \" i \" ---------------------------------------------\"}'",
                ],
                cols: 120,
                rows: 40,
                env: nil
            )
        )
        defer { h.server.killSession(info.id) }

        let received = Locked<Data>(Data())
        let deliveries = Locked<Int>(0)
        h.server.onOutput = { (sessionID: SessionID, data: Data) in
            guard sessionID == info.id else { return }
            received.withValue { $0.append(data) }
            deliveries.withValue { $0 += 1 }
        }

        _ = try await h.server.attach(sessionID: info.id, replay: false)
        h.server.write(sessionID: info.id, data: Data("start\n".utf8))

        // Wait for the last line rather than a fixed sleep.
        let done = try await waitUntil(timeout: .seconds(30)) {
            String(decoding: received.current, as: UTF8.self).contains("line \(lineCount) ")
        }
        #expect(done, "never saw the final line")

        let text = String(decoding: received.current, as: UTF8.self)

        // Every line present, in order: a merge that dropped or reordered a
        // chunk would show up as a missing or out-of-sequence number.
        var searchIndex = text.startIndex
        for i in stride(from: 1, through: lineCount, by: 997) {
            guard let found = text.range(of: "line \(i) ", range: searchIndex..<text.endIndex) else {
                Issue.record("line \(i) missing or out of order")
                return
            }
            searchIndex = found.upperBound
        }

        // Coalescing must actually be doing something: far fewer deliveries
        // than the number of PTY reads such a burst produces (~1124 without
        // coalescing, 1 with it, locally). Slow shared runners spread the
        // burst out, so the bound is loose — it only has to prove merging.
        #expect(deliveries.current < 300,
                "expected merged deliveries, got \(deliveries.current)")
    }

    /// Attach must stay atomic even with coalescing: bytes still buffered when
    /// a pane attaches are already represented in the snapshot, so delivering
    /// them as well replays that output on top of it. The visible symptom was
    /// pi's splash screen drawn twice, with two prompt boxes.
    @Test func attachDoesNotAlsoDeliverBufferedOutput() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let marker = "SPLASH-SCREEN-MARKER"
        let info = try await h.server.createSession(
            params: CreateSessionParams(
                cwd: "/tmp",
                command: ["/bin/sh", "-c", "printf '\(marker)\\n'; sleep 30"],
                cols: 80,
                rows: 24,
                env: nil
            )
        )
        defer { h.server.killSession(info.id) }

        let live = Locked<Data>(Data())
        h.server.onOutput = { (sessionID: SessionID, data: Data) in
            guard sessionID == info.id else { return }
            live.withValue { $0.append(data) }
        }

        // Attach *while* the child is producing output, so some has been read
        // into the screen (and possibly buffered) before the snapshot.
        try await Task.sleep(for: .milliseconds(300))
        let replay = try await h.server.attach(sessionID: info.id, replay: true)
        try await Task.sleep(for: .milliseconds(500))

        // What the pane feeds its surface: the snapshot, then live output.
        let rendered = String(decoding: replay, as: UTF8.self)
            + String(decoding: live.current, as: UTF8.self)
        let occurrences = rendered.components(separatedBy: marker).count - 1
        #expect(occurrences == 1, "startup output rendered \(occurrences)x")
    }

    /// A blocked renderer must stop the PTY before the child reaches its
    /// final marker. Once released, every byte still arrives in order.
    @Test func stalledRendererBackpressuresWithoutLosingBytes() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let release = DispatchSemaphore(value: 0)

        let payloadCount = 8 * 1024 * 1024
        // Keep the producer raw so PTY output processing cannot rewrite the
        // bytes under test. awk emits a deterministic numbered stream (BSD
        // seq prints "1e+06" past a million; awk always prints integers).
        let info = try await h.server.createSession(
            params: CreateSessionParams(
                cwd: "/tmp",
                command: [
                    "/bin/sh", "-c",
                    "stty raw -echo -opost; sleep 0.1; printf READY; sleep 0.2; awk 'BEGIN{for(i=1;i<=2000000;i++)print i}' | head -c \(payloadCount); printf END; sleep 1",
                ],
                cols: 80,
                rows: 24,
                env: nil
            )
        )
        defer {
            release.signal()
            h.server.killSession(info.id)
        }

        let received = Locked<Data>(Data())
        let entered = Locked(false)
        h.server.onOutput = { (sessionID: SessionID, data: Data) in
            guard sessionID == info.id else { return }
            received.withValue { $0.append(data) }
            if data.range(of: Data("READY".utf8)) != nil {
                entered.withValue { $0 = true }
                release.wait()
            }
        }

        _ = try await h.server.attach(sessionID: info.id, replay: false)
        #expect(try await waitUntil(timeout: .seconds(10)) { entered.current })

        // The child is still trying to write the payload while the first
        // delivery is blocked. A drained tail would mean the PTY read source
        // ignored its high-water mark.
        try await Task.sleep(for: .milliseconds(700))
        let stalledScreen = await h.server.screenText(sessionID: info.id)?.joined(separator: "\n") ?? ""
        #expect(!stalledScreen.contains("END"), "child reached its tail while renderer was stalled")
        #expect(await h.server.sessionInfo(sessionID: info.id)?.isAlive == true)

        release.signal()

        var payload = Data(capacity: payloadCount)
        for index in 1...2_000_000 where payload.count < payloadCount {
            payload.append(contentsOf: "\(index)\n".utf8)
        }
        payload = Data(payload.prefix(payloadCount))
        let expected = Data("READY".utf8) + payload + Data("END".utf8)

        #expect(try await waitUntil(timeout: .seconds(30)) { received.current.count >= expected.count })
        let actual = received.current
        // Never hand multi-MiB blobs to #expect(a == b): on failure Swift
        // Testing runs a Myers diff over them, which spins for hours.
        let firstMismatch = zip(actual, expected).enumerated().first { $1.0 != $1.1 }?.offset
        var detail = "payload mismatch: counts \(actual.count)/\(expected.count)"
        if let at = firstMismatch {
            let lo = max(0, at - 40), hi = min(min(actual.count, expected.count), at + 40)
            let a = String(decoding: actual[lo..<hi], as: UTF8.self)
            let e = String(decoding: expected[lo..<hi], as: UTF8.self)
            detail += ", first divergence at \(at):\n  actual: \(a.debugDescription)\nexpected: \(e.debugDescription)"
        }
        #expect(actual.count == expected.count && firstMismatch == nil, Comment(rawValue: detail))
    }

    /// Output buffered for a pane that detaches must not be delivered later.
    @Test func detachDropsBufferedOutput() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let info = try await h.server.createSession(
            params: CreateSessionParams(
                cwd: "/tmp",
                command: ["/bin/sh", "-c", "sleep 0.2; echo after-detach; sleep 5"],
                cols: 80,
                rows: 24,
                env: nil
            )
        )
        defer { h.server.killSession(info.id) }

        let received = Locked<Data>(Data())
        h.server.onOutput = { (sessionID: SessionID, data: Data) in
            guard sessionID == info.id else { return }
            received.withValue { $0.append(data) }
        }

        _ = try await h.server.attach(sessionID: info.id, replay: false)
        h.server.detach(sessionID: info.id)

        try await Task.sleep(for: .seconds(1))
        #expect(!String(decoding: received.current, as: UTF8.self).contains("after-detach"))
    }
}
