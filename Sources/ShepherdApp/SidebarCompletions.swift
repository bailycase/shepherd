import Foundation
import ShepherdCore
import ShepherdSidebar

@MainActor
extension ShepherdViewModel {
    func reconcileSidebarCompletions() {
        var completions = sidebarCompletions
        completions.reconcile(sidebarSource, endpoints: Dictionary(uniqueKeysWithValues:
            remoteHosts.connections.map { ($0.id, $0.endpointID) }))
        if completions != sidebarCompletions { sidebarCompletions = completions }
        if let reading = sidebarReadingThread, reading == selectedSidebarRow,
           let record = completions.records[reading], record.finished {
            sidebarReadingCompletion = record.generation
        }
        let kept = sidebarSeenCompletions.filter { completions.records[$0.key] != nil }
        if kept != sidebarSeenCompletions { sidebarSeenCompletions = kept }
        let live = Set(state.agents.map(\.id))
        if agentLives.keys.contains(where: { !live.contains($0) }) {
            agentLives = agentLives.filter { live.contains($0.key) }
        }
        sidebarActivityLast = sidebarActivityLast.filter { live.contains($0.key) }
        for id in sidebarActivityTail.keys where !live.contains(id) { forgetSidebarActivity(id) }
    }
}
