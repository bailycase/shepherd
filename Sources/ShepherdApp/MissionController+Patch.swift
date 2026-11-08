import Foundation
import ShepherdCore

/// MXPatch: a revised map the planner proposed against an existing one waits on the run until the owner
/// applies it (or rejects it). Applying is an ordinary map edit (`editMission`), so it clears approval and
/// supersedes only what the edit touches; a settled decision becomes that station's receipt.
extension MissionController {
    func applyPatch(id: MissionID, revision: UInt64, patchID: UUID) async throws {
        let mission = try record(id)
        guard mission.revision == revision, let run = mission.run, !run.phase.active, jobs[id] == nil,
              let patch = run.patch, patch.id == patchID else {
            throw MissionError("stale_mission", "This patch changed or was already handled. Review the current one.")
        }
        guard run.publicationApproval == nil else { throw MissionError("mission_published", "Publication was already authorized; the map can't change.") }
        guard patch.applies(to: mission.draft) else {
            throw MissionError("mission_patch_stale", "The map changed after the planner proposed this patch. Reject it and ask the planner again.")
        }
        try await settle(id, patch: patch, revision: revision)
    }

    func rejectPatch(id: MissionID, revision: UInt64, patchID: UUID) async throws {
        let mission = try record(id)
        guard mission.revision == revision, var run = mission.run, !run.phase.active, run.patch?.id == patchID else {
            throw MissionError("stale_mission", "This patch changed or was already handled.")
        }
        run.patch = nil
        run.notice = "Patch rejected. The map is unchanged; ask the planner for another shape if you need one."
        _ = try await server.setMissionRun(id: id, expectedRevision: revision, run: run)
    }

    func setAutoApplyPatches(id: MissionID, revision: UInt64, on: Bool) async throws {
        let mission = try record(id)
        guard mission.revision == revision, var run = mission.run, !run.phase.active else {
            throw MissionError("stale_mission", "The mission changed. Try again.")
        }
        run.autoApplyPatches = on
        _ = try await server.setMissionRun(id: id, expectedRevision: revision, run: run)
    }

    /// The patch's draft becomes the map, then its decision a receipt and a log line.
    func settle(_ id: MissionID, patch: MissionPatch, revision: UInt64) async throws {
        let saved = try await server.editMission(id: id, expectedRevision: revision, draft: patch.draft)
        guard var run = saved.run else { return }
        run.settle(patch, at: Self.now)
        run.notice = "Patch applied. Review the map, then Launch."
        _ = try await server.setMissionRun(id: id, expectedRevision: saved.revision, run: run)
        reviews[id] = nil; reviewInfo[id] = nil
    }
}
