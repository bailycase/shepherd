import Foundation
import ShepherdCore
import ShepherdProtocol

/// One pull request of a mission's merge train as a client lists it (MXTrain's cards): its place,
/// where it is now, and the step it is on or why it stopped. Read from the record; changes nothing.
public struct RemoteMissionTrainCar: Equatable, Sendable, Identifiable {
    public enum State: String, Equatable, Sendable {
        case waiting, inTrain, staging, soaking, merged, blocked

        public var label: String {
            switch self {
            case .waiting: "Waiting"
            case .inTrain: "In the train"
            case .staging: "Staging"
            case .soaking: "Soaking"
            case .merged: "Merged"
            case .blocked: "Blocked"
            }
        }
    }

    public var spaceID: SpaceID
    public var position: Int
    public var name: String
    /// "#231", from the pull request's URL.
    public var pull: String?
    public var state: State
    /// The step it is on ("CI", "Soak 10m"), or why it is blocked.
    public var detail: String?
    public var id: SpaceID { spaceID }

    /// The train's cars in its order; empty without a train.
    public static func cars(_ mission: Mission) -> [RemoteMissionTrainCar] {
        guard let train = mission.run?.train else { return [] }
        let lanes = mission.draft.plan?.lanes ?? []
        return train.cars.enumerated().map { index, car in
            let checkout = mission.run?.checkouts.first { $0.spaceID == car.spaceID }
            let base = checkout.map { $0.base.replacingOccurrences(of: "refs/heads/", with: "") } ?? "main"
            let next = car.steps.first { ![.done, .fixed, .skipped].contains($0.status) }
            let state: State, detail: String?
            if let failed = car.steps.first(where: { $0.status == .failed }) {
                state = .blocked
                detail = failed.note.flatMap { $0.isEmpty ? nil : $0 } ?? train.notice ?? "\(label(failed.kind, base: base, soak: train.rules.soakMinutes)) failed"
            } else if car.finished || next == nil {
                state = .merged; detail = nil
            } else if car.merged, let next {
                state = next.kind == .staging ? .staging : .soaking
                detail = label(next.kind, base: base, soak: train.rules.soakMinutes)
            } else if let next, car.steps.contains(where: { $0.status != .pending }) || train.current == index && train.status == .running {
                state = .inTrain
                detail = label(next.kind, base: base, soak: train.rules.soakMinutes)
            } else {
                state = .waiting; detail = nil
            }
            return RemoteMissionTrainCar(spaceID: car.spaceID, position: index + 1,
                                         name: lanes.first { $0.spaceID == car.spaceID }?.name ?? "repository",
                                         pull: checkout?.prURL.flatMap(pullNumber), state: state, detail: detail)
        }
    }

    /// The Mac's step words (MissionTrainView).
    static func label(_ kind: MissionTrain.StepKind, base: String, soak: Int) -> String {
        switch kind {
        case .update: "Update from \(base)"
        case .ci: "CI"
        case .merge: "Merge"
        case .staging: "Deploy to staging"
        case .soak: "Soak \(soak)m"
        }
    }

    static func pullNumber(_ url: String) -> String? {
        guard let last = url.split(separator: "/").last, Int(last) != nil else { return nil }
        return "#\(last)"
    }
}
