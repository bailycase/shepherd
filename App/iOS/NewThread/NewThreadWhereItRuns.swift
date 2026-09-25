import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

extension MobileLayout {
    /// New thread's prompt (the boards' 18pt).
    static let newThreadPromptSize: CGFloat = 18
    /// The phone's round Start button.
    static let newThreadStartSize: CGFloat = NW.Height.controlL
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
/// one sheet on iPhone.
struct NewThreadWhereItRuns: View {
    @Bindable var model: NewThreadModel

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: NW.Space.xxl) {
                        NewThreadSection("Repo") { NewThreadRepoList(model: model, carded: true) }
                        NewThreadSection("Host") { NewThreadHostList(model: model, carded: true) }
                        NewThreadWorktreeCard(model: model).id(NewThreadModel.Panel.worktree)
                    }
                    .padding(.horizontal, MobileLayout.gutter)
                    .padding(.vertical, NW.Space.xl)
                }
                .onAppear {
                    if model.workspaceAnchor == .worktree { proxy.scrollTo(NewThreadModel.Panel.worktree, anchor: .bottom) }
                }
            }
            .background(Color.nw.bgWindow)
            .navigationTitle("Where it runs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.panel = nil }.fontWeight(.semibold)
                }
            }
            .navigationDestination(item: $model.folders) { browser in
                NewThreadFolderScreen(model: model, browser: browser)
            }
        }
        .nwAnimation(.disclosure, value: model.usesWorktree)
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
        VStack(alignment: .leading, spacing: NW.Space.m) {
            Text(title)
                .font(.nw(.ui))
                .foregroundStyle(Color.nw.textSecondary)
                .padding(.horizontal, NW.Space.s)
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
            NWGroupCard(content: content)
        } else {
            VStack(spacing: 0) {
                Group(subviews: content()) { subviews in
                    ForEach(subviews) { subview in
                        if subview.id != subviews.first?.id { NWHairline() }
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

    var body: some View {
        let connected = model.host?.phase.isConnected == true
        NewThreadRowStack(carded: carded) {
            ForEach(model.repoRows) { row in
                Button { model.choose(repo: row.id) } label: {
                    NWChoiceRow(row.name, detail: row.detail, selected: row.selected) {
                        Image(systemName: "book.closed")
                            .font(.nw(.ui))
                            .foregroundStyle(Color.nw.textSecondary)
                    }
                }
                .buttonStyle(.nwRow(selected: false, radius: 0))
                .accessibilityHint(row.selected ? "" : "Runs the thread in \(row.name)")
            }
            if model.repoRows.isEmpty {
                Text(model.host.map { "No repos on \($0.name) yet." } ?? "Choose a host first.")
                    .nwText(.caption)
                    .foregroundStyle(Color.nw.textTertiary)
                    .padding(.horizontal, NW.Space.xl)
                    .frame(maxWidth: .infinity, minHeight: MobileLayout.rowHeight, alignment: .leading)
            }
            Button { model.browseFolders() } label: {
                NWChoiceRow("Add repo…", detail: model.host.map { "a folder on \($0.name)" }, mono: false) {
                    Image(systemName: "plus")
                        .font(.nw(.ui))
                        .foregroundStyle(Color.nw.running)
                }
            }
            .buttonStyle(.nwRow(selected: false, radius: 0))
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
                        .buttonStyle(.nwRow(selected: false, radius: 0))
                } else {
                    label(row)
                }
            }
        }
    }

    private func label(_ row: NewThreadHostRow) -> some View {
        NWChoiceRow(row.name, detail: row.detail, note: row.limitation, selected: row.selected, dimmed: !row.selectable) {
            NWStatusDot(row.status.agentState, size: NWChoiceRowMetrics.statusDot)
        } trailing: {
            if row.offersRetry {
                Button("Retry") { model.retry(host: row.id) }
                    .buttonStyle(.nwLink)
                    .nwTouchTarget(height: NW.Height.controlS)
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
        NWGroupCard {
            NWCardRow("New worktree", description: NewThreadRules.worktreeCaption(base: model.base.base),
                      problem: supported ? nil : model.host.map { "Update Shepherd on \($0.name) to start threads in a new worktree." }) {
                Toggle("New worktree", isOn: Binding(get: { on }, set: { model.setWorktree($0) }))
                    .toggleStyle(.nwSwitch)
                    .labelsHidden()
                    .nwTouchTarget(height: NW.Height.controlS, width: NW.Height.controlL)
                    .disabled(!supported)
            }
            if on {
                field("Branch", text: Binding(get: { model.branch }, set: { model.setBranch($0) }), prompt: "branch name")
                VStack(alignment: .leading, spacing: NW.Space.xs) {
                    field("Base", text: Binding(get: { model.base.base }, set: { model.setBase($0) }), prompt: "base branch")
                    Text(model.base.resolving ? "Resolving on \(model.host?.name ?? "the host")…" : model.base.note)
                        .nwText(.caption)
                        .foregroundStyle(Color.nw.textTertiary)
                        .nwContentTransition(.crossFade)
                        .padding(.leading, NW.Space.xl)
                        .padding(.bottom, model.base.note.isEmpty && !model.base.resolving ? 0 : NW.Space.m)
                }
                NWCardRow("Fetch origin first", description: "Resolves the base again after a fetch.") {
                    Toggle("Fetch origin first", isOn: Binding(get: { model.base.fetchFirst }, set: { model.setFetchFirst($0) }))
                        .toggleStyle(.nwSwitch)
                        .labelsHidden()
                        .nwTouchTarget(height: NW.Height.controlS, width: NW.Height.controlL)
                        .disabled(model.base.resolving)
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: NW.Space.l) {
            Text(label)
                .font(.nw(.ui))
                .foregroundStyle(Color.nw.textPrimary)
                .accessibilityHidden(true)
            TextField(label, text: text, prompt: Text(prompt).foregroundStyle(Color.nw.textTertiary))
                .font(.nw(.code))
                .foregroundStyle(Color.nw.textPrimary)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(label)
        }
        .padding(.horizontal, NW.Space.xl)
        .frame(minHeight: MobileLayout.rowHeight)
    }
}

/// The model picker: the host's catalog with a filter, and the host's default first.
struct NewThreadModelPicker: View {
    let model: NewThreadModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NWSearchField("Filter models", text: Binding(get: { model.modelQuery }, set: { model.setModelQuery($0) }))
                .padding(MobileLayout.gutter)
            NWHairline()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.modelQuery.isEmpty {
                        row("Host default", mono: false, selected: model.defaults.model.isEmpty) { model.setModel("") }
                    }
                    ForEach(model.modelMatches, id: \.self) { id in
                        row(id, mono: true, selected: id == model.defaults.model) { model.setModel(id) }
                    }
                    if model.modelMatches.isEmpty {
                        Text(model.modelOptions.isEmpty ? "The host listed no models. Its default runs." : "No matching models")
                            .nwText(.caption)
                            .foregroundStyle(Color.nw.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: MobileLayout.rowHeight)
                    }
                }
            }
        }
        .background(Color.nw.bgWindow)
    }

    private func row(_ title: String, mono: Bool, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            close()
        } label: {
            HStack(spacing: NW.Space.m) {
                Text(title)
                    .font(mono ? .nw(.code) : .nw(.ui))
                    .foregroundStyle(Color.nw.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").font(.nw(.ui, weight: .semibold)).foregroundStyle(Color.nw.running)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .frame(maxWidth: .infinity, minHeight: MobileLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nwRow(selected: false, radius: 0))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
