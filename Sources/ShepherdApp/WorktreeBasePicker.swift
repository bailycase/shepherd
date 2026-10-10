import SwiftUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// The branch a new worktree starts from, chosen from this Mac's branches with the Changes pane's
/// base picker (ChangesBase): search, then the default base, recents and every branch by last
/// commit (`changesBaseOptions`, shared with the pane). Unlike a comparison, the checked-out
/// branch is a valid start. Shown from the New thread page's workplace menu and the New Worktree
/// sheet; a host's projects keep the base the host resolves.
struct WorktreeBasePicker: View {
    let vm: ShepherdViewModel
    let repo: String
    /// The branch picked so far; nil while Settings ▸ Worktrees decides.
    let selected: String?
    let choose: (String) -> Void
    let close: () -> Void
    @State private var branches: ChangesBranches?
    @State private var failure: String?
    @State private var query: String
    @FocusState private var searching: Bool

    init(vm: ShepherdViewModel, repo: String, selected: String?, query: String = "", choose: @escaping (String) -> Void,
         close: @escaping () -> Void) {
        self.vm = vm
        self.repo = repo
        self.selected = selected
        self.choose = choose
        self.close = close
        _query = State(initialValue: query)
    }

    var body: some View {
        let options = branches.map { changesBaseOptions($0, selected: selected ?? "", query: query, includeCurrent: true) } ?? []
        NWChangesMenu(width: NWChangesMenuMetrics.baseWidth) {
            NWChangesMenuSearch(text: $query, prompt: "Search branches", isFocused: $searching,
                                onSubmit: { if let first = options.first { choose(first.name) } }, onEscape: close)
            NWChangesMenuTitle("Branch from")
            if branches != nil {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(options) { option in
                            NWChangesMenuRow(option.name, systemImage: NWChangesScopeGlyph.branch.systemImage, titleIsMono: true,
                                             trailing: option.tag.map { .text($0) } ?? .none, checked: option.selected) { choose(option.name) }
                        }
                    }
                }
                .frame(maxHeight: ChangesMenuLayout.listMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
                if options.isEmpty { NWChangesMenuNote("No branch matches “\(query)”.") }
            } else if let failure {
                NWChangesMenuNote(failure)
            } else {
                HStack(spacing: NW.Space.m) {
                    ProgressView().progressViewStyle(.nwSpinner(size: AppLayout.reviewLoadingSpinner))
                    Text("Reading branches…").font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                }
                .padding(.horizontal, NW.Space.m)
                .frame(height: NWChangesMenuMetrics.rowHeight)
            }
        }
        .task {
            do { branches = try await vm.server.changes.branches(agentID: nil, cwd: (repo as NSString).expandingTildeInPath) }
            catch { failure = (error as? ChangesError)?.message ?? "Couldn’t read this project’s branches." }
        }
    }
}
