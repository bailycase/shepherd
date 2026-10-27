import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Every Project on every paired host, grouped by its owner. Always a tab on iPhone: when no
/// host serves Projects, the empty state says why instead of the entry disappearing.
struct ProjectsScreen: View {
    @Environment(MobileProjects.self) private var projects
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var creatable: Bool { projects.owners.contains { $0.connected && $0.supported } }

    var body: some View {
        let rows = projects.rows
        Group {
            if rows.isEmpty {
                SHEmptyState(Text("No projects"), message: Self.emptyMessage(projects.owners)) {
                    if creatable {
                        Button("New project", systemImage: "plus") { navigator.present(.projects(.create(host: nil))) }
                            .buttonStyle(.sh(.primary))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                        ForEach(Self.groups(rows), id: \.home) { group in
                            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                                SHListHeader(group.owner, count: group.rows.count)
                                SHListCard {
                                    ForEach(group.rows) { row in
                                        Button { navigator.open(.projects(.project(row.ref))) } label: {
                                            SHListRow(row.name, subtitle: row.summary.nilIfEmpty, subtitleMono: false,
                                                      leading: .symbol("square.stack.3d.up", row.needsYou > 0 ? .attention : nil),
                                                      trailing: row.needsYou > 0 ? .alert("\(row.needsYou) needs you")
                                                          : row.connected ? .none : .meta("Offline"),
                                                      dimmed: !row.connected)
                                        }
                                        .buttonStyle(.shRow(radius: 0))
                                    }
                                }
                            }
                        }
                        if let note = Self.unsupportedNote(projects.owners) {
                            Text(note).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, MobileLayout.gutter)
                    .padding(.bottom, MobileLayout.sectionSpacing)
                }
            }
        }
        .refreshable { await projects.refresh() }
        .task { await projects.refresh() }
        .background(Color.sh.bgWindow)
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(sizeClass == .regular ? .inline : .large)
        .toolbar {
            if creatable {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New project", systemImage: "plus") { navigator.present(.projects(.create(host: nil))) }
                        .buttonStyle(.glassProminent)
                        .tint(Color.sh.lantern)
                }
            }
        }
    }

    struct OwnerGroup: Equatable { let home: LogicalProjectHome; let owner: String; let rows: [MobileProjectRow] }

    static func groups(_ rows: [MobileProjectRow]) -> [OwnerGroup] {
        var order: [LogicalProjectHome] = []
        var by: [LogicalProjectHome: [MobileProjectRow]] = [:]
        for row in rows {
            if by[row.ref.home] == nil { order.append(row.ref.home) }
            by[row.ref.home, default: []].append(row)
        }
        return order.map { OwnerGroup(home: $0, owner: by[$0]?.first?.owner ?? "", rows: by[$0] ?? []) }
    }

    /// Why nothing is listed, in the order a person would fix it.
    static func emptyMessage(_ owners: [MobileProjectOwner]) -> String {
        if owners.isEmpty { return "Projects live on a Mac. Pair one in Settings ▸ Hosts to see its projects here." }
        if !owners.contains(where: \.connected) { return "No host is connected. Projects show here once their Mac is back online." }
        if !owners.contains(where: { $0.connected && $0.supported }) {
            return "No connected host serves Projects. Turn on Projects in Settings ▸ Experiments on the Mac, or update Shepherd there."
        }
        return "A project is one ongoing conversation that plans work and runs threads in its spaces. Start one here."
    }

    static func unsupportedNote(_ owners: [MobileProjectOwner]) -> String? {
        let names = owners.filter { $0.connected && !$0.supported }.map(\.name)
        guard !names.isEmpty else { return nil }
        return "\(names.joined(separator: ", ")) doesn't serve Projects. Turn them on in Settings ▸ Experiments there, or update Shepherd."
    }
}

/// New project (the Mac's NewProjectSheet): Name required, Goal and Spaces optional. One Project ID
/// per sheet, so a retry after an answer that never came back creates nothing twice.
struct NewProjectScreen: View {
    let host: UUID?
    @Environment(MobileProjects.self) private var projects
    @Environment(MobileNavigator.self) private var navigator
    @State private var name = ""
    @State private var goal = ""
    @State private var spaces: Set<SpaceID> = []
    @State private var chosenHost: UUID?
    @State private var id = ProjectID()
    @State private var saving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        let owners = projects.owners.filter { $0.connected && $0.supported }
        // The host is the consent boundary: once chosen it is kept, and a host that goes offline or loses
        // Projects disables Create rather than handing the project to another one.
        let owner = chosenHost.flatMap { id in projects.owners.first { $0.id == id } }
        let usable = owner.map { $0.connected && $0.supported } ?? false
        let ready = usable && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving
        Form {
            Section("Name") {
                TextField("Name", text: $name)
                    .font(.sh(.ui))
                    .focused($nameFocused)
                    .accessibilityLabel("Project name")
            }
            Section {
                TextField("Goal", text: $goal, axis: .vertical)
                    .font(.sh(.ui))
                    .accessibilityLabel("Goal")
            } header: { Text("Goal") } footer: { Text("One line the project works toward. Optional.") }
            if owners.count > 1 || !usable {
                Section {
                    Picker("Host", selection: Binding(get: { chosenHost }, set: { chosenHost = $0; spaces = [] })) {
                        if chosenHost == nil || !owners.contains(where: { $0.id == chosenHost }) {
                            Text(owner?.name ?? "Choose…").tag(chosenHost)
                        }
                        ForEach(owners) { Text($0.name).tag(Optional($0.id)) }
                    }
                } header: { Text("Host") } footer: {
                    if let owner, !usable {
                        Text(owner.connected ? "\(owner.name) doesn't serve Projects." : "\(owner.name) is offline. Reconnect it, or choose another host.")
                    }
                }
            }
            Section {
                if let owner, !owner.spaces.isEmpty {
                    ForEach(owner.spaces) { space in
                        Toggle(isOn: Binding(get: { spaces.contains(space.id) },
                                             set: { if $0 { spaces.insert(space.id) } else { spaces.remove(space.id) } })) {
                            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                                Text(space.name).font(.sh(.ui))
                                Text(space.path).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                } else {
                    Text("\(owner?.name ?? "The host") has no spaces yet. The project can still plan, and ask for a folder when work needs one.")
                        .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
            } header: { Text("Spaces") } footer: { Text("Optional. Threads the project starts work in these folders.") }
            if let error {
                Section { Text(error).font(.sh(.caption)).foregroundStyle(Color.sh.failed) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.sh.bgWindow)
        .navigationTitle("New project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { navigator.dismissPresented() } }
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView().progressViewStyle(SHSpinnerStyle()) } else {
                    Button("Create project") { create(owner) }.disabled(!ready)
                }
            }
        }
        .onAppear {
            nameFocused = true
            // Only the first entry picks a host for the person: the one asked for, else the first that takes Projects.
            if chosenHost == nil { chosenHost = host ?? owners.first?.id }
        }
    }

    private func create(_ owner: MobileProjectOwner?) {
        guard let owner, owner.connected, owner.supported else { return }
        saving = true
        error = nil
        let home = LogicalProjectHome.host(owner.id)
        let chosen = owner.spaces.map(\.id).filter(spaces.contains)
        Task {
            let made = await projects.model.create(home: home, id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   goal: goal.trimmingCharacters(in: .whitespacesAndNewlines), spaces: chosen)
            saving = false
            if let made {
                navigator.dismissPresented()
                navigator.open(.projects(.project(LogicalProjectRef(home: home, id: made.id))))
            } else {
                error = projects.model.failure?.message ?? "The project was not created."
            }
        }
    }
}
