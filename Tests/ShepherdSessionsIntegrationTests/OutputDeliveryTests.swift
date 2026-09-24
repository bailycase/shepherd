import Foundation
import Testing
import ShepherdCore
@testable import ShepherdSessions
import ShepherdTestSupport

/// How PTY bytes reach the pane: merged per session (one main-queue delivery in flight), bounded
/// by backpressure, exact across attach (snapshot + watermark), and never after detach.
@Suite("Terminal output delivery", .integrationTimeLimit)
struct OutputDeliveryTests {
    /// `awk` numbered lines: one burst, deterministic bytes.
    private static func numberedLines(_ count: Int) -> String {
        "awk 'BEGIN{for(i=1;i<=\(count);i++)print \"line \" i \" ---------------------------------------------\"}'"
    }

    private func expectInOrder(_ text: String, lines count: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        var cursor = text.startIndex
        for i in stride(from: 1, through: count, by: 997) {
            guard let found = text.range(of: "line \(i) ", range: cursor..<text.endIndex) else {
                Issue.record("line \(i) missing or out of order", sourceLocation: sourceLocation)
                return
            }
            cursor = found.upperBound
        }
    }

    /// A big repaint is hundreds of PTY reads; delivering each separately floods the main
    /// thread. Merging must never lose or reorder a byte.
    @Test func aLargeBurstArrivesCompleteInOrderAndMerged() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let lines = 20_000
        let info = try await h.shell("stty -echo -opost; IFS= read -r _; \(Self.numberedLines(lines)); printf END", cols: 120, rows: 40)
        _ = try await h.server.attachSnapshot(sessionID: info.id, replay: false)
        h.server.write(sessionID: info.id, data: Data("start\n".utf8))

        try await eventually("the final marker", timeout: .seconds(30)) { callbacks.text(info.id).hasSuffix("END") }
        expectInOrder(callbacks.text(info.id), lines: lines)
        // ~1.2 MiB is over a thousand PTY reads unmerged. How many merge depends on the child's
        // speed against the main queue's: a slow child beside an idle main queue has each read
        // delivered alone, so CI checks only that every byte arrived in order.
        if TimingTests.enabled { #expect((callbacks.deliveries.current[info.id] ?? 0) < 300) }
    }

    /// The pane renders the attach snapshot and then only later output; together they must equal
    /// the host's screen exactly, even when attach lands mid-burst with output still buffered.
    @Test func snapshotPlusLiveOutputReproducesTheHostScreen() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let live = Locked<[(Data, UInt64)]>([])
        h.server.onSequencedOutput = { _, data, sequence in live.withValue { $0.append((data, sequence)) } }
        let script = "stty -echo; i=0; while [ $i -lt 1500 ]; do echo \"first $i\"; i=$((i+1)); done; " +
            "IFS= read -r _; i=0; while [ $i -lt 1500 ]; do echo \"second $i\"; i=$((i+1)); done; echo DONE; sleep 30"
        let info = try await h.shell(script)
        try await h.waitForScreen(info.id, toContain: "first 1")

        let snapshot = try await h.server.attachSnapshot(sessionID: info.id, replay: true)
        h.server.write(sessionID: info.id, data: Data("go\n".utf8))
        try await h.waitForScreen(info.id, toContain: "DONE")
        await drainMainQueue()

        let pane = SessionScreen(cols: 80, rows: 24)
        pane.feed(snapshot.replay)
        for (data, sequence) in live.current {
            #expect(sequence > snapshot.watermark, "a delivery the snapshot already represents")
            pane.feed(data)
        }
        var rendered = pane.visibleText()
        while rendered.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { rendered.removeLast() }
        let host = await h.server.screenText(sessionID: info.id)
        #expect(rendered == host)
    }

    /// Output still buffered at attach is already in the snapshot; delivering it too drew pi's
    /// splash screen twice.
    @Test func attachDoesNotAlsoDeliverOutputTheSnapshotContains() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let marker = "SPLASH-SCREEN-MARKER"
        let info = try await h.shell("printf '\(marker)\\n'; sleep 30")
        try await h.waitForScreen(info.id, toContain: marker)

        let replay = try await h.server.attach(sessionID: info.id, replay: true)
        await drainMainQueue()
        let rendered = String(decoding: replay, as: UTF8.self) + callbacks.text(info.id)
        #expect(rendered.components(separatedBy: marker).count == 2)
    }

    @Test func outputAfterDetachIsNeverDelivered() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let info = try await h.shell("stty -echo; IFS= read -r _; echo after-detach; sleep 30")
        _ = try await h.server.attachSnapshot(sessionID: info.id, replay: false)
        h.server.detach(sessionID: info.id)
        h.server.write(sessionID: info.id, data: Data("go\n".utf8))

        try await h.waitForScreen(info.id, toContain: "after-detach")
        await drainMainQueue()
        #expect(!callbacks.text(info.id).contains("after-detach"))
    }

    /// Attach submits before returning, so a detach or re-attach issued right after it is
    /// ordered behind it; the completions still arrive with full snapshots.
    @Test(arguments: [false, true])
    @MainActor
    func aPendingAttachIsOrderedBeforeDetachAndReplacement(replace: Bool) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let info = try await h.shell("stty -echo -opost; printf 'READY\\n'; while IFS= read -r line; do printf '%s\\n' \"$line\"; done")
        try await h.waitForScreen(info.id, toContain: "READY")
        let replies = Locked<[AttachmentSnapshot]>([])

        h.server.attachSnapshot(sessionID: info.id, replay: true) { result in
            if let snapshot = try? result.get() { replies.withValue { $0.append(snapshot) } }
        }
        h.server.detach(sessionID: info.id)
        if replace {
            h.server.attachSnapshot(sessionID: info.id, replay: true) { result in
                if let snapshot = try? result.get() { replies.withValue { $0.append(snapshot) } }
            }
        }
        #expect(replies.current.isEmpty, "completions run later on the main queue")
        h.server.write(sessionID: info.id, data: Data("after\n".utf8))

        try await h.waitForScreen(info.id, toContain: "after")
        await drainMainQueue()
        #expect(replies.current.count == (replace ? 2 : 1))
        for snapshot in replies.current {
            #expect(String(decoding: snapshot.replay, as: UTF8.self).components(separatedBy: "READY").count == 2)
            #expect(snapshot.outputSequence > 0)
        }
        #expect(callbacks.text(info.id) == (replace ? "after\n" : ""))
    }

    /// The pane retires a session from its exit callback, so exit must trail the last byte.
    @Test func theExitCallbackTrailsTheFinalOutput() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let received = Locked(Data())
        let exits = Locked<[Bool]>([])
        let lines = 20_000
        let finalLine = Data("line \(lines) ".utf8)
        h.server.onOutput = { _, data in received.withValue { $0.append(data) } }
        h.server.onSessionExited = { _, _ in exits.withValue { $0.append(received.current.range(of: finalLine) != nil) } }
        let info = try await h.shell("stty -echo -opost; IFS= read -r _; \(Self.numberedLines(lines)); exit 0")
        _ = try await h.server.attachSnapshot(sessionID: info.id, replay: false)
        h.server.write(sessionID: info.id, data: Data("go\n".utf8))

        try await eventually("the exit callback", timeout: .seconds(30)) { !exits.current.isEmpty }
        await drainMainQueue()
        #expect(exits.current == [true], "exactly one exit, after the final line was delivered")
    }

    /// A stalled renderer must stop the PTY before the child finishes; released, every byte
    /// still arrives in order. The stall blocks the main queue, so it runs in its own process
    /// where no other test waits on that queue.
    @Test func aStalledRendererBackpressuresTheChildWithoutLosingBytes() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors {
                let h = try ScratchServer()
                defer { h.stop() }
                let release = DispatchSemaphore(value: 0)
                defer { release.signal() }
                let received = Locked(Data())
                let stalled = Locked(false)
                let payloadCount = 6 * 1024 * 1024
                h.server.onOutput = { _, data in
                    received.withValue { $0.append(data) }
                    if !stalled.current, data.range(of: Data("READY".utf8)) != nil {
                        stalled.withValue { $0 = true }
                        release.wait()
                    }
                }
                let info = try await h.shell(
                    "stty raw -echo -opost; IFS= read -r _; printf READY; awk 'BEGIN{for(i=1;i<=2000000;i++)print i}' | head -c \(payloadCount); printf END; sleep 30")
                _ = try await h.server.attachSnapshot(sessionID: info.id, replay: false)
                h.server.write(sessionID: info.id, data: Data("go\n".utf8))
                try await eventually("the renderer to stall", timeout: .seconds(20)) { stalled.current }

                // Reading stops at the high-water mark: the host screen freezes short of the tail.
                // Reaching it feeds 4 MiB through the host's debug-build screen first, which took
                // 14 s on a loaded machine.
                var previous = ""
                var unchanged = 0
                try await eventually("the host screen to stop advancing", timeout: .seconds(60)) {
                    let now = await h.screen(info.id)
                    unchanged = now == previous ? unchanged + 1 : 0
                    previous = now
                    return unchanged >= 5
                }
                #expect(!(await h.screen(info.id)).contains("END"), "the child reached its tail while the renderer was stalled")
                release.signal()

                var payload = Data(capacity: payloadCount)
                var n = 1
                while payload.count < payloadCount { payload.append(contentsOf: "\(n)\n".utf8); n += 1 }
                let expected = Data("READY".utf8) + payload.prefix(payloadCount) + Data("END".utf8)
                // Anything before READY is the tty echoing "go" if it beat `stty -echo`.
                func fromReady() -> Data {
                    let all = received.current
                    return all.range(of: Data("READY".utf8)).map { all[$0.lowerBound...] } ?? Data()
                }
                try await eventually("every byte after release", timeout: .seconds(30)) { fromReady().count >= expected.count }
                let intact = fromReady() == expected
                #expect(intact, "payload differs: \(fromReady().count) of \(expected.count) bytes")
            }
        }
    }
}
