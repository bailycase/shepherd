import SwiftUI
import ShepherdRemote
import ShepherdUI

extension MobileHosts {
    /// The threads working now, on every connected host (`StopAllWorking.targets`).
    var workingThreads: [StopAllWorking.Target] {
        hosts.filter { $0.phase.isConnected }.flatMap { StopAllWorking.targets(host: $0.id, in: $0.state) }
    }
}

/// What a window's Stop all working threads is asking or has just done.
@MainActor @Observable
final class StopAllWorkingModel {
    /// The threads the confirm names, until the person answers it.
    var confirming: [StopAllWorking.Target]?
    /// What the last run did, until the person has read it.
    var outcome: StopAllWorking.Outcome?

    func stop(_ targets: [StopAllWorking.Target], hosts: MobileHosts) {
        confirming = nil
        Task {
            outcome = await StopAllWorking.run(targets) { target, request in
                guard let client = hosts.host(target.host)?.connectedClient else { throw RemoteHostClientError.disconnected }
                return try await client.nativeThread(agentID: target.agent, request: request)
            }
        }
    }
}

/// Home's overflow menu: Stop all working threads. It only asks; the window's root presents the
/// confirm and the result (`StopAllWorkingDialogs`), once, however many menus the layout draws.
struct StopAllWorkingMenu: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let working = hosts.workingThreads
        Menu {
            Button(StopAllWorking.menuTitle(count: working.count), systemImage: "stop.circle", role: .destructive) {
                navigator.stopAll.confirming = working
            }
            .disabled(working.isEmpty)
        } label: {
            Label("More", systemImage: "ellipsis").duoStripIcon()
        }
    }
}

/// The confirm, which names how many threads it stops, and the result: "Stopped 3 threads", or what failed and why.
struct StopAllWorkingDialogs: ViewModifier {
    @Bindable var model: StopAllWorkingModel
    @Environment(MobileHosts.self) private var hosts

    func body(content: Content) -> some View {
        content
            .confirmationDialog(StopAllWorking.confirmTitle(count: model.confirming?.count ?? 0),
                                isPresented: Binding(get: { model.confirming != nil }, set: { if !$0 { model.confirming = nil } }),
                                titleVisibility: .visible, presenting: model.confirming) { targets in
                Button(StopAllWorking.confirmButton, role: .destructive) { model.stop(targets, hosts: hosts) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(StopAllWorking.confirmMessage)
            }
            .alert(model.outcome?.title ?? "", isPresented: Binding(get: { model.outcome != nil }, set: { if !$0 { model.outcome = nil } }),
                   presenting: model.outcome) { _ in
                Button("OK") {}
            } message: { outcome in
                Text(outcome.message)
            }
    }
}
