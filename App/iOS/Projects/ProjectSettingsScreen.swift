import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Project settings (the Mac's General, Spaces, Memory and Automations tabs) as one native form.
/// Every control edits the owner's record through `LogicalProjectsModel`, carrying the revision it
/// was shown; a refusal is said at the top and nothing is replayed.
struct ProjectSettingsScreen: View {
    let ref: LogicalProjectRef
    @Environment(MobileProjects.self) private var projects
    @Environment(MobileNavigator.self) private var navigator
    @State private var name = ""
    @State private var goal = ""
    @State private var instructions = ""
    @State private var loaded: UInt64?
    /// What the owner's record said when the fields were last filled from it.
    @State private var shown: (name: String, goal: String, instructions: String) = ("", "", "")
    /// nil until the owner's catalog answered.
    @State private var models: [String]?
    @State private var hostOptions: [ProjectHostOption]?
    @State private var confirmingDelete = false
    @State private var deleting = false

    private var model: LogicalProjectsModel { projects.model }

    var body: some View {
        let project = model.project(ref)
        let host = projects.host(ref)
        let editable = projects.canEdit(ref)
        Form {
            if let project {
                if let failure = model.failure {
                    Section { Text(failure.message).font(.nw(.caption)).foregroundStyle(Color.nw.failed) }
                }
                general(project, editable: editable)
                spaces(project, host: host, editable: editable)
                memory(project, editable: editable)
                automations(project, host: host, editable: editable)
                Section {
                    Button("Delete project…", role: .destructive) { confirmingDelete = true }
                        .disabled(!editable || deleting)
                } footer: {
                    Text("Removes the conversation, memory and automations. Threads stay in their spaces; branches and PRs are untouched.")
                }
            } else {
                Section { Text("This project is gone. It was deleted on its host.").foregroundStyle(Color.nw.textSecondary) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.nw.bgWindow)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("Project settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load(project) }
        .onChange(of: project?.revision) { load(project) }
        .task(id: host?.session) {
            if let client = host?.connectedClient, let listing = try? await client.listModels() { models = listing.models } else { models = nil }
            hostOptions = await model.hostOptions(ref.home)
        }
        .confirmationDialog("Delete project", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete project", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes \(project?.name ?? "the project")’s conversation, memory and automations from \(host?.name ?? "its host"). "
                 + "Threads stay in their spaces; branches and pull requests are untouched. "
                 + "The project’s files stay on that host: Shepherd does not delete them.")
        }
    }

    // MARK: General

    @ViewBuilder private func general(_ project: Project, editable: Bool) -> some View {
        let settings = project.settings
        let textChanged = name != project.name || goal != project.goal
        Section {
            TextField("Name", text: $name).font(.nw(.ui)).accessibilityLabel("Project name")
            TextField("Goal", text: $goal, axis: .vertical).font(.nw(.ui)).accessibilityLabel("Goal")
            if textChanged {
                Button("Save name and goal") {
                    Task { _ = await model.edit(ref, name: name.trimmingCharacters(in: .whitespacesAndNewlines), goal: goal) }
                }
                .disabled(!editable || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: { Text("General") } footer: { Text("The goal is one line the project works toward. Optional.") }
        Section {
            modelPicker("Conversation model", current: settings.conversationModel, editable: editable) { settings, choice in settings.conversationModel = choice }
            modelPicker("Thread model", current: settings.threadModel, editable: editable) { settings, choice in settings.threadModel = choice }
            Picker("Threads at once", selection: Binding(get: { settings.maxConcurrentWorkers }, set: { count in
                guard count != settings.maxConcurrentWorkers else { return }
                Task { _ = await model.saveSettings(ref) { $0.maxConcurrentWorkers = count } }
            })) {
                ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
            }
            .disabled(!editable)
        } footer: {
            Text("The conversation model plans the work and talks with you; each thread uses the thread model unless the task says otherwise. "
                 + "More threads wait for a slot, counted across every host.")
        }
    }

    /// A model preference from the owner's real catalog. Default clears it; the saved one stays listed
    /// even when the owner no longer offers it.
    private func modelPicker(_ label: String, current: String?, editable: Bool,
                             change: @escaping (inout LogicalProjectSettings, String?) -> Void) -> some View {
        let options = ([current].compactMap { $0 } + (models ?? [])).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return Picker(label, selection: Binding(get: { current }, set: { choice in
            guard choice != current else { return }
            Task { _ = await model.saveSettings(ref) { change(&$0, choice) } }
        })) {
            Text("Default").tag(String?.none)
            ForEach(options, id: \.self) { Text($0).tag(Optional($0)) }
        }
        .disabled(!editable || models == nil)
    }

    // MARK: Spaces

    @ViewBuilder private func spaces(_ project: Project, host: MobileHost?, editable: Bool) -> some View {
        let owned = host?.state.spaces ?? []
        // Links to the owner's own Spaces; one placed on another host is named by the owner's record only.
        let linked = project.linkedSpaces
        let addable = owned.filter { space in !linked.contains { $0.destination == .local && $0.spaceID == space.id } }
        let offers = project.spaceProposals.filter { $0.phase == .pending }
        Section {
            if linked.isEmpty {
                Text("No spaces yet. Add one, or let the project ask when the work needs a folder.")
                    .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            }
            ForEach(linked, id: \.id) { link in
                let space = link.destination == .local ? owned.first { $0.id == link.spaceID } : nil
                HStack(spacing: NW.Space.m) {
                    VStack(alignment: .leading, spacing: NW.Space.xxs) {
                        Text(space?.name ?? "A space on another host").font(.nw(.ui))
                        Text(Self.provenance(link)).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                    }
                    Spacer(minLength: NW.Space.m)
                    Button("Remove", role: .destructive) {
                        Task { _ = await model.unlink(ref, space: link.spaceID, host: link.host) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!editable)
                    .accessibilityLabel("Remove \(space?.name ?? "space")")
                }
            }
            if !addable.isEmpty {
                Menu("Add a space…") {
                    ForEach(addable) { space in
                        Button(space.name) { Task { _ = await model.link(ref, space: space.id) } }
                    }
                }
                .disabled(!editable)
            }
            ForEach(offers) { ProjectSpaceOffer(ref: ref, proposal: $0) }
            Toggle("The project can add spaces", isOn: Binding(get: { project.settings.canRequestSpaceLinks }, set: { value in
                Task { _ = await model.saveSettings(ref) { $0.canRequestSpaceLinks = value } }
            }))
            .disabled(!editable)
            hostsPicker(project, owner: host?.name ?? "The host", editable: editable)
        } header: { Text("Spaces") } footer: {
            Text("When work needs a folder that isn’t here, the project asks in the conversation. With the switch off it only suggests. "
                 + "Hosts are where threads may run; a space must be set up on a host first.")
        }
    }

    /// Where threads may run, from the OWNER's own host list: "<owner> and <host>", "<owner> only", "Any connected host".
    private func hostsPicker(_ project: Project, owner: String, editable: Bool) -> some View {
        let settings = project.settings
        var choices: [(title: String, policy: ProjectHostPolicy, hosts: [ProjectHostReference])] = []
        for option in hostOptions ?? [] where option.reference != .local {
            choices.append(("\(owner) and \(option.name)", .selected, [.local, option.reference]))
        }
        choices.append(("\(owner) only", .selected, [.local]))
        choices.append(("Any connected host", .anyConnected, settings.allowedHosts))
        let current = choices.first { $0.policy == settings.hostPolicy && ($0.policy == .anyConnected || $0.hosts == settings.allowedHosts) }?.title
        return Picker("Hosts", selection: Binding(get: { current }, set: { title in
            guard title != current, let choice = choices.first(where: { $0.title == title }) else { return }
            Task { _ = await model.saveSettings(ref) { $0.hostPolicy = choice.policy; $0.allowedHosts = choice.hosts } }
        })) {
            if current == nil { Text("As set on the Mac").tag(String?.none) }
            ForEach(choices, id: \.title) { Text($0.title).tag(Optional($0.title)) }
        }
        .disabled(!editable || hostOptions == nil)
    }

    static func provenance(_ link: ProjectSpaceLink) -> String {
        switch link.provenance {
        case .user: "Added by you"
        case .project: "Added by the project · " + Date(milliseconds: link.linkedAt).formatted(.dateTime.month(.abbreviated).day())
        }
    }

    // MARK: Memory

    @ViewBuilder private func memory(_ project: Project, editable: Bool) -> some View {
        let limit = Project.maximumInstructionsLength
        Section {
            TextEditor(text: $instructions)
                .font(.nw(.body))
                .frame(minHeight: MobileLayout.projectInstructionsMinHeight)
                .accessibilityLabel("Project instructions")
            if instructions != project.settings.instructions {
                HStack {
                    Button("Save") {
                        let text = instructions
                        Task { _ = await model.saveSettings(ref) { $0.instructions = text } }
                    }
                    .disabled(!editable || instructions.count > limit)
                    Spacer()
                    Button("Revert") { instructions = project.settings.instructions }
                }
                .buttonStyle(.borderless)
            }
        } header: { Text("Project instructions") } footer: {
            Text("Sent to the conversation and to every new thread, after each space’s AGENTS.md. \(instructions.count.formatted()) of \(limit.formatted()) characters.")
                .foregroundStyle(instructions.count > limit ? Color.nw.failed : Color.nw.textTertiary)
        }
        Section("What the project remembers") {
            if project.memory.isEmpty {
                Text("Nothing yet. What you decide and what the project learns is kept here, and you can make it forget any of it.")
                    .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            }
            ForEach(project.memory) { entry in
                HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
                    Text(entry.text).font(.nw(.ui)).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Forget") { Task { _ = await model.forget(ref, memory: entry.id) } }
                        .buttonStyle(.borderless)
                        .disabled(!editable)
                        .accessibilityLabel("Forget: \(entry.text)")
                }
            }
        }
    }

    // MARK: Automations

    @ViewBuilder private func automations(_ project: Project, host: MobileHost?, editable: Bool) -> some View {
        let rows = (host?.state.automations ?? []).filter { $0.projectID == project.id }
        let manageable = host?.supports(RemoteProtocol.logicalProjectAutomationsCapability) == true
        Section {
            if rows.isEmpty {
                Text("Automations that belong to \(project.name) show here with a switch for each.")
                    .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            }
            ForEach(rows) { automation in
                Toggle(isOn: Binding(get: { automation.enabled }, set: { value in
                    Task { _ = await model.automation(ref, automation.id, .setEnabled(value)) }
                })) {
                    VStack(alignment: .leading, spacing: NW.Space.xxs) {
                        Text(automation.name).font(.nw(.ui))
                        if let line = automation.prompt.split(whereSeparator: \.isNewline).first {
                            Text(String(line)).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary).lineLimit(1)
                        }
                    }
                }
                .disabled(!editable || !manageable)
            }
        } header: { Text("Automations") } footer: {
            if !rows.isEmpty, !manageable { Text("Update Shepherd on \(host?.name ?? "the host") to switch these here.") }
        }
    }

    // MARK: Loading and deleting

    /// A newer revision replaces the fields only where there are no unsaved edits, so typing is never overwritten.
    private func load(_ project: Project?) {
        guard let project, loaded != project.revision else { return }
        let fresh = loaded == nil
        if fresh || name == shown.name { name = project.name }
        if fresh || goal == shown.goal { goal = project.goal }
        if fresh || instructions == shown.instructions { instructions = project.settings.instructions }
        shown = (project.name, project.goal, project.settings.instructions)
        loaded = project.revision
    }

    private func delete() {
        deleting = true
        Task {
            let ok = await model.delete(ref)
            deleting = false
            if ok { navigator.popToRoot() }
        }
    }
}
