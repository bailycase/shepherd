import SwiftUI
import ShepherdUI
import ShepherdRemote

/// How the thread opens review: the changes card's Review, a changed file, an edit line. On
/// iPhone the changes push over the thread; on iPad they open in the side pane's Changes tab
/// beside it (it can go full screen from there).
@MainActor
enum ReviewHooks {
    static func open(thread: AgentRef, file: String?, navigator: MobileNavigator) {
        navigator.open(.review(.changes(thread, file: file)))
    }

    /// A changes card's Review, its file rows and the turn's edit lines: the review scoped to
    /// the turn the host recorded, at `file` when one is named.
    static func open(thread: AgentRef, turn: UUID, file: String? = nil, navigator: MobileNavigator) {
        ReviewStores.shared.store(for: thread).show(turn: turn)
        navigator.open(.review(.changes(thread, file: file)))
    }
}

/// The phone's review screens; on regular width the navigator shows changes and a diff in the side
/// pane's Changes tab instead (`SidePaneChanges`).
struct ReviewDestination: View {
    let route: ReviewRoute

    var body: some View {
        switch route {
        case .changes(let ref, let file):
            ChangesScreen(ref: ref, file: file)
        case .diff(let ref, let path):
            DiffScreen(ref: ref, path: path)
        case .commit(let ref):
            CommitScreen(ref: ref)
        case .branch(let ref):
            ThreadBranchSheet(ref: ref)
        }
    }
}
