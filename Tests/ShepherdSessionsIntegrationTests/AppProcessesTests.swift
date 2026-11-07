import Darwin
import Foundation
import ShepherdCore
import ShepherdTestSupport
import Testing
@testable import ShepherdSessions

/// The apps Shepherd runs in the background (`AppProcesses`): real processes in their own groups.
/// Output is captured, Stop ends the whole group (a child the command spawned too), an exit is
/// seen with its code, two spaces' apps of one name stay apart, and quitting stops every app.
@Suite("App processes", .integrationTimeLimit)
struct AppProcessesTests {
    private let space = AppScope.space(SpaceID())

    private func snapshot(_ apps: AppProcesses, _ key: AppKey) async -> AppProcessSnapshot? {
        await apps.snapshots()[key]
    }

    /// The pid a command printed as "child <pid>".
    private func child(_ apps: AppProcesses, _ key: AppKey) async throws -> pid_t {
        var found: pid_t?
        try await eventually("the command to print its child") {
            found = await apps.lines(key, tail: 50).lazy.compactMap { line in
                line.hasPrefix("child ") ? pid_t(line.dropFirst(6)) : nil
            }.first
            return found != nil
        }
        return try #require(found)
    }

    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    @Test func runCapturesOutputAndStopEndsTheWholeGroup() async throws {
        let dir = try makeScratchDirectory("apps")
        let apps = AppProcesses(grace: 0.5)
        let key = AppKey(scope: space, name: "Web app")
        // The child ignores SIGTERM: only the SIGKILL after the grace period ends it.
        let command = "/bin/bash -c 'trap \"\" TERM; while :; do sleep 1; done' & echo \"child $!\"; pwd; echo 'ready on http://localhost:4321'; wait"
        apps.start(key, command: command, directory: dir.path)
        let pid = try await child(apps, key)
        #expect(alive(pid))
        try await eventually("the app to read as running, on its port") {
            let state = await snapshot(apps, key)
            return state?.status == .running && state?.port == 4321
        }
        let lines = await apps.lines(key, tail: 50)
        #expect(lines.contains { $0.hasSuffix(dir.lastPathComponent) }, "it runs in its folder: \(lines)")
        #expect(lines.contains("ready on http://localhost:4321"))

        apps.stop(key)
        try await eventually("the app to end") {
            if case .exited? = await snapshot(apps, key)?.status { return true }
            return false
        }
        try await eventually("the child that ignored SIGTERM to end too") { !alive(pid) }
    }

    @Test func anExitIsSeenWithItsCode() async throws {
        let dir = try makeScratchDirectory("apps")
        let apps = AppProcesses()
        let key = AppKey(scope: .mac, name: "Worker")
        apps.start(key, command: "echo bye; exit 3", directory: dir.path)
        try await eventually("the app to exit") { await snapshot(apps, key)?.status == .exited(3) }
        #expect(await apps.lines(key, tail: 10).contains("bye"))
        // It starts again.
        apps.start(key, command: "sleep 30", directory: dir.path)
        try await eventually("it to run again") { await snapshot(apps, key)?.status.isLive == true }
        apps.stop(key)
        try await eventually("it to stop") { await snapshot(apps, key)?.status.isLive == false }
    }

    @Test func aFolderThatIsGoneFailsToStart() async throws {
        let apps = AppProcesses()
        let key = AppKey(scope: .mac, name: "Worker")
        apps.start(key, command: "true", directory: "/nonexistent/acme-web")
        try await eventually("the failure") {
            if case .failed(let why)? = await snapshot(apps, key)?.status { return why.contains("doesn’t exist") }
            return false
        }
    }

    @Test func twoSpacesAppsOfOneNameStayApart() async throws {
        let dir = try makeScratchDirectory("apps")
        let apps = AppProcesses(grace: 0.5)
        let payments = AppKey(scope: .space(SpaceID()), name: "Web app")
        let ledger = AppKey(scope: .space(SpaceID()), name: "Web app")
        apps.start(payments, command: "echo payments; sleep 30", directory: dir.path)
        apps.start(ledger, command: "echo ledger; sleep 30", directory: dir.path)
        try await eventually("both to print") {
            let (p, l) = (await apps.lines(payments, tail: 5), await apps.lines(ledger, tail: 5))
            return p == ["payments"] && l == ["ledger"]
        }
        apps.stop(payments)
        try await eventually("payments to stop") { await snapshot(apps, payments)?.status.isLive == false }
        #expect(await snapshot(apps, ledger)?.status.isLive == true, "stopping one space's app leaves the other's")
        apps.stop(ledger)
    }

    @Test func quittingStopsEveryAppAndRunsNoMore() async throws {
        let dir = try makeScratchDirectory("apps")
        let apps = AppProcesses()
        let one = AppKey(scope: .mac, name: "One"), two = AppKey(scope: space, name: "Two")
        apps.start(one, command: "sleep 300 & echo \"child $!\"; wait", directory: dir.path)
        apps.start(two, command: "sleep 300 & echo \"child $!\"; wait", directory: dir.path)
        let first = try await child(apps, one), second = try await child(apps, two)
        apps.stopAll(grace: 0.5)
        #expect(!alive(first) && !alive(second))
        apps.start(one, command: "sleep 300", directory: dir.path)
        try await eventually("a start after quitting to be refused") {
            if case .failed? = await snapshot(apps, one)?.status { return true }
            return false
        }
    }

    @Test func outputIsPlainAndNamesItsPort() {
        #expect(AppProcesses.stripANSI("\u{1B}[32m✓\u{1B}[0m Ready in \u{1B}[1m1.2s\u{1B}[22m") == "✓ Ready in 1.2s")
        #expect(AppProcesses.port(in: "  - Local:   http://localhost:3000") == 3000)
        #expect(AppProcesses.port(in: "Listening on port 8080") == 8080)
        #expect(AppProcesses.port(in: "compiled 42 modules") == nil)
    }
}
