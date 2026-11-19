import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

#if canImport(UIKit)
extension MobileNavigator {
    /// Where the person is: every stack, the tab, and the iPad's detail. Closing a thread records it
    /// before and after, so a refusal restores only a place nobody has left.
    struct Place: Equatable {
        var tab: Tab
        var paths: [[MobileRoute]]
        var padPath: [MobileRoute]
        var padSelection: AgentRef?
        var padColumns: NavigationSplitViewVisibility
    }

    var place: Place {
        get { Place(tab: tab, paths: Tab.allCases.map { self[path: $0] }, padPath: padPath, padSelection: padSelection, padColumns: padColumns) }
        set {
            tab = newValue.tab
            for (tab, path) in zip(Tab.allCases, newValue.paths) { self[path: tab] = path }
            padPath = newValue.padPath
            padSelection = newValue.padSelection
            padColumns = newValue.padColumns
        }
    }
}

/// Closing a thread after its confirmation (Delete agent, Delete worktree agent, Delete agent only): the row
/// leaves every list and the screen leaves the thread at once, then the host answers. A refusal brings the row
/// back, the thread's screen too unless the person has moved on, and says why. An unknown outcome brings the
/// row back only where the host still has the agent, leaves the person where they are, and keeps the host's
/// worktree operation so the sheet shows its status and nothing is sent twice.
@MainActor
enum ThreadClosingFlow {
    /// Hides `ref`, leaves its screens and runs `send`; the confirmation has been given.
    static func close(_ ref: AgentRef, hosts: MobileHosts, navigator: MobileNavigator, title: String,
                      send: @escaping @MainActor () async throws -> Void) {
        hosts.host(ref.host)?.setClosing(ref.agent, true)
        let before = navigator.place
        navigator.dismissPresented()
        navigator.close(thread: ref)
        if navigator.layout == .pad, before.padSelection == ref, navigator.padSelection == nil,
           let last = navigator.recentPadThreads.last(where: { previous in
               guard previous != ref, let host = hosts.host(previous.host) else { return false }
               return host.agentIDs.contains(previous.agent) && !host.closingAgents.contains(previous.agent)
           }) {
            navigator.padSelection = last
            navigator.padColumns = before.padColumns
        }
        let rollback = ThreadClosing.Rollback(before: before, after: navigator.place)
        Task { @MainActor in
            do { try await send() } catch {
                hosts.host(ref.host)?.setClosing(ref.agent, false)
                let message: String
                switch ThreadClosing.outcome(of: error) {
                case .refused(let why):
                    if let place = rollback.restoring(from: navigator.place) { navigator.place = place }
                    message = why
                case .unknown(let why):
                    message = why
                }
                // Over nothing the person has since opened.
                if navigator.presented == nil { navigator.present(.search(.problem(title: title, message: message))) }
            }
        }
    }

    /// The host's worktree delete, confirmed as `info` read: start it, then follow it to its end. The host
    /// refusing the start, or the operation ending in an error, leaves the agent where it was.
    static func deleteWorktree(_ ref: AgentRef, info: RemoteWorktreeInfo, operationID: UUID, client: RemoteHostClient,
                               hosts: MobileHosts, operations: WorktreeOperations) async throws {
        var result: RemoteAgentResult
        do {
            result = try await client.agentQuery(agentID: ref.agent, query: WorktreeDeletion.query(info, operationID: operationID))
        } catch {
            switch WorktreeDeletion.startFailure(error) {
            case .refused(let message):
                operations.finish(ref)
                throw ThreadClosing.Refusal(message)
            case .unknown(let message):
                // It may be running: its status stays, for the sheet to show and nothing to send again.
                throw ThreadClosing.Unanswered(message)
            }
        }
        while operations.running[ref] == operationID {
            guard case .worktreeOperation(let status) = result else {
                throw ThreadClosing.Unanswered("The host didn’t report the worktree operation’s status. Don’t delete again.")
            }
            if status.finished {
                operations.finish(ref)
                if let failure = status.error { throw ThreadClosing.Refusal(failure) }
                return
            }
            try? await Task.sleep(for: .seconds(2))
            guard let host = hosts.host(ref.host) else { return }
            // Retirement can precede checkout cleanup. Only the operation says whether it finished.
            if let polled = host.connectedClient {
                do { result = try await polled.agentQuery(agentID: ref.agent, query: .worktreeStatus(operationID: operationID)) } catch {
                    // A dropped connection is waited out; a host that no longer knows the operation is not.
                    if case RemoteHostClientError.rejected = error {
                        throw ThreadClosing.Unanswered("Outcome not yet known: \(error). Don’t delete again.")
                    }
                }
            }
        }
    }
}
#endif
