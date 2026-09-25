import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// Rename a thread's agent on its host. Presented modally; Save sends the new name and closes
/// once the host took it. A manual name is final there: the namer never replaces it.
struct RenameAgentSheet: View {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @State private var name = ""
    @State private var saving = false
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
                    .font(.nw(.ui))
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { if next != nil { save(next) } }
                    .accessibilityLabel("Thread name")
            } footer: {
                VStack(alignment: .leading, spacing: NW.Space.xs) {
                    if let error {
                        Text(error).foregroundStyle(Color.nw.failed)
                    }
                    if let host {
                        Text(agent == nil ? "This agent is no longer on \(host.name)." : "On \(host.name). The new name replaces the one the agent chose.")
                    }
                }
                .font(.nw(.caption))
                .foregroundStyle(Color.nw.textTertiary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.nw.bgWindow)
        .navigationTitle("Rename")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { navigator.dismissPresented() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView().progressViewStyle(NWSpinnerStyle())
                } else {
                    Button("Save") { save(next) }.disabled(next == nil || agent == nil)
                }
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
        guard let next, !saving else { return }
        saving = true
        error = nil
        Task {
            do {
                try await AgentActions.rename(ref, to: next, hosts: hosts)
                navigator.dismissPresented()
            } catch {
                self.error = String(describing: error)
            }
            saving = false
        }
    }
}

/// Delete a thread's agent. A plain agent confirms and is retired on its host; its folder stays.
/// A worktree agent follows the Mac's Delete Worktree Agent: the host describes the checkout and
/// any work that would be lost, which must be acknowledged, and the delete runs on the host as
/// an operation whose progress shows here; "Delete agent only" keeps the checkout and branch.
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
        .background(Color.nw.bgWindow)
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
    @State private var deleting = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Thread") { Text(name ?? "Gone").lineLimit(1) }
                LabeledContent("Host") { Text(hostName ?? "Forgotten") }
            } footer: {
                Text("The agent stops and its thread closes on every device. Its folder and files stay.")
                    .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            }
            if let error {
                Section { Text(error).font(.nw(.caption)).foregroundStyle(Color.nw.failed) }
            }
            Section {
                Button(role: .destructive, action: delete) {
                    HStack(spacing: NW.Space.m) {
                        Text("Delete agent")
                        if deleting { ProgressView().progressViewStyle(NWSpinnerStyle()) }
                    }
                }
                .disabled(deleting || name == nil)
            }
        }
        .font(.nw(.ui))
        .navigationTitle("Delete agent")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { navigator.dismissPresented() }
            }
        }
    }

    private func delete() {
        deleting = true
        error = nil
        Task {
            do {
                try await AgentActions.delete(ref, hosts: hosts)
                navigator.dismissPresented()
                navigator.close(thread: ref)
            } catch {
                self.error = String(describing: error)
            }
            deleting = false
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
                        Text(info.path).font(.nw(.mono)).lineLimit(1).truncationMode(.middle)
                    }
                    LabeledContent("Branch") { Text(info.branch).font(.nw(.mono)).lineLimit(1) }
                } else if loading && !running {
                    HStack(spacing: NW.Space.m) {
                        ProgressView().progressViewStyle(NWSpinnerStyle())
                        Text("Checking the worktree on \(host?.name ?? "the host")…").foregroundStyle(Color.nw.textSecondary)
                    }
                }
            }
            if let info, let warning = info.warning, operation == nil, !running {
                Section {
                    NWBanner(.attention, title: "Unreconciled work", message: WorktreeDeletion.lossMessage(warning))
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
                        Text(line).font(.nw(.mono)).foregroundStyle(Color.nw.textSecondary)
                    }
                    if let failure = operation.error {
                        Text(failure).font(.nw(.caption)).foregroundStyle(Color.nw.failed)
                    }
                    if operation.finished, operation.error == nil {
                        Label("Agent, checkout and local branch removed", systemImage: "checkmark.circle")
                            .foregroundStyle(Color.nw.done)
                    }
                }
            } else if running {
                Section {
                    HStack(spacing: NW.Space.m) {
                        ProgressView().progressViewStyle(NWSpinnerStyle())
                        Text("Deleting on the host. Closing this only stops watching it.").foregroundStyle(Color.nw.textSecondary)
                    }
                }
            }
            if let error {
                Section { Text(error).font(.nw(.caption)).foregroundStyle(Color.nw.failed) }
            }
            if !running, operation == nil {
                Section {
                    Button("Delete agent and worktree", role: .destructive) { start() }
                        .disabled(!WorktreeDeletion.canDelete(info, acknowledged: acknowledged, submitting: submitting))
                    Button("Delete agent only") { deleteAgentOnly() }
                        .disabled(submitting || info == nil && loading)
                } footer: {
                    Text("Delete agent only keeps the checkout and its branch. The remote branch is never deleted.")
                        .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                }
            }
        }
        .font(.nw(.ui))
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

    /// A request over the connection the confirmation came from; a status check goes over any.
    private func query(_ value: RemoteAgentQuery, anyConnection: Bool = false) async throws -> RemoteAgentResult {
        guard let host = hosts.host(ref.host), let client = host.connectedClient else {
            throw AgentActions.Failure("The host is offline. Reopen this once it reconnects.")
        }
        guard anyConnection || host.session == session else {
            throw AgentActions.Failure("The connection to \(host.name) changed. Reopen this to check the worktree again.")
        }
        return try await client.agentQuery(agentID: ref.agent, query: value)
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
        submitting = true
        error = nil
        let id = operations.start(ref)
        Task {
            do {
                if case .worktreeOperation(let status) = try await query(WorktreeDeletion.query(info, operationID: id)) {
                    operation = status
                }
            } catch {
                switch WorktreeDeletion.startFailure(error) {
                case .refused(let message):
                    operations.finish(ref)
                    self.error = message
                case .unknown(let message):
                    self.error = message
                }
            }
            submitting = false
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
        submitting = true
        error = nil
        Task {
            do {
                _ = try await query(.deleteKeepingWorktree)
                navigator.dismissPresented()
                navigator.close(thread: ref)
            } catch {
                self.error = Self.message(error)
            }
            submitting = false
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
        NWEmptyState(Text(title), message: message, showsMark: false) {
            Button("OK") { navigator.dismissPresented() }
                .buttonStyle(.nw(.secondary, size: .l))
                .nwTouchTarget(height: NW.Height.controlL)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.nw.bgWindow)
        .presentationDetents(navigator.layout == .pad ? [.large] : [.medium])
    }
}
