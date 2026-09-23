import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// A remote Shepherd driving the host's sessions over TCP: attach/replay/stream, input and
/// paste, exits, and output framing.
@Suite("Remote sessions")
struct RemoteSessionTests {
    @Test func attachReplaysTheScreenThenStreamsLiveOutput() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let info = try await r.host.shell("echo REPLAY_MARKER; cat")
        try await r.host.waitForScreen(info.id, toContain: "REPLAY_MARKER")
        let client = try await r.typed()
        defer { client.disconnect() }
        let received = Locked(Data())
        client.onOutput = { id, data in if id == info.id { received.withValue { $0.append(data) } } }

        let attachment = try await client.attach(sessionID: info.id, cols: 100, rows: 30)
        #expect(attachment.sessionID == info.id && attachment.cols == 100 && attachment.rows == 30)
        try await eventually("the replay") { String(decoding: received.current, as: UTF8.self).contains("REPLAY_MARKER") }
        client.write(sessionID: info.id, data: Data("hello-from-remote\n".utf8))
        try await eventually("the echoed input") { String(decoding: received.current, as: UTF8.self).contains("hello-from-remote") }
    }

    @Test func detachStopsTheStreamButInputStillWorks() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let info = try await r.host.shell("stty -echo; cat")
        let client = try await r.raw()
        try client.send(.attach(id: 2, sessionID: info.id, cols: 80, rows: 24, viewportGeneration: 0))
        guard case .attached = try await client.next() else { Issue.record("expected attached"); return }

        try client.send(.detach(sessionID: info.id))
        try client.send(.input(sessionID: info.id, data: Data("after-detach\n".utf8)))
        try await r.host.waitForScreen(info.id, toContain: "after-detach")
        // Anything streamed after detach would sit before this reply on the same connection.
        try client.send(.stateFetch(id: 3))
        let frames = try await client.frames(until: { if case .state = $0 { true } else { false } })
        let streamed = frames.compactMap(\.outputData).reduce(Data(), +)
        #expect(!String(decoding: streamed, as: UTF8.self).contains("after-detach"))
    }

    @Test func attachedClientsHearTheExit() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let info = try await r.host.shell("sleep 30")
        let client = try await r.typed()
        defer { client.disconnect() }
        let exited = Locked<SessionID?>(nil)
        client.onSessionExited = { id, _ in exited.withValue { $0 = id } }
        _ = try await client.attach(sessionID: info.id, cols: 80, rows: 24)

        r.server.killSession(info.id)
        try await eventually("the exit push") { exited.current == info.id }
    }

    @Test func attachingADeadSessionReplaysItAndReportsTheExit() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let info = try await r.host.shell("printf final-words")
        try await r.host.waitForScreen(info.id, toContain: "final-words")
        try await r.host.waitForExit(info.id)
        let client = try await r.raw()
        try client.send(.attach(id: 2, sessionID: info.id, cols: 80, rows: 24, viewportGeneration: 4))
        let frames = try await client.frames(until: { if case .sessionExited = $0 { true } else { false } })
        #expect(frames.first == .attached(id: 2, attachment: RemoteAttachment(sessionID: info.id, cols: 80, rows: 24, viewportGeneration: 4)))
        #expect(String(decoding: frames.compactMap(\.outputData).reduce(Data(), +), as: UTF8.self).contains("final-words"))
    }

    @Test func attachFailsForUnknownAndRPCSessions() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let pi = try await PiAgent.launch(on: r.host)
        let client = try await r.raw()
        let unknown = SessionID()
        try client.send(.attach(id: 2, sessionID: unknown, cols: 80, rows: 24, viewportGeneration: 0))
        #expect(try await client.next() == .error(id: 2, code: "no_such_session", message: "unknown session \(unknown)"))
        try client.send(.attach(id: 3, sessionID: pi.sessionID, cols: 80, rows: 24, viewportGeneration: 0))
        guard case .error(3, "no_terminal", _) = try await client.next() else { Issue.record("expected no_terminal"); return }
    }

    /// A replay larger than one frame is split so every frame stays under the NDJSON cap.
    @Test func aLargeReplayIsChunkedUnderTheFrameLimit() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let lines = SessionScreen.defaultScrollbackLines + 60
        let info = try await r.host.shell(
            "awk 'BEGIN{for(i=1;i<=\(lines);i++)printf \"\\033[3%dmline %d %s\\033[0m\\n\", i%7+1, i, sprintf(\"%180s\",\"\")}' | tr ' ' '='; echo END; sleep 30",
            cols: 200, rows: 50)
        try await r.host.waitForScreen(info.id, toContain: "END")
        let client = try await r.raw()
        try client.send(.attach(id: 2, sessionID: info.id, cols: 0, rows: 0, viewportGeneration: 0))
        guard case .attached = try await client.next() else { Issue.record("expected attached"); return }

        let expected = try await r.server.attachSnapshot(sessionID: info.id, replay: true).replay
        #expect(expected.count > SessionServer.remoteOutputChunkBytes, "the scenario must need more than one frame")
        var chunks: [Data] = []
        while chunks.reduce(0, { $0 + $1.count }) < expected.count {
            guard let data = try await client.next().outputData else { Issue.record("expected output frames"); return }
            chunks.append(data)
        }
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= SessionServer.remoteOutputChunkBytes })
        let intact = chunks.reduce(Data(), +) == expected
        #expect(intact)
    }

    @Test func pasteDeliversOneBracketedBlockThenSubmitAndIsAcknowledged() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let info = try await r.host.shell("stty -echo; cat -v")
        let client = try await r.typed()
        defer { client.disconnect() }

        try await client.paste(sessionID: info.id, text: "line one\nline two", submit: true)
        try await r.host.waitForScreen(info.id, toContain: "^[[201~")
        let screen = await r.host.screen(info.id)
        #expect(screen.contains("^[[200~line one"))
        #expect(screen.contains("line two^[[201~"))
    }

    @Test func pasteToADeadSessionIsARejection() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let info = try await r.host.shell("exit 0")
        try await r.host.waitForExit(info.id)
        let client = try await r.typed()
        defer { client.disconnect() }
        let error = await #expect(throws: RemoteHostClientError.self) { try await client.paste(sessionID: info.id, text: "late", submit: true) }
        guard case .rejected("no_such_session", _)? = error else { Issue.record("got \(String(describing: error))"); return }
    }

    /// A stalled remote UI must not queue one main-queue closure per frame: the client merges
    /// output while a delivery is in flight, without losing or reordering a byte.
    @Test func aStalledRemoteUIReceivesMergedCompleteOutput() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let lines = 20_000
        let info = try await r.host.shell(
            "stty -echo -opost; IFS= read -r _; awk 'BEGIN{for(i=1;i<=\(lines);i++)print \"line \" i \" -----------------------------------\"}'; printf END; sleep 30",
            cols: 120, rows: 40)
        let client = try await r.typed()
        defer { client.disconnect() }
        let received = Locked(Data())
        let deliveries = Locked(0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let stalled = Locked(false)
        client.onOutput = { id, data in
            guard id == info.id else { return }
            received.withValue { $0.append(data) }
            deliveries.withValue { $0 += 1 }
            if !stalled.current, String(decoding: data, as: UTF8.self).contains("line 1 ") {
                stalled.withValue { $0 = true }
                release.wait()
            }
        }
        _ = try await client.attach(sessionID: info.id, cols: 120, rows: 40)
        client.write(sessionID: info.id, data: Data("go\n".utf8))
        try await eventually("the UI to stall") { stalled.current }
        try await r.host.waitForScreen(info.id, toContain: "END", timeout: .seconds(30))
        release.signal()

        try await eventually("every byte", timeout: .seconds(30)) { received.current.suffix(3) == Data("END".utf8) }
        let text = String(decoding: received.current, as: UTF8.self)
        var cursor = text.startIndex
        for i in stride(from: 1, through: lines, by: 997) {
            guard let found = text.range(of: "line \(i) ", range: cursor..<text.endIndex) else { Issue.record("line \(i) missing or out of order"); return }
            cursor = found.upperBound
        }
        #expect(deliveries.current < 20, "\(deliveries.current) deliveries")
    }

    @Test func hostShutdownDisconnectsTheClient() async throws {
        let r = try RemoteHost()
        let client = try await r.typed()
        let dropped = Locked(false)
        client.onDisconnected = { _ in dropped.withValue { $0 = true } }
        r.stop()
        try await eventually("the disconnect") { dropped.current }
    }
}
