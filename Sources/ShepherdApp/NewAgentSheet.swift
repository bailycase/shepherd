import SwiftUI
import AppKit
import ShepherdCore
import ShepherdSessions
import ShepherdRemote

/// Model input: free text with a live filtered dropdown over pi's catalog
/// (900+ ids — a plain Picker menu is unusable). Typing filters by fuzzy
/// subsequence; clicking a row fills the field. Empty text = pi's default.
private struct ModelField: View {
    @Binding var model: String
    let options: [String]
    @State private var showSuggestions = false
    @FocusState private var focused: Bool

    private var matches: [String] {
        let query = model.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Array(options.prefix(12)) }
        // Exact-prefix and substring first, then scattered subsequence.
        return options
            .compactMap { id -> (String, Int)? in
                PaletteSearch.rank(query: query, in: id).map { (id, $0) }
            }
            .sorted { $0.1 < $1.1 }
            .prefix(12)
            .map(\.0)
    }

    var body: some View {
        TextField("", text: $model, prompt: Text("pi default").foregroundStyle(Tokens.textDim))
            .textFieldStyle(.plain)
            .font(Fonts.mono(11.5))
            .foregroundStyle(Tokens.textSecondary)
            .focused($focused)
            .onChange(of: focused) { showSuggestions = focused && !options.isEmpty }
            .onChange(of: model) { if focused { showSuggestions = !options.isEmpty } }
            .popover(isPresented: $showSuggestions, arrowEdge: .bottom) {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches, id: \.self) { id in
                            ModelSuggestionRow(id: id) {
                                model = id
                                showSuggestions = false
                            }
                        }
                        if matches.isEmpty {
                            Text("no matching models")
                                .font(Fonts.mono(10.5))
                                .foregroundStyle(Tokens.textDim)
                                .padding(8)
                        }
                    }
                }
                .frame(width: 380, height: min(CGFloat(max(matches.count, 1)) * 26 + 8, 220))
                .background(Tokens.paletteBg)
            }
    }
}

private struct ModelSuggestionRow: View {
    let id: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(id)
            .font(Fonts.mono(11))
            .foregroundStyle(hovering ? Tokens.textPrimary : Tokens.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Tokens.rowHover : Color.clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}

/// Quiet inline action ("add space…", "choose…") styled like palette rows
/// rather than a bordered AppKit button.
struct SheetLinkButton: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(label)
            .font(Fonts.mono(11))
            .foregroundStyle(hovering ? Tokens.textPrimary : Tokens.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(hovering ? Tokens.rowHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}

struct NewAgentSheet: View {
    var vm: ShepherdViewModel

    /// nil = this Mac; a host id = create on that remote host.
    @State private var targetHostID: UUID?
    @State private var spaceID: SpaceID?
    @State private var workingDirectory = ""
    @State private var model = ""
    @State private var modelOptions: [String] = []
    @State private var thinking: ThinkingLevel = AppSettings.shared.defaultThinking
    @State private var initialPrompt = ""
    @State private var worktree = false
    @State private var worktreeBranch = ""
    @State private var sessionCaption = "…"
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

    private var canStart: Bool {
        !starting && spaceID != nil
            && (!worktree || !worktreeBranch.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Connected hosts only — an unreachable host cannot create anything.
    private var connectedHosts: [RemoteHostStore.Connection] {
        vm.remoteHosts.connections.filter { $0.phase == .connected }
    }

    private func addSpaceInline() {
        remotePicking = .space
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("New Agent")
                    .font(Fonts.mono(13.5, .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                Text("Starts a Pi process in an app-owned PTY that stops when Shepherd quits. Pi names the agent from your first prompt.")
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(Tokens.textSecondary)
            }
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 6, trailing: 20))

            VStack(spacing: 0) {
                if !connectedHosts.isEmpty {
                    SheetRow("host") {
                        Picker("", selection: $targetHostID) {
                            Text("this mac").tag(UUID?.none)
                            ForEach(connectedHosts) { connection in
                                Text("⌁ \(connection.config.name)").tag(Optional(connection.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                    }
                }

                SheetRow("space") {
                    HStack(spacing: 8) {
                        if targetSpaces.isEmpty {
                            Text("no spaces yet")
                                .font(Fonts.mono(11.5))
                                .foregroundStyle(Tokens.textTertiary)
                        } else {
                            Picker("", selection: $spaceID) {
                                ForEach(targetSpaces) { space in
                                    Text(space.name).tag(Optional(space.id))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 180)
                        }
                        Spacer(minLength: 0)
                        SheetLinkButton(label: "add space…") { addSpaceInline() }
                    }
                }

                SheetRow("directory") {
                    HStack(spacing: 8) {
                        TextField("", text: $workingDirectory)
                            .textFieldStyle(.plain)
                            .font(Fonts.mono(11.5))
                            .foregroundStyle(Tokens.textSecondary)
                        SheetLinkButton(label: "choose…") { remotePicking = .cwd }
                    }
                }

                // Local git checkouts offer an isolated worktree: the agent
                // then works on its own branch in a sibling directory instead
                // of the shared checkout. Remote hosts: not supported (git
                // runs on this Mac).
                if targetHostID == nil, GitWorktree.isRepo(workingDirectory) {
                    SheetRow("worktree") {
                        HStack(spacing: 8) {
                            Toggle("", isOn: $worktree)
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                            if worktree {
                                TextField("", text: $worktreeBranch,
                                          prompt: Text("branch name").foregroundStyle(Tokens.textDim))
                                    .textFieldStyle(.plain)
                                    .font(Fonts.mono(11.5))
                                    .foregroundStyle(Tokens.textSecondary)
                            } else {
                                Text("isolate the agent on its own branch")
                                    .font(Fonts.mono(11))
                                    .foregroundStyle(Tokens.textDim)
                            }
                        }
                    }
                }

                SheetRow("model") {
                    ModelField(model: $model, options: modelOptions)
                }

                SheetRow("thinking") {
                    Picker("", selection: $thinking) {
                        ForEach(ThinkingLevel.allCases, id: \.self) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)
                }

                // Prompt: full-width editor under its label, no row chrome —
                // this is the field you actually type into.
                VStack(alignment: .leading, spacing: 6) {
                    Text("prompt")
                        .font(Fonts.mono(10.5, .semibold))
                        .tracking(0.74)
                        .foregroundStyle(Tokens.textDim)
                    TextEditor(text: $initialPrompt)
                        .focused($promptFocused)
                        .font(Fonts.mono(11.5))
                        .foregroundStyle(Tokens.textPrimary)
                        .frame(height: 84)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color.black.opacity(0.25))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(promptFocused ? Tokens.focusAccent.opacity(0.4) : Tokens.chipBorder, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .padding(EdgeInsets(top: 12, leading: 20, bottom: 4, trailing: 20))
            }
            .padding(.top, 6)

            HStack(spacing: 10) {
                Text(errorText ?? sessionCaption)
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(errorText == nil ? Tokens.textTertiary : Tokens.statusBlocked)
                    .lineLimit(2)
                Spacer(minLength: 12)
                Button("Cancel") { vm.showNewAgentSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button(starting ? "Starting…" : "Start Agent") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.accentButton)
                    .disabled(!canStart)
            }
            .padding(EdgeInsets(top: 4, leading: 20, bottom: 16, trailing: 20))
        }
        .frame(width: 560)
        .background(Tokens.workspaceBg)
        .onAppear {
            if let preselect = vm.newAgentPreselect {
                // Opened from a remote space header's `+`.
                vm.newAgentPreselect = nil
                targetHostID = preselect.hostID
                spaceID = preselect.spaceID
            } else {
                spaceID = vm.selectedSpaceID ?? vm.visibleSpaces.first?.id
            }
            workingDirectory = selectedSpace?.path ?? ""
            thinking = AppSettings.shared.defaultThinking
            loadModels()
            promptFocused = true
        }
        .onChange(of: spaceID) {
            workingDirectory = selectedSpace?.path ?? ""
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
        .task {
            sessionCaption = await vm.sessionCaption()
        }
        .sheet(item: $remotePicking) { target in
            // One picker for both machines: the listing source is the only
            // difference between browsing this Mac and browsing the host.
            let connection = remoteConnection
            RemoteDirectoryPicker(
                hostName: connection?.config.name ?? "this mac",
                // cwd browsing starts where the field points; space browsing
                // starts at home.
                startPath: target == .cwd ? workingDirectory : "",
                list: { path in
                    if let connection {
                        return try await vm.remoteHosts.listDir(hostID: connection.id, path: path)
                    }
                    return try LocalDirectoryLister.list(path: path)
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
        if let connection = remoteConnection {
            modelOptions = []
            model = ""
            let hostID = connection.id
            Task {
                do {
                    let listing = try await vm.remoteHosts.listModels(hostID: hostID)
                    guard targetHostID == hostID else { return }
                    modelOptions = listing.models
                    model = listing.defaultModel ?? ""
                } catch {
                    // Field degrades to free text.
                }
            }
            return
        }
        // Shepherd's own default wins over pi's when the user set one.
        model = AppSettings.shared.agentDefaults.model ?? PiConfig.defaultModel() ?? ""
        Task {
            let ids = await Task.detached(priority: .userInitiated) {
                PiModelCatalog.modelIDs()
            }.value
            guard targetHostID == nil else { return }
            modelOptions = ids
        }
    }

    private func start() {
        guard canStart, let spaceID else { return }
        starting = true
        errorText = nil
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let prompt = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = workingDirectory.isEmpty ? (selectedSpace?.path ?? "~") : workingDirectory

        // Worktree first: resolve the base per Settings ▸ Worktrees (may
        // fetch — off-main) and branch from it explicitly. A failure (branch
        // exists, bad base) surfaces in the sheet before any agent exists.
        if targetHostID == nil, worktree {
            let repo = cwd
            let branchName = worktreeBranch.trimmingCharacters(in: .whitespaces)
            let mode = AppSettings.shared.worktreeBaseMode
            let fetchFirst = AppSettings.shared.worktreeFetchBeforeCreate
            Task {
                do {
                    let (path, baseUsed) = try await Task.detached(priority: .userInitiated) { () -> (String, String) in
                        let resolution = GitWorktree.resolveBase(repo: repo, mode: mode, fetchFirst: fetchFirst)
                        let path = try GitWorktree.add(repo: repo, branch: branchName, from: resolution.startPoint)
                        return (path, resolution.display)
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
                        thinking: thinking,
                        initialPrompt: prompt.isEmpty ? nil : prompt
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
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let prompt = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = NewAgentConfig(
            spaceID: spaceID,
            workingDirectory: cwd,
            model: trimmedModel.isEmpty ? nil : trimmedModel,
            thinking: thinking,
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
