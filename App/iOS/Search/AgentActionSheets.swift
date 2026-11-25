import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// Rename a thread's agent on its host. Presented modally; Save shows the new name at once and
/// closes; the host takes it in the background, and a refusal puts the old name back with the
/// reason. A manual name is final there: the namer never replaces it.
struct RenameAgentSheet: View {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        let host = hosts.host(ref.host)
        let agent = host?.agent(ref.agent)
        let current = agent?.name ?? ""
        let next = AgentRename.name(name, current: current)
        Form {
            Section {
                TextField("Name", text: $name)
                    .font(.sh(.ui))
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { if next != nil { save(next) } }
                    .accessibilityLabel("Thread name")
            } footer: {
                VStack(alignment: .leading, spacing: SH.Space.xs) {
                    if let error {
                        Text(error).foregroundStyle(Color.sh.failed)
                    }
                    if let host {
                        Text(agent == nil ? "This agent is no longer on \(host.name)." : "On \(host.name). The new name replaces the one the agent chose.")
                    }
                }
                .font(.sh(.caption))
                .foregroundStyle(Color.sh.textTertiary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.sh.bgWindow)
        .navigationTitle("Rename")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { navigator.dismissPresented() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save(next) }.disabled(next == nil || agent == nil)
            }
        }
        // On iPad the sheet is a form fitted to what it holds (MobileRoot); a detent would override it.
        .presentationDetents(navigator.layout == .pad ? [.large] : [.medium, .large])
        .onAppear {
            if name.isEmpty { name = current }
            focused = true
        }
    }

    private func save(_ next: String?) {
        guard let next else { return }
        error = nil
        do {
            // The thread shows the name at once; the host takes it in the background.
            try AgentActions.rename(ref, to: next, hosts: hosts) { [navigator = self.navigator] failure in
                navigator.present(.search(.problem(title: "Couldn’t rename the thread", message: String(describing: failure))))
            }
            navigator.dismissPresented()
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// Delete a thread's agent. A plain agent confirms and is retired on its host; its folder stays.
/// A worktree agent follows the Mac's Delete Worktree Agent: the host describes the checkout and
/// any work that would be lost, which must be acknowledged, and the delete runs on the host as
/// an operation followed in the background (reopening shows its status); "Delete agent only" keeps the checkout and branch.
/// Confirming closes the thread at once; `ThreadClosingFlow` settles the host's answer.
struct DeleteAgentSheet: View {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let host = hosts.host(ref.host)
        let agent = host?.agent(ref.agent)
        let worktree = agent?.worktreeBranch != nil || WorktreeOperations.shared.running[ref] != nil
        Group {
            if worktree {
                DeleteWorktreeAgentForm(ref: ref)
            } else {
                DeleteAgentForm(ref: ref, name: agent?.name, hostName: host?.name)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.sh.bgWindow)
        .navigationBarTitleDisplayMode(.inline)
        // The worktree's confirmation needs the whole height: details, the warning, both deletes.
        .presentationDetents(worktree || navigator.layout == .pad ? [.large] : [.medium, .large])
    }
}

private struct DeleteAgentForm: View {
    let ref: AgentRef
    let name: String?
    let hostName: String?
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Thread") { Text(name ?? "Gone").lineLimit(1) }
                LabeledContent("Host") { Text(hostName ?? "Forgotten") }
            } footer: {
                Text("The agent stops and its thread closes on every device. Its folder and files stay.")
                    .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            }
            if let error {
                Section { Text(error).font(.sh(.caption)).foregroundStyle(Color.sh.failed) }
            }
            Section {
                Button(role: .destructive, action: delete) {
                    Text("Delete agent")
                }
                .disabled(name == nil)
            }
        }
        .font(.sh(.ui))
        .navigationTitle("Delete agent")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { navigator.dismissPresented() }
            }
        }
    }

    /// The confirmation is this button: the thread closes at once and the host's answer follows
    /// (`ThreadClosingFlow`). Only a host that can't be reached keeps the sheet.
    private func delete() {
        error = nil
        let client: RemoteHostClient
        do { client = try AgentActions.client(ref, hosts: hosts) } catch {
            self.error = String(describing: error)
            return
        }
        let ref = ref
        ThreadClosingFlow.close(ref, hosts: hosts, navigator: navigator, title: "Couldn’t delete the agent") {
            try await client.agentAction(agentID: ref.agent, action: .deleteKeepingWorktree)
        }
    }
}

/// The Mac's Delete Worktree Agent sheet, for touch.
private struct DeleteWorktreeAgentForm: View {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @State private var operations = WorktreeOperations.shared
    /// The connection the confirmation was read on: the delete goes only over it.
    @State private var session: UUID?
    @State private var info: RemoteWorktreeInfo?
    @State private var loading = true
    @State private var acknowledged = false
    @State private var submitting = false
    @State private var operation: RemoteWorktreeOperation?
    @State private var error: String?

    var body: some View {
        let host = hosts.host(ref.host)
        let operationID = operations.running[ref]
        let running = operationID != nil
        Form {
            Section {
                LabeledContent("Host") { Text(host?.name ?? "Forgotten") }
                if let info {
                    LabeledContent("Worktree") {
                        Text(info.path).font(.sh(.mono)).lineLimit(1).truncationMode(.middle)
                    }
                    LabeledContent("Branch") { Text(info.branch).font(.sh(.mono)).lineLimit(1) }
                } else if loading && !running {
                    HStack(spacing: SH.Space.m) {
                        Text("Checking the worktree on \(host?.name ?? "the host")…").shShimmer(active: true)
                    }
                }
            }
            if let info, let warning = info.warning, operation == nil, !running {
                Section {
                    SHBanner(.attention, title: "Unreconciled work", message: WorktreeDeletion.lossMessage(warning))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    Toggle("I understand this work will be lost", isOn: $acknowledged)
                }
            }
            if let operation {
                Section("On \(host?.name ?? "the host")") {
                    ForEach(Array(operation.progress.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary)
                    }
                    if let failure = operation.error {
                        Text(failure).font(.sh(.caption)).foregroundStyle(Color.sh.failed)
                    }
                    if operation.finished, operation.error == nil {
                        Label("Agent, checkout and local branch removed", systemImage: "checkmark.circle")
                            .foregroundStyle(Color.sh.done)
                    }
                }
            } else if running {
                Section {
                    HStack(spacing: SH.Space.m) {
                        Text("Deleting on the host. Closing this only stops watching it.").shShimmer(active: true)
                    }
                }
            }
            if let error {
                Section { Text(error).font(.sh(.caption)).foregroundStyle(Color.sh.failed) }
            }
            if !running, operation == nil {
                Section {
                    Button("Delete agent and worktree", role: .destructive) { start() }
                        .disabled(!WorktreeDeletion.canDelete(info, acknowledged: acknowledged, submitting: submitting))
                    Button("Delete agent only") { deleteAgentOnly() }
                        .disabled(submitting || info == nil && loading)
                } footer: {
                    Text("Delete agent only keeps the checkout and its branch. The remote branch is never deleted.")
                        .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
            }
        }
        .font(.sh(.ui))
        .navigationTitle("Delete worktree agent")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { navigator.dismissPresented() }
            }
            if operation?.finished == true {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        operations.finish(ref)
                        navigator.dismissPresented()
                        if operation?.error == nil { navigator.close(thread: ref) }
                    }
                }
            }
        }
        .task {
            session = host?.session
            guard operations.running[ref] == nil else { return }
            await load()
        }
        .task(id: operationID) {
            guard let operationID else { return }
            await watch(operationID)
        }
    }

    /// The client of the connection the confirmation came from; a status check goes over any.
    private func client(anyConnection: Bool = false) throws -> RemoteHostClient {
        guard let host = hosts.host(ref.host), let client = host.connectedClient else {
            throw AgentActions.Failure("The host is offline. Reopen this once it reconnects.")
        }
        guard anyConnection || host.session == session else {
            throw AgentActions.Failure("The connection to \(host.name) changed. Reopen this to check the worktree again.")
        }
        return client
    }

    private func query(_ value: RemoteAgentQuery, anyConnection: Bool = false) async throws -> RemoteAgentResult {
        try await client(anyConnection: anyConnection).agentQuery(agentID: ref.agent, query: value)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            if case .worktreeInfo(let value) = try await query(.worktreeInfo) { info = value }
        } catch {
            self.error = Self.message(error)
        }
    }

    private func start() {
        guard let info, WorktreeDeletion.canDelete(info, acknowledged: acknowledged, submitting: submitting) else { return }
        error = nil
        let client: RemoteHostClient
        do { client = try self.client() } catch {
            self.error = Self.message(error)
            return
        }
        // Confirmed (with the warning shown): the thread closes at once, and the host's operation is followed
        // in the background (`ThreadClosingFlow`); reopening the delete shows its status.
        let (ref, hosts, operations) = (ref, hosts, operations)
        let id = operations.start(ref)
        ThreadClosingFlow.close(ref, hosts: hosts, navigator: navigator, title: "Couldn’t delete the worktree") {
            try await ThreadClosingFlow.deleteWorktree(ref, info: info, operationID: id, client: client, hosts: hosts, operations: operations)
        }
    }

    private func watch(_ id: UUID) async {
        while !Task.isCancelled {
            do {
                if case .worktreeOperation(let status) = try await query(.worktreeStatus(operationID: id), anyConnection: true) {
                    operation = status
                    error = nil
                    if status.finished { return }
                }
            } catch {
                self.error = "Outcome not yet known: \(Self.message(error)). Don’t delete again."
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func deleteAgentOnly() {
        error = nil
        let client: RemoteHostClient
        do { client = try self.client() } catch {
            self.error = Self.message(error)
            return
        }
        let ref = ref
        ThreadClosingFlow.close(ref, hosts: hosts, navigator: navigator, title: "Couldn’t delete the agent") {
            _ = try await client.agentQuery(agentID: ref.agent, query: .deleteKeepingWorktree)
        }
    }

    private static func message(_ error: Error) -> String {
        if case RemoteHostClientError.rejected(_, let message) = error { return message }
        return String(describing: error)
    }
}

/// An action that failed where nothing was on screen to say so (a menu, the palette).
struct ActionProblemSheet: View {
    let title: String
    let message: String
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        SHEmptyState(Text(title), message: message, showsMark: false) {
            Button("OK") { navigator.dismissPresented() }
                .buttonStyle(.sh(.secondary, size: .l))
                .shTouchTarget(height: SH.Height.controlL)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sh.bgWindow)
        .presentationDetents(navigator.layout == .pad ? [.large] : [.medium])
    }
}

/// Move to Mac: the Macs of the thread's host's fleet with their room and a note, as the Mac's header menu lists them. A pick while a turn runs
/// asks what to do with it (stop and move, or move when it's done). The host does the move; the thread then runs on the other Mac and shows
/// under it.
struct MoveToMacSheet: View {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @State private var menu: FleetMoveMenu?
    @State private var phase = Phase.loading
    @State private var asking: FleetMoveMenu.Target?
    @State private var moving = false
    @State private var error: String?

    private enum Phase { case loading, loaded, unavailable(String) }

    var body: some View {
        let host = hosts.host(ref.host)
        let agent = host?.agent(ref.agent)
        let working = agent?.status == .working || agent?.status == .blocked
        Form {
            switch phase {
            case .loading:
                Section { Text("Reading the fleet…").font(.sh(.ui)).shShimmer(active: true) }
            case .unavailable(let why):
                Section { Text(why).font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary) }
            case .loaded:
                if let menu {
                    Section("Runs on") {
                        LabeledContent(menu.here.name) { Text(menu.here.detail).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary) }
                    }
                    Section {
                        ForEach(menu.targets) { target in
                            Button { pick(target, working: working) } label: {
                                HStack(spacing: SH.Space.m) {
                                    VStack(alignment: .leading, spacing: SH.Space.xxs) {
                                        Text(target.name).font(.sh(.ui)).foregroundStyle(target.enabled ? Color.sh.textPrimary : Color.sh.textTertiary)
                                        Text(target.note).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                                    }
                                    Spacer(minLength: 0)
                                    ProgressView(value: target.room).frame(width: SH.Height.touch)
                                        .tint(Color.sh.done).accessibilityHidden(true)
                                }
                            }
                            .disabled(!target.enabled || moving)
                            .accessibilityLabel(target.accessibilityLabel)
                        }
                    } header: {
                        Text("Move to")
                    } footer: {
                        Text(FleetMoveMenu.footnote).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    }
                }
            }
            if let error {
                Section { Text(error).font(.sh(.caption)).foregroundStyle(Color.sh.failed) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.sh.bgWindow)
        .navigationTitle("Move to Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { navigator.dismissPresented() } } }
        .presentationDetents(navigator.layout == .pad ? [.large] : [.medium, .large])
        .confirmationDialog(asking.map { _ in "It’s working" } ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible, presenting: asking) { target in
            Button("Stop and move") { move(target, .now) }
            Button("Move when it’s done") { move(target, .whenDone) }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(FleetMoveConfirm.make(running: nil, host: target.name).message)
        }
        .task { await load() }
    }

    private func load() async {
        guard let host = hosts.host(ref.host), let client = host.connectedClient, let agent = host.agent(ref.agent) else {
            phase = .unavailable("This thread’s host isn’t connected.")
            return
        }
        do {
            let snapshot = try await client.fleetRead().snapshot
            let space = host.state.spaces.first { $0.id == agent.spaceID }
            guard let here = snapshot.hostID,
                  let made = FleetMoveMenu.make(snapshot: snapshot, currentHostID: here, repoKey: space?.repoKey, repoName: space?.name ?? "this folder",
                                                weight: { _ in .normal }) else {
                phase = .unavailable("\(host.name) has no other Mac in its fleet to move this thread to.")
                return
            }
            menu = made
            phase = .loaded
        } catch {
            phase = .unavailable(String(describing: error))
        }
    }

    private func pick(_ target: FleetMoveMenu.Target, working: Bool) {
        if working { asking = target } else { move(target, .now) }
    }

    private func move(_ target: FleetMoveMenu.Target, _ when: FleetMoveRequest.When) {
        guard !moving else { return }
        moving = true
        error = nil
        let (ref, hosts) = (ref, hosts)
        Task {
            do {
                try await AgentActions.moveToMac(ref, FleetMoveRequest(agentID: ref.agent, host: target.id.uuidString, when: when), hosts: hosts)
                navigator.dismissPresented()
            } catch {
                self.error = String(describing: error)
            }
            moving = false
        }
    }
}
