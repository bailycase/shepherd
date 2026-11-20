import Foundation
import ShepherdCore
import ShepherdProtocol

extension FixtureCatalog {
    /// A stopped agent's Can't start banner above the composer: Retry for a pi that stopped, Start new conversation beside it for a
    /// conversation pi couldn't find, only guidance for a folder that is gone, and no button on a host that can't restart pi.
    static var startProblems: [FixtureScreen] {
        let thread = FixtureData.ref(FixtureData.preview)
        func screen(_ name: String, _ problem: NativeStartProblem, restart: Bool = true) -> FixtureScreen {
            var hosts = ThreadFixtures.hosts()
            // A stopped thread's snapshot is its conversation read from pi's session file, with the problem.
            hosts[0].threads[FixtureData.preview]?.preview = true
            hosts[0].threads[FixtureData.preview]?.startProblem = problem
            if !restart { hosts[0].capabilities = hosts[0].defaultCapabilities.filter { $0 != RemoteProtocol.agentRestartCapability } }
            return FixtureScreen(name: name, hosts: hosts, routes: [.thread(thread)])
        }
        return [
            screen("start-problem-stopped", NativeStartProblem(kind: .stopped, signal: 9, lines: ["FATAL ERROR: Reached heap limit Allocation failed"])),
            screen("start-problem-new-conversation", NativeStartProblem(kind: .resumedAsNew)),
            screen("start-problem-folder-missing", NativeStartProblem(kind: .folderMissing)),
            screen("start-problem-old-host", NativeStartProblem(kind: .stopped, signal: 9), restart: false),
        ]
    }
}
