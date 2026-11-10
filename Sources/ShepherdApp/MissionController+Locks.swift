import Foundation
import ShepherdCore
import ShepherdSessions

/// MXLocks: a running mission's repositories that another mission holds. The lane waits in its queue unless the
/// owner stacks it on the holder's branch or runs it anyway; a worker that writes outside the paths its map
/// declared pauses the mission.
extension MissionController {
    /// How often a held lane looks again. Tests shorten it.
    static var lockPoll: Duration = .seconds(5)

    /// Records which lanes are held now (and frees the ones that aren't), stacks where the owner chose it,
    /// and answers the lanes whose stations must not start.
    func refreshLocks(_ id: MissionID, runID: UUID) async throws -> Set<SpaceID> {
        let mission = try record(id, runID: runID)
        guard let plan = mission.draft.plan, let run = mission.run else { return [] }
        var held = run.held ?? [:], freed: [String] = []
        for lane in plan.lanes.map(\.spaceID) {
            if let holder = records.holders(of: lane, for: mission).first {
                if held[lane]?.holder != holder.mission.id {
                    held[lane] = MissionLaneLock(holder: holder.mission.id, holderTitle: holder.mission.draft.title, overlap: holder.overlap, since: Self.now,
                                                 choice: held[lane]?.choice ?? .wait)
                }
            } else if held.removeValue(forKey: lane) != nil {
                freed.append(mission.lane(lane)?.name ?? "A repository")
            }
        }
        for (lane, lock) in held where lock.choice == .stack && lock.stacked != true {
            guard let ours = run.checkouts.first(where: { $0.spaceID == lane }),
                  let theirs = records.first(where: { $0.id == lock.holder })?.run?.checkouts.first(where: { $0.spaceID == lane }) else {
                throw MissionError("mission_stack", "\(mission.lane(lane)?.name ?? "That repository") has no worktree to stack on yet. Wait in the queue instead.")
            }
            let merge = await Self.command("git -c user.name=Shepherd -c user.email=shepherd@localhost merge --no-edit \(shellQuoted(theirs.branch))", cwd: ours.path)
            guard merge.status == 0 else {
                _ = await Self.command("git merge --abort", cwd: ours.path)
                throw MissionError("mission_stack", "Stacking on \(lock.holderTitle) conflicts in \(mission.lane(lane)?.name ?? "that repository"). Nothing was kept; wait in the queue or run anyway.")
            }
            held[lane]?.stacked = true
        }
        if held != (run.held ?? [:]) {
            _ = try await server.updateMissionRun(id: id, runID: runID) { $0.held = held.isEmpty ? nil : held }
        }
        for name in freed {
            hosting.notify(mission.draft.title, "\(name) is free. Its stations start now.")
        }
        return Set(held.filter(\.value.blocks).keys)
    }

    /// The owner's choice for a held lane: wait in the queue, stack on the holder's branch, or run anyway.
    func chooseLock(id: MissionID, lane: SpaceID, choice: MissionLaneLock.Choice) async throws {
        let mission = try record(id)
        guard var run = mission.run, run.held?[lane] != nil else { throw MissionError("stale_mission", "That repository isn't held any more.") }
        if run.phase.active {
            _ = try await server.updateMissionRun(id: id, runID: run.id) { $0.held?[lane]?.choice = choice }
        } else {
            run.held?[lane]?.choice = choice
            _ = try await server.setMissionRun(id: id, expectedRevision: mission.revision, run: run)
        }
    }

    /// A worker that declared its paths and wrote elsewhere stops the mission: the map is the lock.
    func checkWrites(_ id: MissionID, runID: UUID, station: MissionStation) async throws {
        let mission = try record(id, runID: runID)
        guard let lane = station.laneID, let checkout = mission.run?.checkouts.first(where: { $0.spaceID == lane }) else { return }
        let paths = mission.writes(lane)
        guard !paths.isEmpty else { return }
        let changed = await Self.command("git diff --name-only \(shellQuoted(checkout.head)) && git ls-files --others --exclude-standard", cwd: checkout.path)
        let outside = changed.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !MissionPaths.covers(paths, $0) }
        guard outside.isEmpty else {
            throw MissionError("mission_paths", "\(station.title) wrote outside the paths its map holds: \(outside.prefix(5).joined(separator: ", ")). Add them to the map (other missions on \(mission.lane(lane)?.name ?? "this repository") may hold them) or revert them, then resume.")
        }
    }
}
