import SwiftUI
import ShepherdUI

/// Review's screens (review track): an agent's changes and the diff of one file.
enum ReviewRoute: Hashable, Codable {
    /// Working tree vs HEAD: the file list, comments, Request changes; `file` scrolls to one.
    case changes(AgentRef, file: String?)
    /// One file's diff.
    case diff(AgentRef, path: String)

    var thread: AgentRef {
        switch self {
        case .changes(let ref, _), .diff(let ref, _): ref
        }
    }
}

/// How the thread opens review: the changes card's Review, a changed file, an edit line. The
/// review track decides where it shows (pushed on iPhone, docked beside the thread on iPad).
@MainActor
enum ReviewHooks {
    static func open(thread: AgentRef, file: String?, navigator: MobileNavigator) {
        navigator.open(.review(.changes(thread, file: file)))
    }
}

struct ReviewDestination: View {
    let route: ReviewRoute

    var body: some View {
        switch route {
        case .changes(_, let file):
            NWEmptyState(Text("Changes"), message: file.map { "Review opens at \($0)." } ?? "The agent's changes appear here.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.nw.bgWindow)
                .navigationTitle("Changes")
                .navigationBarTitleDisplayMode(.inline)
        case .diff(_, let path):
            NWEmptyState(Text(path).font(.nw(.mono)), message: "This file's diff appears here.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.nw.bgWindow)
                .navigationTitle((path as NSString).lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}
