import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// The branch a new worktree starts from, chosen from this Mac's branches with the Changes pane's
/// base picker (ChangesBase): search, then the default base, recents and every branch by last
/// commit (`changesBaseOptions`, shared with the pane). Unlike a comparison, the checked-out
/// branch is a valid start. Shown from the New thread page's workplace menu and the New Worktree
/// sheet; a host's projects keep the base the host resolves. Its last row, always shown, makes the
/// picked branch the project's default base (`Space.worktreeBase`), or clears it. Turned on before
/// a branch is picked, it pins the branch picked next.
struct WorktreeBasePicker: View {
    let vm: ShepherdViewModel
    let space: SpaceID
    let repo: String
    /// The branch picked so far; nil while Settings ▸ Worktrees decides.
    let selected: String?
    let choose: (String) -> Void
    let close: () -> Void
    /// The project's default base changed (nil: cleared).
    let defaultChanged: (String?) -> Void
    @State private var branches: ChangesBranches?
    @State private var failure: String?
    @State private var query: String
    @FocusState private var searching: Bool
    /// "Default for this project" is on: picking a branch also pins it.
    @State private var pin: Bool

    init(vm: ShepherdViewModel, space: SpaceID, repo: String, selected: String?, query: String = "", choose: @escaping (String) -> Void,
         close: @escaping () -> Void, defaultChanged: @escaping (String?) -> Void = { _ in }) {
        self.vm = vm
        self.space = space
        self.repo = repo
        self.selected = selected
        self.choose = choose
        self.close = close
        self.defaultChanged = defaultChanged
        _query = State(initialValue: query)
        let projectBase = vm.state.spaces.first { $0.id == space }?.worktreeBase
        _pin = State(initialValue: projectBase != nil && projectBase == selected)
    }

    private func pick(_ branch: String) {
        if pin { setDefault(branch) }
        choose(branch)
    }

    private func setDefault(_ base: String?) {
        vm.setWorktreeBase(base, for: space)
        defaultChanged(base)
    }

    var body: some View {
        let options = branches.map { changesBaseOptions($0, selected: selected ?? "", query: query, includeCurrent: true) } ?? []
        SHChangesMenu(width: SHChangesMenuMetrics.baseWidth) {
            SHChangesMenuSearch(text: $query, prompt: "Search branches", isFocused: $searching,
                                onSubmit: { if let first = options.first { pick(first.name) } }, onEscape: close)
            SHChangesMenuTitle("Branch from")
            if branches != nil {
                ScrollView {
                    // A repository can list hundreds of branches (the engine stops at 500).
                    LazyVStack(spacing: 0) {
                        ForEach(options) { option in
                            SHChangesMenuRow(option.name, systemImage: SHChangesScopeGlyph.branch.systemImage, titleIsMono: true,
                                             trailing: option.tag.map { .text($0) } ?? .none, checked: option.selected) { pick(option.name) }
                        }
                    }
                }
                .frame(maxHeight: ChangesMenuLayout.listMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
                if options.isEmpty { SHChangesMenuNote("No branch matches “\(query)”.") }
            } else if let failure {
                SHChangesMenuNote(failure)
            } else {
                HStack(spacing: SH.Space.m) {
                    ProgressView().progressViewStyle(.shSpinner(size: AppLayout.reviewLoadingSpinner))
                    Text("Reading branches…").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
                .padding(.horizontal, SH.Space.m)
                .frame(height: SHChangesMenuMetrics.rowHeight)
            }
            SHChangesMenuDivider()
            SHChangesMenuToggle("Default for this project",
                                subtitle: selected == nil ? "The branch you pick becomes the default" : "New threads here start from this branch",
                                systemImage: SHGlyph.pin.symbolName, isOn: Binding(
                get: { pin },
                set: { on in
                    pin = on
                    if on, let selected { setDefault(selected) }
                    if !on, vm.state.spaces.first(where: { $0.id == space })?.worktreeBase != nil { setDefault(nil) }
                }))
        }
        .task {
            do { branches = try await vm.hostBranches(space: space) }
            catch { failure = (error as? ChangesError)?.message ?? "Couldn’t read this project’s branches." }
        }
    }
}
