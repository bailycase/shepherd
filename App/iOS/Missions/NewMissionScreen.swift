import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// New mission on a host (presented): where you want to end up, the host's Git repositories each
/// from a branch you pick, and the model. The host makes a fresh worktree per repository and its
/// planner starts there; the phone never names a repository, branch or model the host didn't list.
struct NewMissionScreen: View {
    let host: UUID?
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss
    @State private var chosenHost: UUID?
    @State private var goal = ""
    @State private var spaces: [SpaceID] = []
    @State private var branches: [SpaceID: String] = [:]
    @State private var model = ""
    @State private var busy = false
    @State private var failure: String?

    private var serving: [MobileHost] { hosts.hosts.filter(\.servesMissions) }
    private var target: MobileHost? { serving.first { $0.id == (chosenHost ?? host) } ?? serving.first }
    private var options: RemoteMissionStartOptions? { target?.missions.startOptions }

    private var blocker: String? {
        guard let options else { return "Reading the host's repositories…" }
        if options.spaces.isEmpty { return "Add a Git repository as a Space on the host to plan a mission." }
        if spaces.isEmpty { return "Choose at least one repository." }
        if spaces.contains(where: { space in
            guard let branch = branches[space], !branch.isEmpty else { return true }
            return options.branchChoices[space]?.contains(branch) != true
        }) { return "Choose a starting branch for each repository." }
        if model.isEmpty { return "Choose a model." }
        if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Describe where you want to end up." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let failure { Section { Text(failure).shText(.caption).foregroundStyle(Color.sh.failed) } }
                if serving.count > 1 {
                    Section("Host") {
                        Picker("Runs on", selection: Binding(get: { target?.id ?? UUID() }, set: { chosenHost = $0; reset() })) {
                            ForEach(serving) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                Section {
                    TextField("Add checkout funnel analytics so product can see drop-off at every step…", text: $goal, axis: .vertical)
                        .shText(.body).lineLimit(4...12)
                        .accessibilityLabel("Mission goal")
                } header: { Text("Where do you want to end up?") } footer: {
                    Text("The planner reads the repositories you pick, finds the context and the checks, and only asks what it can't work out.")
                }
                Section("Repositories the planner may read") {
                    ForEach(options?.spaces ?? []) { space in repositoryRow(space) }
                }
                Section("Model") {
                    Picker("Model", selection: $model) {
                        ForEach(options?.models ?? [], id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    Text("\(blocker.map { $0 + " " } ?? "")Each repository gets a fresh worktree on \(target?.name ?? "the host") from the branch you pick; its checkouts are not edited. Context and code go to \(model.isEmpty ? "the selected model's provider" : model).")
                        .shText(.caption).foregroundStyle(Color.sh.textTertiary)
                }
            }
            .navigationTitle("New mission")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Planning…" : "Plan") { create() }.disabled(busy || blocker != nil)
                }
            }
            .task(id: target?.id) { await load() }
        }
    }

    private func repositoryRow(_ space: Space) -> some View {
        let on = spaces.contains(space.id)
        let choices = options?.branchChoices[space.id] ?? []
        return VStack(alignment: .leading, spacing: SH.Space.s) {
            Toggle(isOn: Binding(get: { on }, set: { value in
                if value { spaces.append(space.id) } else { spaces.removeAll { $0 == space.id } }
            })) { Text(space.name).shText(.mono) }
            if on {
                Picker("Start from", selection: Binding(get: { branches[space.id] ?? "" }, set: { branches[space.id] = $0 })) {
                    if branches[space.id] == nil { Text("Choose a branch").tag("") }
                    ForEach(choices, id: \.self) { Text(Self.label($0)).tag($0) }
                }
            }
        }
    }

    /// "main" from "refs/heads/main"; full refs stay what is sent.
    static func label(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/"] where ref.hasPrefix(prefix) { return String(ref.dropFirst(prefix.count)) }
        return ref
    }

    private func reset() { spaces = []; branches = [:]; model = "" }

    private func load() async {
        guard let missions = target?.missions else { return }
        do {
            try await missions.loadStartOptions()
            guard let options = missions.startOptions else { return }
            if model.isEmpty { model = options.defaultModel.flatMap { options.models.contains($0) ? $0 : nil } ?? options.models.first ?? "" }
            for (space, branch) in options.defaultBranches where branches[space] == nil && options.branchChoices[space]?.contains(branch) == true {
                branches[space] = branch
            }
            if spaces.isEmpty, options.spaces.count == 1 { spaces = options.spaces.map(\.id) }
        } catch { failure = RemoteMissions.describe(error) }
    }

    private func create() {
        guard blocker == nil, !busy, let target else { return }
        busy = true
        failure = nil
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines), spaces = spaces, model = model
        let branches = branches.filter { spaces.contains($0.key) }
        Task { @MainActor in
            defer { busy = false }
            do {
                let id = try await target.missions.create(goal: goal, spaces: spaces, model: model, branches: branches)
                dismiss()
                MissionsHooks.open(host: target.id, mission: id, navigator: navigator)
            } catch { failure = RemoteMissions.describe(error) }
        }
    }
}
