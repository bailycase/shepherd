import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

// Fleet ▸ Check's buttons: Check now, Fix with an agent (a normal thread on the Mac, started through `sendThread` like New thread's), Fix everything,
// Ignore, and Open thread. Checks only read; every change a fix makes is made by a thread the person watches.

@MainActor
extension ShepherdViewModel {
    /// Check now: this Mac and every Mac of the fleet look at themselves again; the page reads what they found.
    func checkFleetNow() {
        guard !fleetPage.checking else { return }
        fleetPage.checking = true
        Task {
            _ = await fleet.checkNow()
            fleetPage.checking = false
        }
    }

    /// Fix with an agent: a thread on `fix.mac` with the checklist. A thread on another Mac goes through the same `sendThread` as New thread's
    /// (so it is placed, refused or waits as any), tagged with the items so the row shows Fixing… and Check looks again when it ends; a thread
    /// on this Mac is a thread of its own, here.
    func startFleetFix(_ fix: FleetCheckFix) {
        fleetPage.checkProblem = nil
        Task {
            do {
                if fix.mac == thisFleetID {
                    try await startLocalFix(fix)
                } else {
                    guard let space = fixSpace(for: fix) else {
                        fleetPage.checkProblem = "Start a thread in a space with a git origin first: \(fix.macName) finds the repository there."
                        return
                    }
                    let thread = FleetUserThread(spaceID: space.id, task: fix.prompt, title: fix.title, host: fix.mac.uuidString,
                                                 thinking: settings.defaultThinking.rawValue, fixes: fix.items)
                    _ = try await fleet.sendThread(thread)
                }
            } catch {
                fleetPage.checkProblem = FleetSettingsModel.words(error)
            }
        }
    }

    /// The space a fix thread on another Mac starts from: one of the repositories its items come from that the Mac has, else any this Mac and
    /// the Mac have in common, else any with an origin (the Mac clones it).
    private func fixSpace(for fix: FleetCheckFix) -> Space? {
        let spaces = state.spaces.filter { !$0.hidden && $0.repoKey != nil && !missingSpaces.contains($0.id) }
        let theirs = Set(fleetPage.snapshot.macs.first { $0.hostID == fix.mac }?.readiness?.repoKeys ?? [])
        return spaces.first { fix.repos.contains($0.name) && theirs.contains($0.repoKey ?? "") }
            ?? spaces.first { theirs.contains($0.repoKey ?? "") }
            ?? spaces.first
    }

    /// A fix of This Mac: a standalone thread (the host makes its folder), so it needs no repository and touches none.
    private func startLocalFix(_ fix: FleetCheckFix) async throws {
        var config = NewAgentConfig(spaceID: SpaceID(rawValue: ""), workingDirectory: "", model: nil, thinking: settings.defaultThinking, initialPrompt: fix.prompt)
        config.reservedAgentID = AgentID()
        config.initialName = fix.title
        let agent = try await startAgent(config, focusWindow: false)
        fleetPage.startedLocalFix(agent, title: fix.title, items: fix.items)
    }

    /// The thread a running fix is: opened in the sidebar, whichever Mac runs it.
    func openFleetFix(_ fixing: FleetCheckFixing) {
        if let agent = fixing.agentID {
            selectSidebarRow(.local(agent))
        } else if let dispatch = fixing.dispatchID, let card = fleetPage.dispatchCards.first(where: { $0.id == dispatch }) {
            openDispatchedThread(card)
        }
    }

    /// A local thread's turn ended: a fix of This Mac that ended makes Check look again.
    func fleetCheckAgentEnded(_ agent: AgentID) {
        if fleetPage.endedLocalFix(agent) { checkFleetNow() }
    }
}
