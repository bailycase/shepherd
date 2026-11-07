import Foundation

/// MXLocks: missions lock paths, not repositories. A launched mission holds, in each repository, the paths its
/// workers plan to write (from the map) until that repository's pull request merges or the mission ends. Another
/// mission whose paths overlap waits in a queue for that lane, unless its owner stacks it or runs it anyway.
public enum MissionPaths {
    /// The literal part of a path or glob, before its first wildcard.
    static func prefix(_ pattern: String) -> String {
        String(pattern.prefix { !"*?[".contains($0) })
    }

    /// Whether two paths or globs can name the same file.
    public static func overlaps(_ a: String, _ b: String) -> Bool {
        if a == b || fnmatch(a, b, FNM_PATHNAME) == 0 || fnmatch(b, a, FNM_PATHNAME) == 0 { return true }
        let (pa, pb) = (prefix(a), prefix(b))
        let wildA = pa != a, wildB = pb != b
        // A glob reaches everything under its literal prefix; two literals overlap only when equal.
        if wildA && b.hasPrefix(pa) && (a.hasSuffix("**") || !b.dropFirst(pa.count).contains("/")) { return true }
        if wildB && a.hasPrefix(pb) && (b.hasSuffix("**") || !a.dropFirst(pb.count).contains("/")) { return true }
        if wildA && wildB { return pa.hasPrefix(pb) || pb.hasPrefix(pa) }
        return false
    }

    /// The paths of `mine` that some path of `theirs` can also name: the more specific of each pair.
    public static func overlap(_ mine: [String], _ theirs: [String]) -> [String] {
        var found: [String] = []
        for a in mine {
            for b in theirs where overlaps(a, b) {
                let narrow = prefix(a).count >= prefix(b).count ? a : b
                if !found.contains(narrow) { found.append(narrow) }
            }
        }
        return found
    }

    /// Whether `file` is inside any of `paths`.
    public static func covers(_ paths: [String], _ file: String) -> Bool {
        paths.contains { path in
            file == path || fnmatch(path, file, FNM_PATHNAME) == 0 || (path.hasSuffix("/**") && file.hasPrefix(String(path.dropLast(2))))
                || (!path.contains("*") && file.hasPrefix(path.hasSuffix("/") ? path : path + "/"))
        }
    }
}

/// One of a mission's repositories held by another mission, and what the owner chose to do about it.
public struct MissionLaneLock: Codable, Hashable, Sendable {
    public enum Choice: String, Codable, Sendable, CaseIterable { case wait, stack, runAnyway }
    public var holder: MissionID
    public var holderTitle: String
    /// The paths both missions plan to write.
    public var overlap: [String]
    public var since: Double
    public var choice: Choice
    /// Stack only: the holder's branch is merged into this mission's worktree.
    public var stacked: Bool?

    public init(holder: MissionID, holderTitle: String, overlap: [String], since: Double, choice: Choice = .wait) {
        self.holder = holder; self.holderTitle = holderTitle; self.overlap = overlap; self.since = since; self.choice = choice
    }

    /// Waiting keeps the lane's stations from starting; stack and run anyway let them go.
    public var blocks: Bool { choice == .wait || (choice == .stack && stacked != true) }
}

public extension Mission {
    /// What this mission's workers plan to write in `lane`.
    func writes(_ lane: SpaceID) -> [String] {
        var paths: [String] = []
        for station in draft.plan?.stations ?? [] where station.laneID == lane && station.kind == .worker {
            for path in station.paths ?? [] where !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    /// The paths this mission holds in `lane` now: from launch until the lane's pull request merges in its train or
    /// the mission ends; never while it waits for that lane itself.
    func holds(_ lane: SpaceID) -> [String] {
        guard approvedPlanRevision != nil, let run, run.held?[lane]?.blocks != true else { return [] }
        switch run.phase {
        case .running, .paused, .review, .publishing: break
        case .done:
            guard let train = run.train, train.status != .done, train.cars.first(where: { $0.spaceID == lane })?.merged == false else { return [] }
        default: return []
        }
        return writes(lane)
    }
}

public extension Array where Element == Mission {
    /// The other missions holding paths `mission` plans to write in `lane`, and the overlap with each.
    func holders(of lane: SpaceID, for mission: Mission) -> [(mission: Mission, overlap: [String])] {
        let mine = mission.writes(lane)
        guard !mine.isEmpty else { return [] }
        return compactMap { other in
            guard other.id != mission.id, other.draft.plan?.lanes.contains(where: { $0.spaceID == lane }) == true else { return nil }
            let overlap = MissionPaths.overlap(mine, other.holds(lane))
            return overlap.isEmpty ? nil : (other, overlap)
        }
    }

    /// The queue on `lane` for `paths`: who holds them, who waits (longest first), then drafts that plan to write them.
    func queue(_ lane: SpaceID, paths: [String]) -> [(mission: Mission, state: QueueState)] {
        let touching = filter { !MissionPaths.overlap($0.writes(lane), paths).isEmpty }
        let holding = touching.filter { !$0.holds(lane).isEmpty }.map { ($0, QueueState.holding) }
        let waiting = touching.compactMap { mission in mission.run?.held?[lane].map { (mission, $0.since) } }
            .filter { $0.0.run?.held?[lane]?.blocks == true }.sorted { $0.1 < $1.1 }.map { ($0.0, QueueState.waiting) }
        let drafts = touching.filter { $0.approvedPlanRevision == nil && ($0.run?.phase ?? .map) == .map }.map { ($0, QueueState.draft) }
        return holding + waiting + drafts
    }
}

public enum QueueState: Sendable { case holding, waiting, draft }
