import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

extension FixtureCatalog {
    /// A stopped agent's Can't start banner above the composer: Retry for a pi that stopped, Start new conversation beside it for a
    /// conversation pi couldn't find, only guidance for a folder that is gone or a pi that isn't signed in, and no button on a host
    /// that can't restart pi. A Retry under way, and a host's refusal, are the store's `startRestart`.
    static var startProblems: [FixtureScreen] {
        let thread = FixtureData.ref(FixtureData.preview)
        func screen(_ name: String, _ problem: NativeStartProblem, restart: Bool = true,
                    prepare: (@MainActor (MobileApp, NativeThreadStore) -> Void)? = nil) -> FixtureScreen {
            var hosts = ThreadFixtures.hosts()
            // A stopped thread's snapshot is its conversation read from pi's session file, with the problem.
            hosts[0].threads[FixtureData.preview]?.preview = true
            hosts[0].threads[FixtureData.preview]?.startProblem = problem
            if !restart { hosts[0].capabilities = hosts[0].defaultCapabilities.filter { $0 != RemoteProtocol.agentRestartCapability } }
            var screen = FixtureScreen(name: name, hosts: hosts, routes: [.thread(thread)])
            if let prepare {
                screen.prepare = { app in
                    let store = app.threads.store(for: thread)
                    await FixtureWindows.wait("the stopped thread's problem", seconds: 10) { store.startProblem != nil }
                    prepare(app, store)
                }
            }
            return screen
        }
        return [
            screen("start-problem-stopped", NativeStartProblem(kind: .stopped, signal: 9, lines: ["FATAL ERROR: Reached heap limit Allocation failed"])),
            screen("start-problem-new-conversation", NativeStartProblem(kind: .resumedAsNew)),
            screen("start-problem-folder-missing", NativeStartProblem(kind: .folderMissing)),
            screen("start-problem-old-host", NativeStartProblem(kind: .stopped, signal: 9), restart: false),
            screen("start-problem-not-signed-in", NativeStartProblem(kind: .notSignedIn)),
            screen("start-problem-restarting", NativeStartProblem(kind: .stopped, signal: 9)) { _, store in store.restartRequested() },
            screen("start-problem-refused", NativeStartProblem(kind: .stopped, signal: 9)) { _, store in
                store.restartRefused("Couldn’t start the agent: The host refused the restart.")
            },
        ]
    }
}
