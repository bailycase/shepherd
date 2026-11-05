import SwiftUI
import ShepherdUI
import ShepherdProtocol

// MARK: The filter bar

/// Under the search field: Waiting on me or Everything, the Filter menu (state, author, assignee,
/// label, sort), and a chip per active filter that removes it. Any filter browses Everything.
struct ForgeFilterBar: View {
    @Bindable var store: ForgeStore
    @State private var asking: Ask?
    @State private var draft = ""

    private enum Ask: String, Identifiable {
        case author, assignee, label
        var id: String { rawValue }
        var title: String {
            switch self {
            case .author: "Filter by author"
            case .assignee: "Filter by assignee"
            case .label: "Filter by label"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(spacing: SH.Space.s) {
                scope
                filterMenu
                Spacer(minLength: 0)
                if store.browsing {
                    Button("Clear") { store.clearFilters() }
                        .buttonStyle(.sh(.ghost, size: .s))
                        .help("Back to what's waiting on you")
                }
            }
            if !chips.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: SH.Space.xs) {
                        ForEach(chips, id: \.title) { chip in ForgeFilterChip(title: chip.title, remove: chip.remove) }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .alert(asking?.title ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), presenting: asking) { ask in
            TextField(ask == .label ? "Label" : "GitHub login", text: $draft)
            Button("Filter") {
                let value = draft.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
                if !value.isEmpty { set(ask, value) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var scope: some View {
        Menu {
            Picker("Show", selection: Binding(get: { store.browsing }, set: { if $0 { store.everything = true } else { store.clearFilters() } })) {
                Text("Waiting on me").tag(false)
                Text(store.repo == nil ? "Everything involving me" : "Everything in \(store.repoName)").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            SHPopupLabel(store.browsing ? "Everything" : "Waiting on me")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show what's waiting on you, or browse everything")
        .accessibilityLabel("Show")
        .accessibilityValue(store.browsing ? "Everything" : "Waiting on me")
    }

    private var filterMenu: some View {
        let kind = store.kind
        return Menu {
            Picker("State", selection: edit(\.state)) {
                ForEach(ForgeFilter.State.allCases.filter { kind == .pullRequest || $0 != .merged }, id: \.self) { state in
                    Text(state.rawValue.capitalized).tag(state)
                }
            }
            .pickerStyle(.inline)
            Menu("Author") { people(\.author, ask: .author) }
            Menu("Assignee") { people(\.assignee, ask: .assignee) }
            Menu("Label") {
                Picker("Label", selection: edit(\.label)) {
                    Text("Any label").tag(String?.none)
                    ForEach(store.knownLabels, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .pickerStyle(.inline)
                Button("Other…") { ask(.label) }
            }
            Menu("Sort") {
                Picker("Sort", selection: edit(\.sort)) {
                    Text("Recently updated").tag(ForgeFilter.Sort.updated)
                    Text("Newest").tag(ForgeFilter.Sort.created)
                    Text("Most commented").tag(ForgeFilter.Sort.comments)
                }
                .pickerStyle(.inline)
            }
            Divider()
            Toggle("Only involving me", isOn: edit(\.mine))
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .menuStyle(.button)
        .buttonStyle(.shIcon(size: SH.Height.controlM))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter")
        .accessibilityLabel("Filter")
    }

    @ViewBuilder private func people(_ path: WritableKeyPath<ForgeFilter, String?>, ask kind: Ask) -> some View {
        Picker(kind == .author ? "Author" : "Assignee", selection: edit(path)) {
            Text("Anyone").tag(String?.none)
            Text("Me").tag(String?.some("@me"))
            ForEach(store.knownPeople, id: \.self) { Text($0).tag(String?.some($0)) }
        }
        .pickerStyle(.inline)
        Button("Other…") { ask(kind) }
    }

    /// A filter field; setting it browses Everything.
    private func edit<Value>(_ path: WritableKeyPath<ForgeFilter, Value>) -> Binding<Value> {
        Binding(get: { store.filter[keyPath: path] }, set: { value in
            store.everything = true
            store.filter[keyPath: path] = value
        })
    }

    private func ask(_ kind: Ask) {
        draft = ""
        asking = kind
    }

    private func set(_ ask: Ask, _ value: String) {
        store.everything = true
        switch ask {
        case .author: store.filter.author = value
        case .assignee: store.filter.assignee = value
        case .label: store.filter.label = value
        }
    }

    private var chips: [(title: String, remove: () -> Void)] {
        let filter = store.filter
        func person(_ login: String) -> String { login == "@me" ? "me" : login }
        var chips: [(String, () -> Void)] = []
        if filter.state != .open { chips.append((filter.state.rawValue.capitalized, { store.filter.state = .open })) }
        if let author = filter.author { chips.append(("Author: \(person(author))", { store.filter.author = nil })) }
        if let assignee = filter.assignee { chips.append(("Assignee: \(person(assignee))", { store.filter.assignee = nil })) }
        if let label = filter.label { chips.append(("Label: \(label)", { store.filter.label = nil })) }
        if filter.mine { chips.append(("Involving me", { store.filter.mine = false })) }
        switch filter.sort {
        case .created: chips.append(("Newest", { store.filter.sort = .updated }))
        case .comments: chips.append(("Most commented", { store.filter.sort = .updated }))
        case .updated: break
        }
        return chips
    }
}

/// An active filter: its words and the × that removes it.
private struct ForgeFilterChip: View {
    let title: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: SH.Space.xs) {
            Text(title).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark").font(.sh(.micro)) }
                .buttonStyle(.plain)
                .foregroundStyle(Color.sh.textTertiary)
                .accessibilityLabel("Remove \(title)")
        }
        .padding(.horizontal, SH.Space.s)
        .padding(.vertical, SH.Space.xxs)
        .background(Color.sh.bgSelected, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
        .fixedSize()
    }
}

// MARK: New issue

/// New Issue: a repository this host knows, a title and a description, opened through gh.
struct ForgeNewIssueSheet: View {
    let store: ForgeStore
    let close: () -> Void
    @State private var repo: String
    @State private var title = ""
    @State private var body_ = ""
    @State private var sending = false

    init(store: ForgeStore, close: @escaping () -> Void) {
        self.store = store
        self.close = close
        _repo = State(initialValue: store.repo ?? store.repos.first?.nameWithOwner ?? "")
    }

    var body: some View {
        SHDialog("New issue", message: "Opened on GitHub as you, through gh.") {
            VStack(alignment: .leading, spacing: 0) {
                SHSheetRow("Repository") {
                    SHPopupMenu(repo.isEmpty ? "Pick one" : repo, mono: true) {
                        ForEach(store.repos) { found in Button(found.nameWithOwner) { repo = found.nameWithOwner } }
                    }
                }
                SHSheetRow("Title") {
                    TextField("What's wrong or wanted", text: $title).textFieldStyle(.sh).accessibilityLabel("Title")
                }
                TextEditor(text: $body_)
                    .font(.sh(.ui, weight: .regular))
                    .foregroundStyle(Color.sh.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(SH.Space.s)
                    .frame(height: AppLayout.forgeReviewTextHeight * 2)
                    .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                    .shBorder(Color.sh.lineStrong, radius: SH.Radius.s)
                    .padding(.horizontal, SHDialogMetrics.inset)
                    .padding(.top, SH.Space.l)
                    .accessibilityLabel("Description")
            }
        } status: {
            if let error = store.actionError { SHDialogStatus(error.message, isError: true) }
        } actions: {
            Button("Cancel", action: close).buttonStyle(.sh(.secondary)).keyboardShortcut(.cancelAction)
            Button("Open issue") {
                sending = true
                Task {
                    let made = await store.createIssue(repo: repo, title: title, body: body_)
                    sending = false
                    if made { close() }
                }
            }
            .buttonStyle(.sh(.primary))
            .keyboardShortcut(.defaultAction)
            .disabled(sending || repo.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

// MARK: Editing an item's lists

/// The + beside Labels, Assignees or Reviewers: every choice the repository offers, checked when
/// the item has it; picking one adds or removes it on GitHub.
struct ForgeEditMenu: View {
    let store: ForgeStore
    let field: ForgeEditField
    let repo: String
    let current: [String]

    var body: some View {
        let people = store.people[repo]
        let choices = field == .labels ? (people?.labels.map(\.name) ?? []) : (people?.assignable ?? [])
        let all = Array(NSOrderedSet(array: current + choices)) as? [String] ?? choices
        Menu {
            if all.isEmpty { Text(people == nil ? "Loading…" : "Nothing to pick") }
            ForEach(all, id: \.self) { value in
                let on = current.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
                Toggle(value, isOn: Binding(get: { on }, set: { next in Task { await store.toggle(field, value, on: next) } }))
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.shIcon(size: SH.Height.controlS))
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(store.working)
        .help("Edit \(field.rawValue)")
        .accessibilityLabel("Edit \(field.rawValue)")
        .task(id: repo) { await store.loadPeople(repo) }
    }
}
