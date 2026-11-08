import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// A mission as the phone draws it: the Mac's pill words and states (MissionsPage's shared
// presentation), for the iOS client.
extension MissionRun.Phase {
    var mobileLabel: String {
        switch self {
        case .planning: "Planning"
        case .map: "Draft"
        case .running: "Running"
        case .paused: "Paused"
        case .review: "Review · needs you"
        case .publishing: "Publishing PRs"
        case .done: "PRs published"
        case .stopped: "Stopped"
        }
    }
}

extension AgentState {
    init(_ phase: MissionRun.Phase) {
        switch phase {
        case .planning, .running, .publishing: self = .running
        case .paused, .review: self = .attention
        case .done: self = .done
        case .map, .stopped: self = .idle
        }
    }

    init(_ status: MissionAttempt.Status) {
        switch status {
        case .running: self = .running
        case .succeeded: self = .done
        case .failed: self = .failed
        case .interrupted: self = .attention
        case .superseded: self = .queued
        }
    }
}

/// One mission's row in a list: its name, pill, host and repositories, and its route.
struct MissionRowModel: Identifiable, Equatable {
    let key: MissionKey
    let title: String
    let state: AgentState
    let label: String
    let detail: String
    let route: [AgentState?]
    var id: MissionKey { key }

    @MainActor init(_ mission: Mission, host: MobileHost) {
        key = MissionKey(host: host.id, mission: mission.id)
        title = mission.draft.title.isEmpty ? mission.draft.goal : mission.draft.title
        let phase = mission.run?.phase ?? .map
        let waiting = mission.run?.pendingQuestion != nil && phase == .map
            || phase == .map && mission.run?.specKit?.lanes.contains { $0.convergence?.accepted == false } == true
        let patched = mission.run?.patch != nil && !phase.active
        let train = phase == .done ? mission.run?.train : nil
        state = waiting || patched || train?.status == .paused || (phase == .running && mission.run?.held?.values.contains(where: \.blocks) == true) ? .attention : train?.status == .running ? .running : AgentState(phase)
        let held = phase == .running ? (mission.run?.held ?? [:]).values.filter(\.blocks).count : 0
        label = waiting ? "Needs you" : patched ? "Patch ready" : held > 0 ? "Running · \(held) lane\(held == 1 ? "" : "s") held" : train.map { train in
            switch train.status {
            case .running: "Merging · \(train.merged) of \(train.cars.count)"
            case .paused: "Train paused"
            case .done: "Merged"
            }
        } ?? phase.mobileLabel
        let lanes = (mission.draft.plan?.lanes ?? []).map(\.name).joined(separator: ", ")
        detail = mission.run?.pendingQuestion ?? ([host.name] + (lanes.isEmpty ? [] : [lanes])).joined(separator: " · ")
        route = (mission.draft.plan?.stations ?? []).map { station in
            guard let attempt = mission.run?.latest(station.id), attempt.status != .superseded else { return station.kind == .decision ? .attention : nil }
            return AgentState(attempt.status)
        }
    }
}

/// A station of the map as a row: what it is, where, and its latest receipt.
struct MissionStationRow: Identifiable, Equatable {
    let id: MissionStationID
    let title: String
    let kind: String
    let lane: String?
    let state: AgentState?
    let status: String
    let agent: AgentID?
    let attempt: UUID?
    /// Its turn is working and the mission runs: the owner may steer it.
    let steerable: Bool

    static func rows(_ mission: Mission) -> [MissionStationRow] {
        let plan = mission.draft.plan ?? MissionPlan()
        let active = mission.run?.phase.active == true
        return plan.stations.map { station in
            let attempt = mission.run?.latest(station.id)
            let word: String = switch station.kind {
            case .research: "research"
            case .worker: "worker"
            case .check: "check"
            case .decision: "you"
            case .validator: "validator"
            }
            return MissionStationRow(id: station.id, title: station.title, kind: word,
                                     lane: plan.lanes.first { $0.spaceID == station.laneID }?.name,
                                     state: attempt.map { AgentState($0.status) }, status: attempt?.status.rawValue ?? "not started",
                                     agent: attempt?.agentID, attempt: attempt?.id,
                                     steerable: active && attempt?.status == .running && attempt?.agentID != nil)
        }
    }
}
