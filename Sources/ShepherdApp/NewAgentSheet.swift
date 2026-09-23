import SwiftUI
import ShepherdUI
import AppKit
import ShepherdCore
import ShepherdSessions
import ShepherdRemote
import ShepherdProtocol

/// Model input: free text with a live filtered dropdown over pi's catalog
/// (900+ ids — a plain Picker menu is unusable). Typing filters by fuzzy
/// subsequence; clicking a row fills the field. Empty text = pi's default.
private struct ModelField: View {
    @Binding var model: String
    let options: [String]
    @State private var showSuggestions = false
    /// Ranked once per keystroke, never in `body`.
    @State private var matches: [String] = []
    @FocusState private var focused: Bool

    private static func rank(_ query: String, in options: [String]) -> [String] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Array(options.prefix(AppLayout.modelSuggestionsVisible)) }
        // Exact-prefix and substring first, then scattered subsequence.
        return options
            .compactMap { id -> (String, Int)? in
                PaletteSearch.rank(query: query, in: id).map { (id, $0) }
            }
            .sorted { $0.1 < $1.1 }
            .prefix(AppLayout.modelSuggestionsVisible)
            .map(\.0)
    }

    var body: some View {
        TextField("Model", text: $model, prompt: Text("pi's default").foregroundStyle(Color.nw.textTertiary))
            .focused($focused)
            .nwField(focused: focused, mono: true)
            .onChange(of: focused) { showSuggestions = focused && !options.isEmpty }
            .onChange(of: model) { if focused { showSuggestions = !options.isEmpty } }
            .onChange(of: model, initial: true) { matches = Self.rank(model, in: options) }
            .onChange(of: options) { matches = Self.rank(model, in: options) }
            .popover(isPresented: $showSuggestions, arrowEdge: .bottom) {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches, id: \.self) { id in
                            ModelSuggestionRow(id: id) {
                                model = id
                                showSuggestions = false
                            }
                        }
                        if matches.isEmpty {
                            Text("No matching models")
                                .font(.nw(.caption))
                                .foregroundStyle(Color.nw.textTertiary)
                                .padding(NW.Space.m)
                        }
                    }
                    .padding(NW.Space.s)
                }
                .scrollIndicators(.hidden)
                .frame(width: AppLayout.modelPickerWidth,
                       height: min(CGFloat(max(matches.count, 1)) * NW.Height.row + 2 * NW.Space.s, AppLayout.modelSuggestionsMaxHeight))
                .background(Color.nw.bgRaised)
            }
    }
}

/// A suggestion in the model popover (the Composer board's menu row): 28pt, mono id.
private struct ModelSuggestionRow: View {
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(id)
                .font(.nw(.code))
                .foregroundStyle(Color.nw.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, NW.Space.m)
                .frame(maxWidth: .infinity, minHeight: NW.Height.row, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.nwRow())
    }
}

/// Quiet inline action in a sheet row ("Add space…", "Choose…"): a ghost button.
struct SheetLinkButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(label, action: action).buttonStyle(.nw(.ghost, size: .s))
    }
}

struct NewAgentBaseTarget: Hashable {
    var hostID: UUID?
    var spaceID: SpaceID?
    var cwd: String
    var worktree: Bool
}

struct NewAgentTargetDefaults {
    private(set) var requestID = UUID()
    private(set) var hostID: UUID?
    private(set) var loading = false
    private(set) var ready = false
    var model = ""
    var thinking: ThinkingLevel = .medium
    var modelEdited = false
    var thinkingEdited = false

    mutating func begin(hostID: UUID?, model: String, thinking: ThinkingLevel) -> UUID {
        let sameTarget = self.hostID == hostID && !ready
        requestID = UUID()
        self.hostID = hostID
        if !sameTarget || !modelEdited { self.model = model; modelEdited = false }
        if !sameTarget || !thinkingEdited { self.thinking = thinking; thinkingEdited = false }
        loading = hostID != nil
        ready = hostID == nil
        return requestID
    }

    mutating func apply(requestID: UUID, model: String, thinking: ThinkingLevel) {
        guard self.requestID == requestID else { return }
        if !modelEdited { self.model = model }
        if !thinkingEdited { self.thinking = thinking }
        loading = false
        ready = true
    }

    mutating func fail(requestID: UUID) {
        guard self.requestID == requestID else { return }
        loading = false
        ready = false
    }
}

struct NewAgentSheet: View {
    var vm: ShepherdViewModel

    /// nil = this Mac; a host id = create on that remote host.
    @State private var targetHostID: UUID?
    @State private var spaceID: SpaceID?
    @State private var workingDirectory = ""
    @State private var defaults = NewAgentTargetDefaults()
    @State private var modelOptions: [String] = []
    @State private var initialPrompt = ""
    @State private var worktree = false
    @State private var worktreeBranch = ""
    @State private var worktreeBase = ""
    @State private var fetchFirst = false
    @State private var baseNote = ""
    @State private var resolvingBase = false
    @State private var baseResolved = false
    @State private var baseRequestID = UUID()
    @State private var resolvedBaseTarget: NewAgentBaseTarget?
    @State private var sessionCaption = "…"
    /// Whether the directory is a git checkout (worktree row), probed off the main thread.
    @State private var isRepo = false
    @State private var errorText: String?
    @State private var starting = false
    /// Remote directory browser target: adding a space or picking a cwd.
    @State private var remotePicking: RemotePickTarget?
    @FocusState private var promptFocused: Bool

    private enum RemotePickTarget: String, Identifiable {
        case space, cwd
        var id: String { rawValue }
    }

    private var remoteConnection: RemoteHostStore.Connection? {
        targetHostID.flatMap { id in vm.remoteHosts.connections.first { $0.id == id } }
    }

    /// Spaces on whichever machine is targeted.
    private var targetSpaces: [Space] {
        remoteConnection?.state.spaces ?? vm.visibleSpaces
    }

    private var selectedSpace: Space? {
        targetSpaces.first { $0.id == spaceID }
    }

    private var baseTarget: NewAgentBaseTarget {
        NewAgentBaseTarget(hostID: targetHostID, spaceID: spaceID, cwd: workingDirectory, worktree: worktree)
    }

    private var canStart: Bool {
        !starting && spaceID != nil && defaults.ready && !defaults.loading && defaults.hostID == targetHostID
            && (!worktree || (!worktreeBranch.trimmingCharacters(in: .whitespaces).isEmpty && baseResolved && resolvedBaseTarget == baseTarget && !resolvingBase))
    }

    /// Connected hosts only — an unreachable host cannot create anything.
    private var connectedHosts: [RemoteHostStore.Connection] {
        vm.remoteHosts.connections.filter { $0.phase == .connected }
    }

    private func addSpaceInline() {
        remotePicking = .space
    }

    var body: some View {
        NWDialog("New agent",
                 message: "Starts pi as a native thread that runs until Shepherd quits. Pi names the agent from your first prompt.",
                 width: AppLayout.newAgentSheetWidth) {
            if !connectedHosts.isEmpty {
                SheetRow("Machine") {
                    NWPopupMenu(remoteConnection?.config.name ?? "This Mac", minWidth: AppLayout.settingsPopupWidth) {
                        Button("This Mac") { targetHostID = nil }
                        ForEach(connectedHosts) { connection in
                            Button(connection.config.name) { targetHostID = connection.id }
                        }
                    }
                    .accessibilityLabel("Machine")
                }
            }

            SheetRow("Space") {
                HStack(spacing: NW.Space.m) {
                    if targetSpaces.isEmpty {
                        Text("No spaces yet")
                            .font(.nw(.ui))
                            .foregroundStyle(Color.nw.textSecondary)
                    } else {
                        NWPopupMenu(selectedSpace?.name ?? "Choose a space", minWidth: AppLayout.settingsPopupWidth) {
                            ForEach(targetSpaces) { space in
                                Button(space.name) { spaceID = space.id }
                            }
                        }
                        .accessibilityLabel("Space")
                    }
                    Spacer(minLength: 0)
                    SheetLinkButton(label: "Add space…") { addSpaceInline() }
                }
            }

            SheetRow("Directory") {
                HStack(spacing: NW.Space.m) {
                    TextField("Directory", text: $workingDirectory)
                        .textFieldStyle(.nw(mono: true))
                    SheetLinkButton(label: "Choose…") { remotePicking = .cwd }
                        .accessibilityLabel("Choose directory")
                }
            }

            // Repository probes and worktree creation run on the chosen machine.
            if targetHostID != nil || isRepo {
                SheetRow("Worktree") {
                    HStack(spacing: NW.Space.m) {
                        Toggle("Worktree", isOn: $worktree)
                            .toggleStyle(.nwSwitch)
                            .labelsHidden()
                            .disabled(targetHostID != nil && remoteConnection?.supportsWorktreeCreation != true)
                        if worktree {
                            TextField("Worktree branch", text: $worktreeBranch,
                                      prompt: Text("branch name").foregroundStyle(Color.nw.textTertiary))
                                .textFieldStyle(.nw(mono: true))
                        } else {
                            Text("Isolate the agent on its own branch")
                                .font(.nw(.caption))
                                .foregroundStyle(Color.nw.textSecondary)
                        }
                    }
                }
            }

            if worktree {
                SheetRow("Base", alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: NW.Space.xs) {
                        TextField("Base branch", text: $worktreeBase,
                                  prompt: Text("base branch").foregroundStyle(Color.nw.textTertiary))
                            .textFieldStyle(.nw(mono: true))
                        Text(resolvingBase ? "Resolving on the target…" : baseNote)
                            .font(.nw(.caption))
                            .foregroundStyle(Color.nw.textTertiary)
                    }
                }
                SheetRow("Fetch") {
                    HStack(spacing: NW.Space.m) {
                        Toggle("Fetch origin before creating", isOn: $fetchFirst).toggleStyle(.nwSwitch).labelsHidden()
                        Text("Fetch origin before creating")
                            .font(.nw(.caption))
                            .foregroundStyle(Color.nw.textSecondary)
                            .accessibilityHidden(true)
                        Spacer(minLength: 0)
                        SheetLinkButton(label: "Resolve base…") { Task { await resolveBase(fetch: fetchFirst) } }
                    }
                }
            }

            SheetRow("Model") {
                ModelField(model: Binding(get: { defaults.model }, set: { defaults.model = $0; defaults.modelEdited = true }), options: modelOptions)
            }

            SheetRow("Thinking") {
                NWSegmentedPicker("Thinking", selection: Binding(get: { defaults.thinking }, set: { defaults.thinking = $0; defaults.thinkingEdited = true }),
                                  options: ThinkingLevel.allCases.map { ($0, $0.rawValue.capitalized) })
            }

            // Prompt: full-width editor under its label, no row chrome — this is the field
            // you actually type into.
            VStack(alignment: .leading, spacing: NW.Space.s) {
                Text("Prompt")
                    .font(.nw(.ui))
                    .foregroundStyle(Color.nw.textSecondary)
                    .accessibilityHidden(true)
                TextEditor(text: $initialPrompt)
                    .focused($promptFocused)
                    .nwText(.body)
                    .foregroundStyle(Color.nw.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(height: AppLayout.promptEditorHeight)
                    .padding(NW.Space.m)
                    .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.s))
                    .overlay { RoundedRectangle(cornerRadius: NW.Radius.s).strokeBorder(Color.nw.lineStrong, lineWidth: 1) }
                    .nwFocusRing(promptFocused, radius: NW.Radius.s)
                    .accessibilityLabel("Prompt")
            }
            .padding(EdgeInsets(top: NW.Space.l, leading: NWDialogMetrics.inset, bottom: 0, trailing: NWDialogMetrics.inset))
        } status: {
            if !defaults.ready && !defaults.loading {
                Button("Retry defaults") { loadModels() }.buttonStyle(.nw(.secondary, size: .s))
            }
            NWDialogStatus(errorText ?? (defaults.loading ? "Loading host defaults…" : sessionCaption), isError: errorText != nil)
        } actions: {
            Button("Cancel") { vm.showNewAgentSheet = false }
                .buttonStyle(.nw(.secondary))
                .keyboardShortcut(.cancelAction)
            Button(starting ? "Starting…" : "Start agent") { start() }
                .buttonStyle(.nw(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
        }
        .onAppear {
            if let preselect = vm.newAgentPreselect {
                // Opened from a remote space header's `+`.
                vm.newAgentPreselect = nil
                targetHostID = preselect.hostID
                spaceID = preselect.spaceID
            } else if let remote = vm.selectedRemoteAgent, let agent = vm.remoteAgent(remote) {
                targetHostID = remote.hostID
                spaceID = agent.spaceID
            } else {
                spaceID = vm.selectedSpaceID ?? vm.visibleSpaces.first?.id
            }
            workingDirectory = selectedSpace?.path ?? ""
            loadModels()
            promptFocused = true
        }
        .task(id: baseTarget) {
            baseRequestID = UUID()
            worktreeBase = ""
            fetchFirst = false
            baseNote = ""
            baseResolved = false
            resolvedBaseTarget = nil
            resolvingBase = false
            if worktree {
                if worktreeBranch.isEmpty { worktreeBranch = GitWorktree.generatedBranch() }
                await resolveBase(fetch: nil)
            }
        }
        .onChange(of: spaceID) {
            workingDirectory = selectedSpace?.path ?? ""
            if !defaults.ready && !defaults.loading { loadModels() }
        }
        .onChange(of: targetHostID) {
            // Switching machines invalidates the space selection wholesale
            // (unless the current selection already belongs to the new
            // target — the remote `+` preselects both together).
            if !targetSpaces.contains(where: { $0.id == spaceID }) {
                spaceID = targetSpaces.first?.id
            }
            workingDirectory = selectedSpace?.path ?? ""
            errorText = nil
            loadModels()
        }
        .task(id: targetHostID) {
            sessionCaption = targetHostID == nil ? await vm.sessionCaption() : "The agent runs on the host."
        }
        .task(id: workingDirectory) {
            let directory = workingDirectory
            isRepo = await Task.detached(priority: .userInitiated) { GitWorktree.isRepo(directory) }.value
        }
        .sheet(item: $remotePicking) { target in
            // One picker for both machines: the listing source is the only
            // difference between browsing this Mac and browsing the host.
            let connection = remoteConnection
            RemoteDirectoryPicker(
                hostName: connection?.config.name ?? "this Mac",
                // cwd browsing starts where the field points; space browsing
                // starts at home.
                startPath: target == .cwd ? workingDirectory : "",
                list: { path in
                    if let connection {
                        return try await vm.remoteHosts.listDir(hostID: connection.id, path: path)
                    }
                    return try await LocalDirectoryLister.load(path: path)
                },
                choose: { path in
                    remotePicking = nil
                    switch target {
                    case .cwd:
                        workingDirectory = path
                    case .space:
                        Task {
                            if let connection {
                                do {
                                    spaceID = try await vm.addRemoteSpace(hostID: connection.id, path: path)
                                } catch {
                                    errorText = "\(error)"
                                }
                            } else if let id = await vm.addSpace(at: URL(fileURLWithPath: path), createInitialAgent: false) {
                                spaceID = id
                            }
                        }
                    }
                },
                cancel: { remotePicking = nil }
            )
        }
    }

    /// Model options come from pi on whichever machine will run it: the
    /// local catalog (`pi --list-models`, cached per app run), or the host's
    /// via listModels. The field pre-fills with the default; typing filters.
    private func loadModels() {
        let hostID = targetHostID
        let requestID = defaults.begin(hostID: hostID,
                                       model: hostID == nil ? vm.settings.agentDefaults.model ?? PiConfig.defaultModel() ?? "" : "",
                                       thinking: hostID == nil ? vm.settings.defaultThinking : .medium)
        modelOptions = []
        errorText = nil
        if hostID != nil && remoteConnection?.supportsWorktreeCreation != true { worktree = false }
        if let hostID {
            let targetSpace = spaceID
            Task {
                do {
                    guard let targetSpace else { throw RemoteHostClientError.rejected(code: "no_space", message: "Choose a host space before loading defaults") }
                    let result = try await vm.remoteHosts.creationOptions(hostID: hostID, spaceID: targetSpace, cwd: nil, fetchFirst: nil)
                    guard defaults.requestID == requestID, targetHostID == hostID else { return }
                    defaults.apply(requestID: requestID, model: result.model ?? "", thinking: result.thinking)
                    // A catalog failure leaves the editable defaults usable.
                    if let listing = try? await vm.remoteHosts.listModels(hostID: hostID), defaults.requestID == requestID {
                        modelOptions = listing.models
                    }
                } catch {
                    guard defaults.requestID == requestID else { return }
                    defaults.fail(requestID: requestID)
                    errorText = String(describing: error)
                }
            }
            return
        }
        Task {
            let ids = await Task.detached(priority: .userInitiated) { PiModelCatalog.modelIDs() }.value
            guard defaults.requestID == requestID else { return }
            modelOptions = ids
        }
    }

    private func resolveBase(fetch: Bool?) async {
        guard let spaceID else { return }
        let requestID = UUID()
        baseRequestID = requestID
        let hostID = targetHostID
        let cwd = workingDirectory
        let requestedTarget = baseTarget
        resolvingBase = true
        baseResolved = false
        do {
            let base: String
            let note: String
            let resolvedFetch: Bool
            if let hostID {
                let result = try await vm.remoteHosts.creationOptions(hostID: hostID, spaceID: spaceID, cwd: cwd, fetchFirst: fetch)
                base = result.base; note = result.note; resolvedFetch = result.fetchFirst
            } else {
                let mode = vm.settings.worktreeBaseMode
                resolvedFetch = fetch ?? vm.settings.worktreeFetchBeforeCreate
                let result = await Task.detached { GitWorktree.resolveBase(repo: cwd, mode: mode, fetchFirst: resolvedFetch) }.value
                base = result.display; note = result.note
            }
            guard baseRequestID == requestID, targetHostID == hostID, workingDirectory == cwd, self.spaceID == spaceID else { return }
            worktreeBase = base
            baseNote = note
            fetchFirst = resolvedFetch
            baseResolved = true
            resolvedBaseTarget = requestedTarget
            resolvingBase = false
        } catch {
            guard baseRequestID == requestID, targetHostID == hostID, workingDirectory == cwd else { return }
            errorText = String(describing: error)
            resolvingBase = false
        }
    }

    private func start() {
        guard canStart, let spaceID else { return }
        starting = true
        errorText = nil
        let trimmedModel = defaults.model.trimmingCharacters(in: .whitespaces)
        let prompt = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = workingDirectory.isEmpty ? (selectedSpace?.path ?? "~") : workingDirectory

        // Worktree first: resolve the base per Settings ▸ Worktrees (may
        // fetch — off-main) and branch from it explicitly. A failure (branch
        // exists, bad base) surfaces in the sheet before any agent exists.
        if targetHostID == nil, worktree {
            let repo = cwd
            let branchName = worktreeBranch.trimmingCharacters(in: .whitespaces)
            let mode = AppSettings.shared.worktreeBaseMode
            let fetchFirst = fetchFirst
            let explicitBase = worktreeBase.trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                do {
                    let (path, baseUsed) = try await Task.detached(priority: .userInitiated) { () -> (String, String) in
                        let resolution = GitWorktree.resolveBase(repo: repo, mode: mode, fetchFirst: fetchFirst)
                        let path = try GitWorktree.add(repo: repo, branch: branchName, from: explicitBase.isEmpty ? resolution.startPoint : explicitBase)
                        return (path, explicitBase.isEmpty ? resolution.display : explicitBase)
                    }.value
                    startLocalAgent(cwd: path, worktreeBranch: branchName, worktreeBase: baseUsed)
                } catch {
                    errorText = error.localizedDescription
                    starting = false
                }
            }
            return
        }

        if let connection = remoteConnection {
            Task {
                do {
                    try await vm.createRemoteAgent(
                        hostID: connection.id,
                        spaceID: spaceID,
                        cwd: cwd,
                        model: trimmedModel.isEmpty ? nil : trimmedModel,
                        thinking: defaults.thinking,
                        initialPrompt: prompt.isEmpty ? nil : prompt,
                        worktreeBranch: worktree ? worktreeBranch.trimmingCharacters(in: .whitespaces) : nil,
                        worktreeBase: worktree ? worktreeBase : nil,
                        worktreeFetchFirst: worktree ? fetchFirst : nil
                    )
                    vm.showNewAgentSheet = false
                } catch {
                    errorText = "\(error)"
                    starting = false
                }
            }
            return
        }

        startLocalAgent(cwd: cwd, worktreeBranch: nil, worktreeBase: nil)
    }

    private func startLocalAgent(cwd: String, worktreeBranch: String?, worktreeBase: String?) {
        guard let spaceID else { return }
        let trimmedModel = defaults.model.trimmingCharacters(in: .whitespaces)
        let prompt = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = NewAgentConfig(
            spaceID: spaceID,
            workingDirectory: cwd,
            model: trimmedModel.isEmpty ? nil : trimmedModel,
            thinking: defaults.thinking,
            initialPrompt: prompt.isEmpty ? nil : prompt,
            worktreeBranch: worktreeBranch,
            worktreeBase: worktreeBase
        )
        Task {
            do {
                try await vm.startAgent(config)
                vm.showNewAgentSheet = false
            } catch {
                errorText = "\(error)"
                starting = false
            }
        }
    }
}
