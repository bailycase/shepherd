import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Terminal panes: real PTY children owned by the server — spawn, I/O, resize, exit, and the
/// process-group kill rules that keep nothing alive after its pane or the app is gone.
@Suite("Terminal sessions", .integrationTimeLimit)
struct TerminalSessionTests {
    private func pid(in file: URL) throws -> pid_t {
        pid_t(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
    }

    private func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    // MARK: - Spawn and I/O

    @Test func anAttachedSessionStreamsOutputAndReportsItsExitCode() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let info = try await h.shell("stty -echo; IFS= read -r _; printf ready; exit 7")
        #expect(info.isAlive)

        _ = try await h.server.attachSnapshot(sessionID: info.id, replay: false)
        h.server.write(sessionID: info.id, data: Data("go\n".utf8))
        try await eventually("live output") { callbacks.text(info.id).contains("ready") }
        try await eventually("the exit callback") { callbacks.exited(info.id) }
        #expect(callbacks.exitCode(info.id) == .some(7))
        #expect(await h.server.sessionInfo(sessionID: info.id)?.isAlive == false)
    }

    @Test func outputFromBeforeAttachArrivesOnlyThroughTheReplay() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let info = try await h.shell("printf marker123; sleep 30")
        try await h.waitForScreen(info.id, toContain: "marker123")

        let snapshot = try await h.server.attachSnapshot(sessionID: info.id, replay: true)
        #expect(String(decoding: snapshot.replay, as: UTF8.self).contains("marker123"))
        #expect(snapshot.outputSequence > 0)
        await drainMainQueue()
        #expect(callbacks.output.current[info.id] == nil)
    }

    @Test func attachWithoutReplayReturnsOnlyTheWatermark() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let info = try await h.shell("printf marker; sleep 30")
        try await h.waitForScreen(info.id, toContain: "marker")

        let snapshot = try await h.server.attachSnapshot(sessionID: info.id, replay: false)
        #expect(snapshot.replay.isEmpty)
        #expect(snapshot.watermark > 0)
    }

    @Test func aDeadSessionIsAttachableUntilRetired() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let info = try await h.shell("printf late-snapshot")
        try await h.waitForScreen(info.id, toContain: "late-snapshot")
        try await h.waitForExit(info.id)

        let replay = try await h.server.attach(sessionID: info.id, replay: true)
        #expect(String(decoding: replay, as: UTF8.self).contains("late-snapshot"))
        #expect(await h.server.listSessions().map(\.id) == [info.id])

        await h.server.retireSession(sessionID: info.id)
        await h.server.retireSession(sessionID: info.id)
        #expect(await h.server.listSessions().isEmpty)
        let error = await #expect(throws: SessionServerError.self) { _ = try await h.server.attach(sessionID: info.id, replay: true) }
        #expect(error?.description == SessionServerError.noSuchSession(info.id).description)
    }

    @Test func retiringALiveSessionIsIgnored() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let info = try await h.shell("sleep 30")
        await h.server.retireSession(sessionID: info.id)
        #expect(await h.server.sessionInfo(sessionID: info.id)?.isAlive == true)
    }

    @Test func attachingAnUnknownSessionFails() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let id = SessionID()
        let error = await #expect(throws: SessionServerError.self) { _ = try await h.server.attach(sessionID: id, replay: true) }
        #expect(error?.description == SessionServerError.noSuchSession(id).description)
    }

    @Test func aMissingExecutableFailsToSpawn() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        await #expect(throws: PTYSession.SpawnError.self) {
            _ = try await h.server.createSession(params: CreateSessionParams(cwd: "/", command: ["/nonexistent/definitely-not-here"]))
        }
    }

    /// Children see the terminal Shepherd actually is, not whichever one launched the app.
    @Test func childrenGetShepherdsTerminalIdentity() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let info = try await h.shell(
            #"printf '%s|%s|%s|%s|%s|%s' "$TERM" "$COLORTERM" "$TERM_PROGRAM" "${GHOSTTY_RESOURCES_DIR-unset}" "${TMUX-unset}" "$EXTRA"; sleep 30"#,
            env: ["TERM": "dumb", "COLORTERM": "false", "TERM_PROGRAM": "ghostty",
                  "GHOSTTY_RESOURCES_DIR": "/tmp/stale", "TMUX": "/tmp/stale-tmux", "EXTRA": "passed"])
        try await h.waitForScreen(info.id, toContain: "xterm-256color|truecolor|Shepherd|unset|unset|passed")
    }

    /// The app ignores some signals; a child must not inherit that, or kills escalate to SIGKILL.
    /// A signal disposition is process-wide, so the test ignores SIGTERM in its own process.
    @Test func childrenStartWithDefaultSignalDispositions() async {
        await #expect(processExitsWith: .success) {
            _ = signal(SIGTERM, SIG_IGN)
            let h = try ScratchServer()
            defer { h.stop() }
            let info = try await h.server.createSession(params: CreateSessionParams(cwd: "/", command: [
                "python3", "-c", "import signal; print('TERM=' + ('default' if signal.getsignal(signal.SIGTERM) == signal.SIG_DFL else 'inherited'))",
            ]))
            try await h.waitForScreen(info.id, toContain: "TERM=")
            let screen = await h.screen(info.id)
            #expect(screen.contains("TERM=default"), "\(screen)")
        }
    }

    @Test func inputIsDeliveredInOrderToALateReader() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let info = try await h.shell("stty raw -echo -opost; printf READY; sleep 0.3; cat")
        try await h.waitForScreen(info.id, toContain: "READY")
        _ = try await h.server.attachSnapshot(sessionID: info.id, replay: false)

        var payload = Data()
        for i in 0..<8_192 { payload.append(Data(String(format: "%08d:%023d\n", i, i).utf8)) }
        h.server.write(sessionID: info.id, data: payload)
        // The queued input must not hold the server queue while the child is not reading yet.
        _ = await h.server.listSessions()

        try await eventually("every byte echoed back") { (callbacks.output.current[info.id]?.count ?? 0) >= payload.count }
        let intact = callbacks.output.current[info.id] == payload
        #expect(intact)
    }

    @Test func writesToADeadSessionAreIgnored() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let info = try await h.shell("exit 0")
        try await h.waitForExit(info.id)
        h.server.write(sessionID: info.id, data: Data("echo nope\r".utf8))
        h.server.resize(sessionID: info.id, cols: 10, rows: 5)
        #expect(await h.server.sessionInfo(sessionID: info.id)?.isAlive == false)
    }

    // MARK: - Resize and foreground

    @Test func resizeReachesThePtyAndASameSizeResizeStillNudgesARepaint() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let info = try await h.shell("trap 'echo size=$(stty size)' WINCH; echo READY; while :; do sleep 0.05; done")
        try await h.waitForScreen(info.id, toContain: "READY")

        h.server.resize(sessionID: info.id, cols: 100, rows: 30)
        try await h.waitForScreen(info.id, toContain: "size=30 100")
        #expect(await h.server.sessionInfo(sessionID: info.id).map { [$0.cols, $0.rows] } == [100, 30])

        // A reattached surface needs a redraw even when the grid did not change.
        h.server.resize(sessionID: info.id, cols: 100, rows: 30)
        try await eventually("a second SIGWINCH") {
            await h.screen(info.id).components(separatedBy: "size=30 100").count == 3
        }
    }

    @Test func theForegroundProcessIsReported() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let info = try await h.shell("cd /tmp && exec sleep 30")
        try await eventually("sleep to take the foreground") { await h.server.foregroundProcessName(sessionID: info.id) == "sleep" }
        #expect(await h.server.foregroundCommandLine(sessionID: info.id) == "sleep 30")
        let cwd = await h.server.foregroundWorkingDirectory(sessionID: info.id)
        #expect(cwd == "/private/tmp")
        #expect(await h.server.foregroundProcessName(sessionID: SessionID()) == nil)
    }

    // MARK: - Kill and shutdown

    @Test func killSessionTerminatesWithSIGTERMAndIsIdempotent() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let info = try await h.shell("sleep 100")

        h.server.killSession(info.id)
        try await eventually("the kill to land") { callbacks.exited(info.id) }
        #expect(callbacks.exitCode(info.id) == .some(nil), "killed by a signal, so no exit code")
        h.server.killSession(info.id)
        h.server.killSession(SessionID())
        #expect(await h.server.listSessions().map(\.isAlive) == [false])
    }

    @Test func killEscalatesToSIGKILLForAChildThatIgnoresSIGTERM() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let info = try await h.shell("trap '' TERM; echo READY; while :; do sleep 0.05; done")
        try await h.waitForScreen(info.id, toContain: "READY")

        h.server.killSession(info.id)
        try await eventually("the SIGKILL escalation", timeout: .seconds(15)) { callbacks.exited(info.id) }
    }

    @Test func killTakesTheWholeProcessGroup() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let pidFile = h.dir.appendingPathComponent("child.pid")
        let info = try await h.shell("sleep 100 & echo $! > \(pidFile.path); wait")
        try await eventually("the descendant to start") { FileManager.default.fileExists(atPath: pidFile.path) }
        let child = try pid(in: pidFile)

        h.server.killSession(info.id)
        try await eventually("the session to exit") { callbacks.exited(info.id) }
        try await eventually("the descendant to die") { !isRunning(child) }
    }

    /// Quitting the app ends everything, including descendants that ignore HUP and TERM.
    @Test func stopKillsEveryProcessGroupEvenStubbornOnes() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pidFile = h.dir.appendingPathComponent("child.pid")
        _ = try await h.shell("trap '' HUP TERM; (trap '' HUP TERM; sleep 100) & echo $! > \(pidFile.path); wait")
        try await eventually("the descendant to start") { FileManager.default.fileExists(atPath: pidFile.path) }
        let child = try pid(in: pidFile)

        h.server.stop()
        try await eventually("the descendant to die") { !isRunning(child) }
    }

    /// A leader that exits while a descendant still holds the PTY is reaped, and the
    /// descendant goes with it.
    @Test func anEarlyLeaderExitReapsDescendantsHoldingThePty() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let pidFile = h.dir.appendingPathComponent("child.pid")
        let info = try await h.shell("trap '' HUP TERM; sleep 100 & echo $! > \(pidFile.path); exit 0")
        try await eventually("the descendant to start") { FileManager.default.fileExists(atPath: pidFile.path) }
        let child = try pid(in: pidFile)

        try await eventually("the leader's exit") { callbacks.exited(info.id) }
        #expect(callbacks.exitCode(info.id) == .some(0))
        try await eventually("the descendant to die") { !isRunning(child) }
    }
}
