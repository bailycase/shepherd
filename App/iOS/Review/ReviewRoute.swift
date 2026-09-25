import SwiftUI
import ShepherdUI

/// Review's screens (review track): an agent's changes, one file's diff, and Finalize.
enum ReviewRoute: Hashable, Codable {
    /// Working tree vs HEAD (or the PR): the file list, comments, Request changes and Commit;
    /// `file` picks one (the changes card's file, an edit line).
    case changes(AgentRef, file: String?)
    /// One file's diff.
    case diff(AgentRef, path: String)
    /// Finalize a worktree agent: commit, push, pull request, cleanup, run by its host. Presented.
    case finalize(AgentRef)
    /// Commit from review on iPhone (Commit/): the message, the files, push or a pull request,
    /// run by the host. Presented; on iPad it is a popover beside Commit….
    case commit(AgentRef)

    var thread: AgentRef {
        switch self {
        case .changes(let ref, _), .diff(let ref, _), .finalize(let ref), .commit(let ref): ref
        }
    }
}

/// How the thread opens review: the changes card's Review, a changed file, an edit line. On
/// iPhone the changes push over the thread; on iPad the review docks beside it (it can go full
/// screen from there).
@MainActor
enum ReviewHooks {
    static func open(thread: AgentRef, file: String?, navigator: MobileNavigator) {
        navigator.open(.review(.changes(thread, file: file)))
    }
}

struct ReviewDestination: View {
    let route: ReviewRoute
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        switch route {
        case .changes(let ref, let file):
            if sizeClass == .regular {
                PadReviewScreen(ref: ref, file: file)
            } else {
                ChangesScreen(ref: ref, file: file)
            }
        case .diff(let ref, let path):
            if sizeClass == .regular {
                PadReviewScreen(ref: ref, file: path)
            } else {
                DiffScreen(ref: ref, path: path)
            }
        case .finalize(let ref):
            FinalizeScreen(ref: ref)
        case .commit(let ref):
            CommitScreen(ref: ref)
        }
    }
}
