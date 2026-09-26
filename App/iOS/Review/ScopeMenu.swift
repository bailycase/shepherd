import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// What to compare (ChangesStates › ScopeMenu; the phone's title, the iPad's Branch pill): Last
/// turn, the working tree (Uncommitted, Unstaged, Staged), then Commits, Branch and Pull request,
/// each with its diffstat; a scope the host can't compare says why and is off. Branch opens the
/// base picker from "Compare against…". An older host offers its two sides.
struct ChangesScopeMenu<Label: View>: View {
    let store: ReviewStore
    /// Opens the base picker.
    let pickBase: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            if store.usesChanges {
                changes
            } else {
                legacy
            }
        } label: {
            label()
        }
        .menuOrder(.fixed)
        .accessibilityHint("Chooses what to compare")
    }

    @ViewBuilder private var changes: some View {
        let options = store.scopeOptions
        if options.isEmpty {
            Text(store.loading ? "Loading scopes…" : "Scopes aren't available")
        }
        ForEach(groups(options), id: \.first?.id) { group in
            Section {
                ForEach(group) { option in item(option) }
            }
        }
    }

    @ViewBuilder private func item(_ option: ChangesScopeOption) -> some View {
        switch option.kind {
        case .commits where option.available && !store.commitOptions.isEmpty:
            Menu {
                ForEach(store.commitOptions) { commit in
                    Button { store.pick(commit.scope) } label: {
                        Text(commit.title)
                        if let detail = commit.detail { Text(detail) }
                        if commit.selected { Image(systemName: "checkmark") }
                    }
                }
            } label: {
                SwiftUI.Label(option.title, systemImage: "point.3.connected.trianglepath.dotted")
                if let trailing = option.trailing { Text(nativeCount(Int(trailing) ?? 0, "commit")) }
            }
        case .branch where option.available:
            Menu {
                Button { store.pick(option.scope) } label: {
                    Text(option.detail ?? option.title)
                    if let stat = statText(option) { Text(stat) }
                    if option.selected { Image(systemName: "checkmark") }
                }
                Button("Compare against…", systemImage: "arrow.triangle.branch", action: pickBase)
            } label: {
                SwiftUI.Label(option.title, systemImage: "arrow.triangle.branch")
                if let detail = option.detail { Text(detail) }
            }
        default:
            Button { store.pick(option.scope) } label: {
                SwiftUI.Label(option.title, systemImage: option.selected ? "checkmark" : symbol(option.kind))
                if let note = option.unavailable ?? subtitle(option) { Text(note) }
            }
            .disabled(!option.available)
        }
    }

    /// Last turn; the working tree; history: the board's three groups.
    private func groups(_ options: [ChangesScopeOption]) -> [[ChangesScopeOption]] {
        options.reduce(into: [[ChangesScopeOption]]()) { groups, option in
            if option.startsGroup || groups.isEmpty { groups.append([option]) } else { groups[groups.count - 1].append(option) }
        }
    }

    private func subtitle(_ option: ChangesScopeOption) -> String? {
        let parts = [option.kind == .lastTurn ? option.detail : nil, statText(option), option.trailing].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func statText(_ option: ChangesScopeOption) -> String? {
        guard let added = option.added, let removed = option.removed else { return nil }
        return "+\(added) \u{2212}\(removed)"
    }

    private func symbol(_ kind: ChangesScope.Kind) -> String {
        switch kind {
        case .lastTurn: "clock.arrow.circlepath"
        case .uncommitted, .unstaged, .staged: "pencil"
        case .commits: "point.3.connected.trianglepath.dotted"
        case .branch: "arrow.triangle.branch"
        case .pullRequest: "arrow.triangle.pull"
        }
    }

    @ViewBuilder private var legacy: some View {
        @Bindable var store = store
        Picker("Compare", selection: $store.pullRequest) {
            Text("Working tree vs HEAD").tag(false)
            Text("Pull request").tag(true)
        }
    }
}

/// The phone's title (MobileChanges): "Changes" over the scope, "⑂ Branch · vs main ⌄" in
/// `running`, which opens the scope menu.
struct ChangesTitle: View {
    let store: ReviewStore
    let pickBase: () -> Void

    var body: some View {
        ChangesScopeMenu(store: store, pickBase: pickBase) {
            VStack(spacing: NW.Space.xxs) {
                Text("Changes").font(.nw(.headline)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
                HStack(spacing: NW.Space.xs) {
                    Image(systemName: store.usesChanges ? scopeSymbol : "arrow.triangle.branch").imageScale(.small)
                    Text(store.scopeTitle).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").imageScale(.small)
                }
                .font(.nw(.caption, weight: .medium))
                .foregroundStyle(Color.nw.running)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Changes, \(store.scopeTitle)")
        }
    }

    private var scopeSymbol: String {
        switch store.scope?.kind {
        case .lastTurn?: "clock.arrow.circlepath"
        case .commits?: "point.3.connected.trianglepath.dotted"
        case .pullRequest?: "arrow.triangle.pull"
        case .uncommitted?, .unstaged?, .staged?: "pencil"
        default: "arrow.triangle.branch"
        }
    }
}

/// The base picker (ChangesStates › BasePicker): a search field, then "Compare against" with
/// the default base first (tagged "default"), recents, and every other branch by its last commit
/// (a branch checked out in another worktree tagged "worktree"); the one compared against now is
/// checked. Then the PR's base, when the checkout has a pull request.
struct ChangesBasePicker: View {
    let store: ReviewStore
    let done: () -> Void
    @State private var query = ""

    var body: some View {
        let nw = Color.nw
        NavigationStack {
            List {
                if let branches = store.branches {
                    Section {
                        ForEach(changesBaseOptions(branches, selected: store.base, query: query)) { option in
                            Button { choose(option.name) } label: { row(option) }
                                .listRowBackground(nw.bgRaised)
                                .listRowInsets(EdgeInsets(top: 0, leading: NW.Space.l, bottom: 0, trailing: NW.Space.l))
                        }
                    } header: {
                        Text("Compare against").nwSectionLabel()
                    }
                    if let base = branches.pullRequestBase, query.isEmpty {
                        Section {
                            Button { choose(base) } label: {
                                HStack(spacing: NW.Space.m) {
                                    Image(systemName: "arrow.triangle.pull").foregroundStyle(nw.textSecondary)
                                    Text("The PR's base").font(.nw(.ui)).foregroundStyle(nw.textPrimary)
                                    Spacer(minLength: NW.Space.s)
                                    Text(base).font(.nw(.mono)).foregroundStyle(nw.textTertiary)
                                }
                                .frame(minHeight: NW.Height.touch)
                            }
                            .listRowBackground(nw.bgRaised)
                        }
                    }
                } else if let error = store.branchesError {
                    NWEmptyState(Text("Couldn't list the branches"), message: error)
                        .listRowBackground(Color.clear)
                } else {
                    ProgressView().progressViewStyle(NWSpinnerStyle())
                        .frame(maxWidth: .infinity, minHeight: NW.Height.touch * 2)
                        .listRowBackground(Color.clear)
                        .accessibilityLabel("Loading the branches")
                }
            }
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, NW.Height.touch)
            .background(nw.bgBase)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search branches")
            .navigationTitle("Compare against")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
            }
        }
        .task { await store.loadBranches() }
    }

    private func row(_ option: ChangesBaseOption) -> some View {
        let nw = Color.nw
        return HStack(spacing: NW.Space.m) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(nw.textSecondary).accessibilityHidden(true)
            Text(option.name).font(.nw(.code)).foregroundStyle(nw.textPrimary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: NW.Space.s)
            if let tag = option.tag { Text(tag).font(.nw(.mono)).foregroundStyle(nw.textTertiary) }
            if option.selected {
                Image(systemName: "checkmark").font(.nw(.caption, weight: .semibold)).foregroundStyle(nw.textPrimary)
            }
        }
        .frame(minHeight: NW.Height.touch)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(option.selected ? .isSelected : [])
    }

    private func choose(_ base: String) {
        store.pickBase(base)
        done()
    }
}
