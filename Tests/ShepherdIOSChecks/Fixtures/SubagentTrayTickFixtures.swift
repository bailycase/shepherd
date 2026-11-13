import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// "subagent-tray-ticks": a running thread whose worker changes its words at every poll, as a
/// subagent does with each tool call. The tray's rows follow the call; the composer around the tray
/// only decides whether the tray is docked, so it must not run its body for them
/// (`NativeThreadStore.hasTray`, as the Mac's composer reads it).
///
/// The fixture serves `ticks` snapshots, each with the worker on another call, and after each waits
/// until the tray section has drawn it. It then checks the composer's body ran at most `composerLimit`
/// times over all of them, where a composer that reads the whole tray runs it once per tick.
enum SubagentTrayTicks {
    static let ticks = 20
    /// Runs of the composer's body the ticks may cost together: a layout pass for something else.
    static let composerLimit = 2

    /// The step the host serves.
    private final class Stage: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        private let base = SubagentFixtures.liveThread()

        func advance() { lock.withLock { value += 1 } }
        var snapshot: NativeThreadSnapshot { thread(step: lock.withLock { value }) }

        /// The base thread with the worker on its `step`th call; the other runs do not move.
        func thread(step: Int) -> NativeThreadSnapshot {
            var snapshot = base
            snapshot.revision = UInt64(step + 2)
            snapshot.subagents = base.subagents?.map { run in
                guard run.runID == SubagentFixtures.worker else { return run }
                var run = run
                run.toolCalls = (run.toolCalls ?? 0) + step
                run.lastActivity = ChildActivity(tool: step.isMultiple(of: 2) ? "read" : "edit", preview: "Sources/Tick\(step).swift",
                                                 at: SubagentFixtures.now + Double(step))
                return run
            }
            return snapshot
        }
    }

    private static let stage = Stage()

    static func hosts() -> [FixtureHostData] {
        var hosts = SubagentFixtures.hosts()
        guard let index = hosts.firstIndex(where: { $0.id == FixtureData.studio }) else { return hosts }
        let fallback = hosts[index].reply
        hosts[index].reply = { request in
            guard case .nativeThread(let id, SubagentFixtures.restyle, .snapshot(_, _, let after)) = request else { return fallback?(request) }
            let snapshot = stage.snapshot
            if after == snapshot.revision {
                return .nativeThread(id: id, result: .unchanged(piSessionID: snapshot.piSessionID, generation: snapshot.generation,
                                                                revision: snapshot.revision))
            }
            return .nativeThread(id: id, result: .snapshot(value: snapshot))
        }
        return hosts
    }

    /// What the worker's tray row says at each step, as the store derives it from the snapshot.
    private static func lines() -> [NativeTrayRow.Line?] {
        (0...ticks).map { step in
            stage.thread(step: step).subagents?.first { $0.runID == SubagentFixtures.worker }.map { run in
                let now = nativeRunNow(run)
                return .working(verb: now.verb, subject: now.subject, live: now.live)
            }
        }
    }

    @MainActor static func run(_ app: MobileApp) async {
        let store = app.threads.store(for: FixtureData.ref(SubagentFixtures.restyle))
        func worker() -> NativeTrayRow.Line? { store.tray?.rows.first { $0.runID == SubagentFixtures.worker }?.line }
        let expected = lines()
        SHRenderProbe.start()
        await FixtureWindows.wait("the tray to dock", seconds: 20) { worker() != nil && SHRenderProbe.count("composer.tray") > 0 }
        await settle()
        SHRenderProbe.start()
        for tick in 1...ticks {
            let drawn = SHRenderProbe.count("composer.tray")
            stage.advance()
            await FixtureWindows.wait("tick \(tick) to reach the tray", seconds: 20) {
                worker() == expected[tick] && SHRenderProbe.count("composer.tray") > drawn
            }
        }
        await settle()
        let counts = SHRenderProbe.stop()
        let composer = counts["composer.body", default: 0]
        let tray = counts["composer.tray", default: 0]
        FixtureCheck.report("FIXTURE CHECK ok: \(ticks) ticks: the composer's body ran \(composer) times, the tray section \(tray)")
        if composer > composerLimit {
            FixtureCheck.report("FIXTURE CHECK FAILED: the composer's body ran \(composer) times over \(ticks) subagent ticks (at most \(composerLimit)): it reads the tray's rows")
        }
        FixtureCheck.report("FIXTURE CHECK ok: the composer's body ran at most \(composerLimit) times over \(ticks) ticks")
    }

    /// Waits until the composer and the tray draw nothing for 500 ms, at most 5 s.
    @MainActor private static func settle() async {
        func drawn() -> Int { SHRenderProbe.count("composer.body") + SHRenderProbe.count("composer.tray") }
        let clock = ContinuousClock()
        let started = clock.now
        var last = drawn()
        var quietSince = started
        while clock.now - started < .seconds(5), clock.now - quietSince < .milliseconds(500) {
            try? await Task.sleep(for: .milliseconds(50))
            if drawn() != last {
                last = drawn()
                quietSince = clock.now
            }
        }
    }
}
