import Foundation
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdApp

/// Small builders shared by the suites in this target.
enum Fixture {
    /// A throwaway defaults suite — never `.standard`, which belongs to the running app.
    static func defaults() -> UserDefaults {
        let name = "shepherd.unit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func space(_ name: String, path: String? = nil, hidden: Bool = false) -> Space {
        Space(name: name, path: path ?? "/tmp/\(name)", hidden: hidden)
    }

    /// An agent with its own single-pane layout in `space`.
    static func agent(
        _ name: String,
        in space: Space,
        order: Int = 0,
        worktreeBranch: String? = nil
    ) -> (agent: Agent, tab: Tab) {
        let id = AgentID()
        let pane = LeafPane(cwd: space.path, agentID: id)
        let tab = Tab(spaceID: space.id, order: order, layout: .leaf(pane))
        let agent = Agent(id: id, name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id,
                          worktreeBranch: worktreeBranch)
        return (agent, tab)
    }

    static func child(_ id: String, state: String = "running", attention: Bool = false,
                      sessionFile: String? = nil) -> ChildRun {
        ChildRun(runID: id, label: id, state: state, needsAttention: attention, sessionFile: sessionFile)
    }

    static func diffFile(_ path: String, hunks: [DiffHunk] = []) -> DiffFile {
        DiffFile(oldPath: path, newPath: path, displayPath: path, isNew: false, isDeleted: false,
                 isRenamed: false, isBinary: false, hunks: hunks)
    }

    /// A scratch directory under the temporary directory, removed by the caller.
    static func scratchDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-unit-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
