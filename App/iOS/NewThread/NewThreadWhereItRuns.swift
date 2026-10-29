import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

extension MobileLayout {
    /// New thread's prompt (the boards' 18pt).
    static let newThreadPromptSize: CGFloat = 18
    /// An attached image's thumbnail.
    static let newThreadThumbnail: CGFloat = 56
    /// The iPad's repo, host, worktree and model popovers.
    static let newThreadPopoverWidth: CGFloat = 380
    static let newThreadPopoverMaxWidth: CGFloat = 640
    static let newThreadPopoverHeight: CGFloat = 460
    /// The iPad's prompt keeps room for this many lines before the chips.
    static let newThreadPadPromptLines = 6
}

/// Where it runs (MobileWorkspace board): the repo, the host and the New worktree switch, in
/// one sheet on iPhone. The repo is one row that pushes its searchable list, so the host and the
/// worktree stay in view however many repos the host has; the base pushes the branch list.
struct NewThreadWhereItRuns: View {
    @Bindable var model: NewThreadModel

    var body: some View {
        NavigationStack(path: $model.workspacePath) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: SH.Space.xxl) {
                        NewThreadSection("Repo") { SHGroupCard { NewThreadRepoSummary(model: model) } }
                        NewThreadSection("Host") { NewThreadHostList(model: model, carded: true) }
                        NewThreadWorktreeCard(model: model).id(NewThreadModel.Panel.worktree)
                    }
                    .padding(.horizontal, MobileLayout.gutter)
                    .padding(.vertical, SH.Space.xl)
                }
                .onAppear {
                    if model.workspaceAnchor == .worktree { proxy.scrollTo(NewThreadModel.Panel.worktree, anchor: .bottom) }
                }
            }
            .background(Color.sh.bgWindow)
            .navigationTitle("Where it runs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A symbol, so iPhone Duo's closed display puts it in its column with the sheet's bars.
                ToolbarItem(placement: .confirmationAction) {
                    Button { model.panel = nil } label: { Label("Done", systemImage: "checkmark") }
                }
            }
            .newThreadPages(model)
        }
        .shAnimation(.disclosure, value: model.usesWorktree)
    }
}

extension View {
    /// The pages Where it runs and the iPad's worktree popover push: the repo list (with Add
    /// repo's folders) and the base branches.
    func newThreadPages(_ model: NewThreadModel) -> some View {
        @Bindable var model = model
        return navigationDestination(for: NewThreadModel.Panel.self) { page in
            switch page {
            case .repo: NewThreadRepoPage(model: model)
            case .branches: NewThreadBranchPicker(model: model)
            default: EmptyView()
            }
        }
        .navigationDestination(item: $model.folders) { browser in
            NewThreadFolderScreen(model: model, browser: browser)
        }
    }
}

/// The chosen repo, as one row that pushes the list.
private struct NewThreadRepoSummary: View {
    let model: NewThreadModel

    var body: some View {
        let path = model.space.map { NewThreadRules.abbreviatedPath($0.path) }
        NavigationLink(value: NewThreadModel.Panel.repo) {
            SHChoiceRow(model.space?.name ?? "Choose repo", detail: path ?? model.host.map { "a repo on \($0.name)" }) {
                Image(systemName: "book.closed")
                    .font(.sh(.ui))
                    .foregroundStyle(Color.sh.textSecondary)
            } trailing: {
                NewThreadDisclosure()
            }
        }
        .buttonStyle(.shRow(selected: false, radius: 0))
        .accessibilityHint("Shows every repo")
    }
}

/// A pushed row's trailing chevron.
struct NewThreadDisclosure: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.sh(.caption, weight: .semibold))
            .foregroundStyle(Color.sh.textTertiary)
            .accessibilityHidden(true)
    }
}

/// Every repo, searchable, and Add repo; choosing one goes back.
private struct NewThreadRepoPage: View {
    let model: NewThreadModel
    @FocusState private var searching: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SH.Space.l) {
                SHTouchSearchField("Search repos", text: Binding(get: { model.repoQuery }, set: { model.setRepoQuery($0) }), focus: $searching)
                NewThreadRepoList(model: model, carded: true) {
                    if !model.workspacePath.isEmpty { model.workspacePath.removeLast() }
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.vertical, SH.Space.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.sh.bgWindow)
        .navigationTitle("Repo")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.setRepoQuery("") }
    }
}

/// The worktree's base (WorktreeBasePicker on the Mac): search, then "Branch from" with the
/// default base, recents and every branch by last commit, tagged "default" or "worktree"
/// (`changesBaseOptions`). Choosing one goes back.
struct NewThreadBranchPicker: View {
    let model: NewThreadModel
    @FocusState private var searching: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SH.Space.l) {
                SHTouchSearchField("Search branches", text: Binding(get: { model.branchQuery }, set: { model.setBranchQuery($0) }),
                                   focus: $searching)
                if model.branches != nil {
                    NewThreadSection("Branch from") {
                        // A repository can list hundreds of branches (the engine stops at 500).
                        LazyVStack(spacing: 0) {
                            ForEach(model.branchOptions) { option in
                                VStack(spacing: 0) {
                                    if option.id != model.branchOptions.first?.id { SHHairline() }
                                    row(option)
                                }
                            }
                        }
                        .shCard()
                    }
                    if model.branchOptions.isEmpty {
                        note(model.branchQuery.isEmpty ? "This repo has no branches yet." : "No branch matches “\(model.branchQuery)”.")
                    }
                } else if let error = model.branchesError {
                    SHBanner(.failed, title: "Couldn't read the branches", message: error) {
                        Button("Try again") { model.loadBranches() }.buttonStyle(.sh(.secondary, size: .s))
                    }
                } else {
                    HStack(spacing: SH.Space.m) {
                        ProgressView().progressViewStyle(.shSpinner)
                        note("Reading branches on \(model.host?.name ?? "the host")…")
                    }
                    .frame(maxWidth: .infinity, minHeight: MobileLayout.rowHeight)
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.vertical, SH.Space.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.sh.bgWindow)
        .navigationTitle("Base")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.loadBranches() }
        .onDisappear { model.setBranchQuery("") }
    }

    private func row(_ option: ChangesBaseOption) -> some View {
        Button {
            model.setBase(option.name)
            if !model.workspacePath.isEmpty { model.workspacePath.removeLast() }
        } label: {
            SHChoiceRow(option.name, selected: option.selected) {
                Image(systemName: SHGlyph.gitBranch.symbolName)
                    .font(.sh(.ui))
                    .foregroundStyle(Color.sh.textSecondary)
            } trailing: {
                if let tag = option.tag { SHTag(tag) }
            }
        }
        .buttonStyle(.shRow(selected: false, radius: 0))
        .accessibilityHint(option.selected ? "" : "Branches from \(option.name)")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .shText(.caption)
            .foregroundStyle(Color.sh.textTertiary)
            .padding(.horizontal, SH.Space.s)
    }
}

/// A titled block of Where it runs.
struct NewThreadSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            Text(title)
                .font(.sh(.ui))
                .foregroundStyle(Color.sh.textSecondary)
                .padding(.horizontal, SH.Space.s)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

/// Rows with a hairline between them: in a card (the phone's sheet) or bare (inside an iPad
/// popover, which is the card).
struct NewThreadRowStack<Content: View>: View {
    let carded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if carded {
            SHGroupCard(content: content)
        } else {
            VStack(spacing: 0) {
                Group(subviews: content()) { subviews in
                    ForEach(subviews) { subview in
                        if subview.id != subviews.first?.id { SHHairline() }
                        subview
                    }
                }
            }
        }
    }
}

/// The chosen host's repos, then the other connected hosts', and Add repo.
struct NewThreadRepoList: View {
    let model: NewThreadModel
    let carded: Bool
    var chosen: () -> Void = {}

    var body: some View {
        let connected = model.host?.phase.isConnected == true
        NewThreadRowStack(carded: carded) {
            ForEach(model.repoMatches) { row in
                Button {
                    model.choose(repo: row.id)
                    chosen()
                } label: {
                    SHChoiceRow(row.name, detail: row.detail, selected: row.selected) {
                        Image(systemName: "book.closed")
                            .font(.sh(.ui))
                            .foregroundStyle(Color.sh.textSecondary)
                    }
                }
                .buttonStyle(.shRow(selected: false, radius: 0))
                .accessibilityHint(row.selected ? "" : "Runs the thread in \(row.name)")
            }
            if model.repoMatches.isEmpty {
                Text(!model.repoQuery.isEmpty ? "No repo matches “\(model.repoQuery)”."
                     : model.host.map { "No repos on \($0.name) yet." } ?? "Choose a host first.")
                    .shText(.caption)
                    .foregroundStyle(Color.sh.textTertiary)
                    .padding(.horizontal, SH.Space.xl)
                    .frame(maxWidth: .infinity, minHeight: MobileLayout.rowHeight, alignment: .leading)
            }
            Button { model.browseFolders() } label: {
                SHChoiceRow("Add repo…", detail: model.host.map { "a folder on \($0.name)" }, mono: false) {
                    Image(systemName: "plus")
                        .font(.sh(.ui))
                        .foregroundStyle(Color.sh.running)
                }
            }
            .buttonStyle(.shRow(selected: false, radius: 0))
            .disabled(!connected)
        }
    }
}

/// Every host with its status: a connected one can be chosen, an offline one offers Retry, and
/// one on an older Shepherd says what it cannot do.
struct NewThreadHostList: View {
    let model: NewThreadModel
    let carded: Bool

    var body: some View {
        NewThreadRowStack(carded: carded) {
            ForEach(model.hostRows) { row in
                if row.selectable {
                    Button { model.choose(host: row.id) } label: { label(row) }
                        .buttonStyle(.shRow(selected: false, radius: 0))
                } else {
                    label(row)
                }
            }
        }
    }

    private func label(_ row: NewThreadHostRow) -> some View {
        SHChoiceRow(row.name, detail: row.detail, note: row.limitation, selected: row.selected, dimmed: !row.selectable) {
            SHStatusDot(row.status.agentState, size: SHChoiceRowMetrics.statusDot)
        } trailing: {
            if row.offersRetry {
                Button("Retry") { model.retry(host: row.id) }
                    .buttonStyle(.shLink)
                    .shTouchTarget(height: SH.Height.controlS)
                    .accessibilityLabel("Retry \(row.name)")
            }
        }
    }
}

extension NewThreadHostRow.Status {
    var agentState: AgentState {
        switch self {
        case .connected: .done
        case .connecting: .running
        case .offline: .failed
        }
    }
}

/// The New worktree switch, and with it on, the branch, its base as the host resolved it, and
/// whether to fetch first (the Mac sheet's worktree rows).
struct NewThreadWorktreeCard: View {
    let model: NewThreadModel

    var body: some View {
        let supported = model.host?.supportsWorktrees ?? true
        let on = model.usesWorktree
        SHGroupCard {
            SHCardRow("New worktree", description: NewThreadRules.worktreeCaption(base: model.base.base),
                      problem: supported ? nil : model.host.map { "Update Shepherd on \($0.name) to start threads in a new worktree." }) {
                Toggle("New worktree", isOn: Binding(get: { on }, set: { model.setWorktree($0) }))
                    .toggleStyle(.shSwitch)
                    .labelsHidden()
                    .shTouchTarget(height: SH.Height.controlS, width: SH.Height.controlL)
                    .disabled(!supported)
            }
            if on {
                field("New branch", text: Binding(get: { model.branch }, set: { model.setBranch($0) }), prompt: "branch name")
                if model.offersBranchList {
                    // The base is one of the repo's branches, chosen as on the Mac.
                    NavigationLink(value: NewThreadModel.Panel.branches) {
                        SHCardRow("Base", description: baseNote) {
                            HStack(spacing: SH.Space.s) {
                                Text(model.base.base.isEmpty ? "Choose" : model.base.base)
                                    .font(.sh(.code))
                                    .foregroundStyle(model.base.base.isEmpty ? Color.sh.textTertiary : Color.sh.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                NewThreadDisclosure()
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.shRow(selected: false, radius: 0))
                    .accessibilityLabel("Base, \(model.base.base)")
                    .accessibilityHint("Shows the repo's branches")
                } else {
                    VStack(alignment: .leading, spacing: SH.Space.xs) {
                        field("Base", text: Binding(get: { model.base.base }, set: { model.setBase($0) }), prompt: "base branch")
                        if let baseNote {
                            Text(baseNote)
                                .shText(.caption)
                                .foregroundStyle(Color.sh.textTertiary)
                                .shContentTransition(.crossFade)
                                .padding(.horizontal, SH.Space.xl)
                                .padding(.bottom, SH.Space.m)
                        }
                    }
                }
                SHCardRow("Fetch origin first", description: "Resolves the base again after a fetch.") {
                    Toggle("Fetch origin first", isOn: Binding(get: { model.base.fetchFirst }, set: { model.setFetchFirst($0) }))
                        .toggleStyle(.shSwitch)
                        .labelsHidden()
                        .shTouchTarget(height: SH.Height.controlS, width: SH.Height.controlL)
                        .disabled(model.base.resolving)
                }
            }
        }
    }

    /// What the host said of the base ("origin fetched just now"), or that it is resolving it.
    private var baseNote: String? {
        if model.base.resolving { return "Resolving on \(model.host?.name ?? "the host")…" }
        return model.base.note.isEmpty ? nil : model.base.note
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: SH.Space.l) {
            Text(label)
                .font(.sh(.ui))
                .foregroundStyle(Color.sh.textPrimary)
                .accessibilityHidden(true)
            TextField(label, text: text, prompt: Text(prompt).foregroundStyle(Color.sh.textTertiary))
                .font(.sh(.code))
                .foregroundStyle(Color.sh.textPrimary)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(label)
        }
        .padding(.horizontal, SH.Space.xl)
        .frame(minHeight: MobileLayout.rowHeight)
    }
}

/// The model picker: on iPhone the thinking level first, then a search, the host's default,
/// and the host's catalog by provider, each model named without its provider and the host's
/// default tagged. Choosing a model closes it.
struct NewThreadModelPicker: View {
    let model: NewThreadModel
    /// The phone's sheet holds thinking too; the iPad has its own Thinking chip.
    var thinking = false
    let close: () -> Void
    @FocusState private var searching: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SH.Space.xl) {
                if thinking && model.offersThinking {
                    SHGroupCard {
                        SHCardRow("Thinking", description: "How long it reasons before it acts.") { thinkingMenu }
                    }
                }
                SHTouchSearchField("Search models", text: Binding(get: { model.modelQuery }, set: { model.setModelQuery($0) }), focus: $searching)
                if model.modelQuery.isEmpty {
                    SHGroupCard { hostDefaultRow }
                }
                ForEach(model.modelGroups) { group in
                    NewThreadSection(group.provider.isEmpty ? "Other" : group.provider) {
                        SHGroupCard {
                            ForEach(group.models) { option in row(option) }
                        }
                    }
                }
                if model.modelMatches.isEmpty {
                    Text(model.modelOptions.isEmpty ? "The host listed no models. Its default runs." : "No model matches “\(model.modelQuery)”.")
                        .shText(.caption)
                        .foregroundStyle(Color.sh.textTertiary)
                        .padding(.horizontal, SH.Space.s)
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.vertical, SH.Space.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.sh.bgWindow)
    }

    private var hostDefaultRow: some View {
        let detail = model.hostDefaultModel.map { id in
            model.host.map { "\(NewThreadRules.shortModel(id)) · set on \($0.name)" } ?? NewThreadRules.shortModel(id)
        }
        return Button {
            model.setModel("")
            close()
        } label: {
            SHChoiceRow("Host default", detail: detail, mono: false, selected: model.followsHostDefault) {
                Image(systemName: "sparkle")
                    .font(.sh(.ui))
                    .foregroundStyle(Color.sh.textSecondary)
            }
        }
        .buttonStyle(.shRow(selected: false, radius: 0))
    }

    private func row(_ option: NewThreadModelGroup.Model) -> some View {
        let selected = !model.followsHostDefault && option.id == model.defaults.model
        return Button {
            model.setModel(option.id)
            close()
        } label: {
            SHChoiceRow(option.name, selected: selected) {
                EmptyView()
            } trailing: {
                if option.id == model.hostDefaultModel { SHTag("default") }
            }
        }
        .buttonStyle(.shRow(selected: false, radius: 0))
        .accessibilityLabel(option.id)
    }

    private var thinkingMenu: some View {
        Menu {
            Picker("Thinking", selection: Binding(get: { model.thinking }, set: { model.setThinking($0) })) {
                ForEach(model.thinkingLevels, id: \.self) { level in
                    Text(level.title).tag(level)
                }
            }
        } label: {
            HStack(spacing: SH.Space.xs) {
                Text(model.thinking.title)
                    .font(.sh(.ui))
                    .foregroundStyle(Color.sh.textPrimary)
                Image(systemName: SHGlyph.popupChevrons.symbolName)
                    .font(.sh(.caption, weight: .semibold))
                    .foregroundStyle(Color.sh.textTertiary)
                    .accessibilityHidden(true)
            }
            .shTouchTarget(height: SH.Height.controlS)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Thinking, \(model.thinking.title)")
    }
}
