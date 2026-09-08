import Darwin
import Dispatch
import Foundation
import Testing
import ShepherdCore
@testable import ShepherdSessions

// Serialized: these fork real PTY children, and running them alongside the
// other process-spawning suites made the child's first write occasionally not
// arrive within the timeout (the assertion saw no output at all).
@Suite("PTY session", .serialized)
struct PTYSessionTests {
    @Test func runsCommandStreamsOutputAndExits() async throws {
        let queue = DispatchQueue(label: "test.daemon")
        let output = Locked(Data())
        let exited = Locked<(done: Bool, code: Int32?)>((false, nil))

        let params = CreateSessionParams(
            cwd: "/",
            command: ["/bin/sh", "-c", "printf ready"],
            cols: 80,
            rows: 24
        )
        let session = try PTYSession(
            params: params,
            queue: DispatchQueue(label: "test.pty", target: queue)
        )
        session.onOutput = { chunk in output.withValue { $0.append(chunk) } }
        session.onExit = { code in exited.withValue { $0 = (true, code) } }
        session.start()

        let sawReady = try await waitUntil {
            output.current.range(of: Data("ready".utf8)) != nil
        }
        #expect(sawReady, "expected 'ready' in PTY output, got: \(String(decoding: output.current, as: UTF8.self))")

        let sawExit = try await waitUntil { exited.current.done }
        #expect(sawExit, "child never reported exit")
        #expect(exited.current.code == 0)

        queue.sync {
            #expect(!session.isAlive)
            // The screen retains the final state after exit; the rendered
            // text (not raw bytes) is what late attaches will see.
            let rendered = session.screen.visibleText().joined(separator: "\n")
            #expect(rendered.contains("ready"), "expected 'ready' on the session screen, got: \(rendered)")
        }
    }

    @Test func earlyLeaderExitReapsDescendantHoldingPTY() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pidURL = dir.appendingPathComponent("child.pid")
        let queue = DispatchQueue(label: "test.early-exit.pty")
        let exited = Locked<(done: Bool, code: Int32?)>((false, nil))
        let session = try PTYSession(
            params: CreateSessionParams(
                cwd: "/",
                command: [
                    "/bin/sh", "-c",
                    // Ignore HUP/TERM *before* forking: the disposition is inherited,
                    // so the kernel's leader-exit SIGHUP cannot race the trap.
                    "trap '' HUP TERM; sleep 100 & child=$!; echo $child > \(pidURL.path); exit 0",
                ]
            ),
            queue: queue
        )
        defer { queue.sync { session.shutdown() } }
        session.onExit = { code in exited.withValue { $0 = (true, code) } }

        let wrotePID = try await waitUntil(timeout: .seconds(5)) {
            FileManager.default.fileExists(atPath: pidURL.path)
        }
        #expect(wrotePID)
        let childPID = pid_t(Int32(try String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!)
        #expect(kill(childPID, 0) == 0)
        try await Task.sleep(for: .milliseconds(100))
        session.start()

        #expect(try await waitUntil(timeout: .seconds(5)) { exited.current.done })
        #expect(exited.current.code == 0)
        #expect(try await waitUntil(timeout: .seconds(5)) { kill(childPID, 0) != 0 })
        queue.sync { #expect(!session.isAlive) }
    }

    @Test func advertisesStableTrueColorCapabilities() async throws {
        let queue = DispatchQueue(label: "test.truecolor")
        let output = Locked(Data())
        let exited = Locked(false)
        let params = CreateSessionParams(
            cwd: "/",
            command: [
                "/bin/sh", "-c",
                "printf '%s|%s|%s|%s|%s' \"$TERM\" \"$COLORTERM\" \"$TERM_PROGRAM\" \"${GHOSTTY_RESOURCES_DIR-unset}\" \"${TMUX-unset}\"; sleep 0.2",
            ],
            env: [
                "TERM": "dumb",
                "COLORTERM": "false",
                "TERM_PROGRAM": "ghostty",
                "GHOSTTY_RESOURCES_DIR": "/tmp/stale-ghostty",
                "TMUX": "/tmp/stale-tmux",
            ]
        )
        let session = try PTYSession(
            params: params,
            queue: DispatchQueue(label: "test.truecolor.pty", target: queue)
        )
        session.onOutput = { chunk in output.withValue { $0.append(chunk) } }
        session.onExit = { _ in exited.withValue { $0 = true } }
        session.start()

        let expected = "xterm-256color|truecolor|Shepherd|unset|unset"
        let sawEnvironment = try await waitUntil {
            String(decoding: output.current, as: UTF8.self).contains(expected)
        }
        #expect(
            sawEnvironment,
            "expected \(expected), got: \(String(decoding: output.current, as: UTF8.self))"
        )
        try await waitUntil { exited.current }
    }

    @Test func backpressuredInputDoesNotBlockTheSessionQueue() async throws {
        let sessionQueue = DispatchQueue(label: "test.backpressure.pty")
        let session = try PTYSession(
            params: CreateSessionParams(cwd: "/", command: ["/bin/sh", "-c", "sleep 3"]),
            queue: sessionQueue
        )
        session.start()

        let completed = Locked(false)
        sessionQueue.async {
            session.writeInput(Data(repeating: 0x41, count: PTYSession.inputQueueLimit))
            completed.withValue { $0 = true }
        }

        #expect(try await waitUntil(timeout: .seconds(1)) { completed.current })
        sessionQueue.sync { session.shutdown() }
    }

    @Test func exitsWhileBackpressureSourceIsArmed() async throws {
        let queue = DispatchQueue(label: "test.backpressure-exit.pty")
        let exited = Locked<(done: Bool, code: Int32?)>((false, nil))
        let session = try PTYSession(
            params: CreateSessionParams(cwd: "/", command: ["/bin/sh", "-c", "sleep 0.3"]),
            queue: queue
        )
        defer { queue.sync { session.shutdown() } }
        session.onExit = { code in exited.withValue { $0 = (true, code) } }
        session.start()

        let writeFinished = Locked(false)
        queue.async {
            session.writeInput(Data(repeating: 0x41, count: PTYSession.inputQueueLimit))
            writeFinished.withValue { $0 = true }
        }

        #expect(try await waitUntil(timeout: .seconds(2)) { writeFinished.current })
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await waitUntil(timeout: .seconds(5)) { exited.current.done })
        #expect(exited.current.code == 0)
        queue.sync { #expect(!session.isAlive) }
    }

    @Test func delayedReaderReceivesQueuedInputInOrder() async throws {
        let sessionQueue = DispatchQueue(label: "test.delayed-reader.pty")
        let output = Locked(Data())
        let session = try PTYSession(
            params: CreateSessionParams(
                cwd: "/",
                command: ["/bin/sh", "-c", "stty raw -echo -opost; printf READY; sleep 0.4; cat"]
            ),
            queue: sessionQueue
        )
        session.onOutput = { data in output.withValue { $0.append(data) } }
        session.start()

        #expect(try await waitUntil(timeout: .seconds(2)) {
            output.current.range(of: Data("READY".utf8)) != nil
        })
        let payload: Data = {
            var data = Data()
            for index in 0..<8_192 {
                data.append(Data(String(format: "%08d:%023d\\n", index, index).utf8))
            }
            return data
        }()
        sessionQueue.async {
            session.writeInput(payload)
        }

        let expected = Data("READY".utf8) + payload
        let received = try await waitUntil(timeout: .seconds(10)) {
            output.current.count >= expected.count
        }
        #expect(received, "received \(output.current.count) output bytes: \(String(decoding: output.current.prefix(120), as: UTF8.self))")
        #expect(Data(output.current.prefix(expected.count)) == expected)
        sessionQueue.sync { session.shutdown() }
    }

    @Test func spawnFailsForMissingExecutable() {
        let params = CreateSessionParams(cwd: "/", command: ["/nonexistent/definitely-not-here"])
        #expect(throws: PTYSession.SpawnError.self) {
            _ = try PTYSession(params: params, queue: DispatchQueue(label: "test.pty2"))
        }
    }
}

