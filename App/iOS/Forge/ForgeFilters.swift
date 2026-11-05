import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Under the search field, on a host that browses: Waiting on me or Everything, the filter menu
/// (state, author, assignee, label, sort), and a chip per active filter that removes it.
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
            HStack(spacing: SH.Space.m) {
                Menu {
                    Picker("Show", selection: Binding(get: { store.browsing }, set: { if $0 { store.everything = true } else { store.clearFilters() } })) {
                        Text("Waiting on me").tag(false)
                        Text(store.allRepos ? "Everything involving me" : "Everything in \(store.repo?.repo.name ?? "the repository")").tag(true)
                    }
                } label: {
                    pill(store.browsing ? "Everything" : "Waiting on me", symbol: "chevron.down")
                }
                .accessibilityLabel("Show")
                .accessibilityValue(store.browsing ? "Everything" : "Waiting on me")
                Menu { filterItems } label: { pill("Filter", symbol: "line.3.horizontal.decrease") }
                    .accessibilityLabel("Filter")
                Spacer(minLength: 0)
                if store.browsing {
                    Button("Clear") { store.clearFilters() }
                        .font(.sh(.ui, weight: .medium))
                        .foregroundStyle(Color.sh.textSecondary)
                        .frame(minHeight: SH.Height.touch)
                        .accessibilityHint("Back to what's waiting on you")
                }
            }
            if !chips.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: SH.Space.s) {
                        ForEach(chips, id: \.title) { chip in
                            Button(action: chip.remove) {
                                HStack(spacing: SH.Space.xs) {
                                    Text(chip.title).font(.sh(.caption, weight: .medium)).lineLimit(1)
                                    Image(systemName: "xmark").font(.sh(.micro, weight: .semibold))
                                }
                                .foregroundStyle(Color.sh.textSecondary)
                                .padding(.horizontal, SH.Space.m)
                                .padding(.vertical, SH.Space.xs)
                                .background(Color.sh.bgSelected, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(chip.title)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .task(id: store.repo?.id) {
            if let repo = store.repo { await store.loadPeople(host: repo.host, repo: repo.repo.nameWithOwner) }
        }
        .alert(asking?.title ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), presenting: asking) { ask in
            TextField(ask == .label ? "Label" : "GitHub login", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Filter") {
                let value = draft.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
                guard !value.isEmpty else { return }
                store.everything = true
                switch ask {
                case .author: store.filter.author = value
                case .assignee: store.filter.assignee = value
                case .label: store.filter.label = value
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var filterItems: some View {
        Picker("State", selection: edit(\.state)) {
            ForEach(ForgeFilter.State.allCases.filter { store.kind == .pullRequest || $0 != .merged }, id: \.self) { state in
                Text(state.rawValue.capitalized).tag(state)
            }
        }
        Menu("Author") { people(\.author, ask: .author) }
        Menu("Assignee") { people(\.assignee, ask: .assignee) }
        Menu("Label") {
            Picker("Label", selection: edit(\.label)) {
                Text("Any label").tag(String?.none)
                ForEach(store.knownLabels, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Button("Other…") { ask(.label) }
        }
        Menu("Sort") {
            Picker("Sort", selection: edit(\.sort)) {
                Text("Recently updated").tag(ForgeFilter.Sort.updated)
                Text("Newest").tag(ForgeFilter.Sort.created)
                Text("Most commented").tag(ForgeFilter.Sort.comments)
            }
        }
        Toggle("Only involving me", isOn: edit(\.mine))
    }

    @ViewBuilder private func people(_ path: WritableKeyPath<ForgeFilter, String?>, ask kind: Ask) -> some View {
        Picker(kind == .author ? "Author" : "Assignee", selection: edit(path)) {
            Text("Anyone").tag(String?.none)
            Text("Me").tag(String?.some("@me"))
            ForEach(store.knownPeople, id: \.self) { Text($0).tag(String?.some($0)) }
        }
        Button("Other…") { ask(kind) }
    }

    private func pill(_ title: String, symbol: String) -> some View {
        HStack(spacing: SH.Space.xs) {
            Text(title).font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
            Image(systemName: symbol).font(.sh(.micro, weight: .semibold)).foregroundStyle(Color.sh.textSecondary)
        }
        .padding(.horizontal, SH.Space.l)
        .frame(minHeight: SH.Height.controlL)
        .background(Color.sh.bgRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.sh.lineStrong))
        .frame(minHeight: SH.Height.touch)
        .contentShape(Rectangle())
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

/// New issue: a repository a host knows, a title and a description, opened through that host's gh.
struct ForgeNewIssueSheet: View {
    let store: ForgeStore
    let opened: (ForgeItemKey) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choice: String
    @State private var title = ""
    @State private var text = ""
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    init(store: ForgeStore, opened: @escaping (ForgeItemKey) -> Void) {
        self.store = store
        self.opened = opened
        _choice = State(initialValue: store.repo?.id ?? store.repos.first { $0.host == store.browseHost?.id }?.id ?? "")
    }

    var body: some View {
        let picked = store.repos.first { $0.id == choice }
        let ready = !sending && picked != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ForgeSheetFrame(title: "New issue", action: "Open issue", ready: ready, problem: problem, fraction: MobileLayout.forgeSheetFraction) {
            guard let picked, store.hostBrowses(picked.host) else {
                problem = "Update Shepherd on \(picked.map { store.hostName($0.host) } ?? "the Mac") to open issues from here."
                return
            }
            sending = true
            Task {
                defer { sending = false }
                if let key = await store.createIssue(host: picked.host, repo: picked.repo.nameWithOwner, title: title, body: text) {
                    dismiss()
                    opened(key)
                } else if let failure = store.failure {
                    problem = failure
                    store.failure = nil
                } else {
                    dismiss()
                }
            }
        } content: {
            Menu {
                ForEach(store.repos) { repo in Button(repo.repo.nameWithOwner) { choice = repo.id } }
            } label: {
                HStack {
                    Text(picked?.repo.nameWithOwner ?? "Pick a repository").font(.sh(.mono)).foregroundStyle(Color.sh.textPrimary)
                    Spacer()
                    SHGlyph.popupChevrons.image.font(.sh(.micro, weight: .semibold)).foregroundStyle(Color.sh.textSecondary)
                }
                .padding(.horizontal, SH.Space.l)
                .frame(minHeight: SH.Height.touch)
                .shCard(radius: MobileLayout.cardRadius, line: Color.sh.lineStrong)
            }
            .accessibilityLabel("Repository")
            TextField("Title", text: $title)
                .font(.sh(.body))
                .padding(.horizontal, SH.Space.l)
                .frame(minHeight: SH.Height.touch)
                .shCard(radius: MobileLayout.cardRadius, line: Color.sh.lineStrong)
                .focused($focused)
            ForgeTextBox(text: $text, prompt: "Describe it", focused: $focused)
        }
        .onAppear { focused = true }
    }
}

/// Labels, Assignees and (a pull request) Reviewers in an item's ••• menu: each choice the
/// repository offers, checked when the item has it.
struct ForgeEditMenus: View {
    let store: ForgeStore
    let key: ForgeItemKey
    let labels: [String]
    let assignees: [String]
    /// Reviewers asked and not yet reviewed; nil for an issue or a pull request that's done.
    let reviewers: [String]?

    var body: some View {
        if store.hostBrowses(key.host) {
            let people = store.people[ForgeStore.peopleKey(host: key.host, repo: key.ref.repo)]
            menu("Labels", systemImage: "tag", field: .labels, current: labels, choices: people?.labels.map(\.name), loaded: people != nil)
            menu("Assignees", systemImage: "person", field: .assignees, current: assignees, choices: people?.assignable, loaded: people != nil)
            if let reviewers {
                menu("Reviewers", systemImage: "person.2", field: .reviewers, current: reviewers, choices: people?.assignable, loaded: people != nil)
            }
        }
    }

    private func menu(_ title: String, systemImage: String, field: ForgeEditField, current: [String], choices: [String]?, loaded: Bool) -> some View {
        var seen = Set<String>()
        let all = (current + (choices ?? [])).filter { seen.insert($0.lowercased()).inserted }
        return Menu {
            if all.isEmpty { Text(loaded ? "Nothing to pick" : "Loading…") }
            ForEach(all, id: \.self) { value in
                let on = current.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
                Toggle(value, isOn: Binding(get: { on }, set: { next in Task { await store.toggle(field, value, on: next, for: key) } }))
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}
