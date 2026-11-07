import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// Run on another host (ProjectRunElsewhere): a Project's task started again on another host the owner can place work on.
// "Start over there" is the owner's own placement path, the same `assign` (with a host) the New thread sheet sends, so the
// new thread is the Project's and runs through the owner's RemoteHostStore connection. "Push the branch and continue there"
// needs a thread with a branch of its own; a Project's threads work in their space's checkout, so it is shown and explained,
// never offered.

/// One Run on another host dialog. Its ID is the assignment's operation, so a retry never starts the thread twice.
struct RunElsewhereDraft: Identifiable, Equatable {
    let id = UUID()
    let ref: LogicalProjectRef
    let task: ProjectTaskID
    var target: ProjectHostReference?
    var moving = false
    var failure: String?
}

/// A host in the dialog's list: one the owner can place a thread on, or a paired host that is offline right now.
struct RunElsewhereHost: Equatable, Identifiable {
    /// nil for an offline host: nothing can be placed on it.
    let reference: ProjectHostReference?
    let id: String
    let name: String
    let online: Bool
    /// "Runs here now · Idle", "2 running", "Unreachable · last seen 3h ago", "No gamecards-web here".
    let detail: String
    /// Where the thread runs now.
    let current: Bool
    /// The target's Space with the task's Space's name; the new thread works there.
    let space: SpaceID?

    var selectable: Bool { reference != nil && online && !current && space != nil }
}

enum RunElsewhereHosts {
    struct Offline: Equatable {
        let id: UUID
        let name: String
        let lastSeen: Date?
    }

    /// The owner's hosts the Project allows, in the owner's order, then paired hosts that are offline. `running` counts what a
    /// host runs now, when this Mac can see it.
    static func rows(options: [ProjectHostOption], settings: LogicalProjectSettings, from: ProjectHostReference, spaceName: String?,
                     ownerName: String, running: (ProjectHostReference) -> Int?, offline: [Offline], now: Date = Date()) -> [RunElsewhereHost] {
        let allowed = options.filter { settings.hostPolicy == .anyConnected || settings.allowedHosts.contains($0.reference) || $0.reference == from }
        let online = allowed.map { option in
            let space = spaceName.flatMap { name in option.spaces?.first { $0.name == name }?.id }
            let load = running(option.reference).map { $0 == 0 ? "Idle" : "\($0) running" }
            var parts: [String] = []
            if option.reference == from { parts.append("Runs here now") }
            if option.spaces == nil { parts.append("Update Shepherd there to run project threads") }
            else if space == nil, let spaceName { parts.append("No \(spaceName) here") }
            if let load { parts.append(load) }
            return RunElsewhereHost(reference: option.reference, id: key(option.reference), name: option.reference == .local ? ownerName : option.name,
                                    online: true, detail: parts.joined(separator: " · "), current: option.reference == from, space: space)
        }
        let known = Set(options.compactMap { if case .remote(let id, _) = $0.reference { id } else { nil } })
        let away = offline.filter { !known.contains($0.id) }.map { host in
            RunElsewhereHost(reference: nil, id: host.id.uuidString, name: host.name, online: false,
                             detail: "Unreachable" + (host.lastSeen.map { " · last seen \(InstructionsPresentation.age($0.timeIntervalSince1970, now: now))" } ?? ""),
                             current: false, space: nil)
        }
        return online + away
    }

    static func key(_ reference: ProjectHostReference) -> String {
        switch reference {
        case .local: "local"
        case .remote(let host, let binding): "\(host.uuidString)/\(binding.uuidString)"
        }
    }

    /// "Starts a new thread on studio in gamecards-web with the same task. This thread stays here."
    static func startOverDetail(host: String, space: String?) -> String {
        "Starts a new thread on \(host)\(space.map { " in \($0)" } ?? "") with the same task. This thread stays here until you resolve it."
    }

    static let pushUnavailable = "Not for this thread: it works in its space’s own checkout, not on a branch of its own, so there is nothing to push."
    static let footnote = "The other host uses its own sign-ins, secrets and model accounts. Uncommitted files only move if you push the branch."
}

extension ShepherdViewModel {
    /// Run on another host… from a task's ⋯ menu.
    func beginRunningElsewhere(_ ref: LogicalProjectRef, task: ProjectTaskID) {
        runningElsewhere = RunElsewhereDraft(ref: ref, task: task)
    }

    /// What this Mac sees a host run now: its working threads, outside hidden spaces. nil when this Mac cannot see that host.
    func runningThreads(on reference: ProjectHostReference, owner home: LogicalProjectHome) -> Int? {
        let state: ShepherdState?
        switch (reference, home) {
        case (.local, .local): state = self.state
        case (.local, .host(let id)): state = remoteHosts.connections.first { $0.id == id && $0.phase == .connected }?.state
        case (.remote(let id, _), _): state = remoteHosts.connections.first { $0.id == id && $0.phase == .connected }?.state
        }
        guard let state else { return nil }
        let hidden = Set(state.spaces.filter { !$0.showsThreads }.map(\.id))
        return state.agents.filter { $0.status == .working && !hidden.contains($0.spaceID) && !state.isDesignAgent($0) }.count
    }
}

struct RunElsewhereSheet: View {
    var vm: ShepherdViewModel
    @Binding var draft: RunElsewhereDraft
    let dismiss: () -> Void
    @State private var options: [ProjectHostOption]?

    private var project: Project? { vm.logicalProjects.project(draft.ref) }
    private var task: ProjectTask? { project?.tasks.first { $0.id == draft.task } }
    private var spaceName: String? {
        guard let task else { return nil }
        let spaces = task.destination == .local ? vm.ownerSpaces(of: draft.ref.home)
            : options?.first { $0.reference == task.destination }?.spaces ?? []
        return spaces.first { $0.id == task.spaceID }?.name
    }
    private var hosts: [RunElsewhereHost] {
        guard let project, let task, let options else { return [] }
        let offline = draft.ref.home == .local
            ? vm.remoteHosts.connections.filter { $0.phase != .connected && !$0.isThisMac }
                .map { RunElsewhereHosts.Offline(id: $0.id, name: $0.config.name, lastSeen: $0.lastSeen) }
            : []
        return RunElsewhereHosts.rows(options: options, settings: project.settings, from: task.destination, spaceName: spaceName,
                                      ownerName: vm.ownerName(of: draft.ref.home),
                                      running: { vm.runningThreads(on: $0, owner: draft.ref.home) }, offline: offline)
    }
    private var chosen: RunElsewhereHost? {
        let rows = hosts
        return rows.first { $0.reference == draft.target && $0.selectable } ?? (draft.target == nil ? rows.first(where: \.selectable) : nil)
    }

    var body: some View {
        let rows = hosts
        let target = chosen
        let fromName = task.map { task in rows.first { $0.reference == task.destination }?.name ?? vm.ownerName(of: draft.ref.home) } ?? ""
        DialogSheet(
            title: "Run on another host",
            subtitle: task.map { "\($0.title) · now on \(fromName)" + (spaceName.map { " in \($0)" } ?? "") },
            width: SHLeadMetrics.runElsewhereWidth,
            status: draft.failure ?? (options == nil ? "Asking \(vm.ownerName(of: draft.ref.home)) where it can run…" : nil),
            actions: [
                DialogAction("Cancel", kind: .cancel) { if !draft.moving { dismiss() } },
                DialogAction(draft.moving ? "Moving…" : "Move to \(target?.name ?? "…")", kind: .prominent,
                             isEnabled: !draft.moving && target != nil && task != nil) { move() },
            ]
        ) {
            VStack(alignment: .leading, spacing: SH.Space.l) {
                SHGroupCard {
                    ForEach(rows) { row in
                        Button { draft.target = row.reference; draft.failure = nil } label: {
                            SHChoiceRow(row.name, detail: row.detail, selected: row.id == target?.id, dimmed: !row.selectable) {
                                ZStack(alignment: .bottomTrailing) {
                                    Image(systemName: "desktopcomputer").foregroundStyle(Color.sh.textSecondary)
                                    SHStatusDot(row.online ? .done : .failed)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!row.selectable || draft.moving)
                        .accessibilityLabel("\(row.name), \(row.online ? "online" : "offline"), \(row.detail)")
                    }
                }
                ModeCard(title: "Push the branch and continue there", detail: RunElsewhereHosts.pushUnavailable, selected: false, enabled: false)
                ModeCard(title: "Start over there", detail: RunElsewhereHosts.startOverDetail(host: target?.name ?? "the host you choose", space: spaceName),
                         selected: true, enabled: true)
                Text(RunElsewhereHosts.footnote).shText(.caption).foregroundStyle(Color.sh.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SHDialogMetrics.inset)
            .padding(.bottom, SH.Space.l)
        }
        .task(id: draft.ref) { options = await vm.logicalProjects.hostOptions(draft.ref.home) ?? [] }
    }

    /// Links the target's same-named Space if the Project has not yet, then assigns the same task there under this dialog's operation.
    private func move() {
        guard let target = chosen, let reference = target.reference, let space = target.space, let task else { return }
        let ref = draft.ref, operation = draft.id, from = target.name
        let host: ProjectHostReference? = reference == .local ? nil : reference
        draft.moving = true
        draft.failure = nil
        Task {
            let model = vm.logicalProjects
            var ok = true
            if model.project(ref)?.linkedSpaces.contains(where: { $0.spaceID == space && $0.destination == reference }) != true {
                ok = await model.link(ref, space: space, host: host)
            }
            if ok {
                ok = await model.run(ref, .assign(operationID: operation, spaceID: space, title: task.title, prompt: task.prompt,
                                                  host: host, model: task.model, thinking: task.thinking))
            }
            draft.moving = false
            guard ok else {
                draft.failure = "Not moved. Nothing started on \(from). \(model.failure?.message ?? "")".trimmingCharacters(in: .whitespaces)
                return
            }
            if let started = model.project(ref)?.tasks.first(where: { $0.operationID == operation }) {
                vm.logicalProjectPaneTask = started.id
            }
            dismiss()
        }
    }
}

/// One way to move (ProjectRunElsewhere's two cards): the chosen one is lantern-lined on its tint.
private struct ModeCard: View {
    let title: String
    let detail: String
    let selected: Bool
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            Text(title).font(.sh(.ui, weight: .semibold)).foregroundStyle(enabled ? Color.sh.textPrimary : Color.sh.textTertiary)
            Text(detail).shText(.caption).foregroundStyle(enabled ? Color.sh.textSecondary : Color.sh.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.sh.lanternTint : Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(selected ? Color.sh.lantern : Color.sh.lineStrong, radius: SH.Radius.m)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
