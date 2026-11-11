import Foundation
import ShepherdCore
import ShepherdRemote
import Testing

@Suite("A mission's merge train on a client")
struct RemoteMissionTrainTests {
    static let lanes = (1...4).map { SpaceID(rawValue: "00000000-0000-0000-0000-0000000000a\($0)") }
    static let names = ["contracts", "analytics-ingest", "checkout-svc", "orders-svc"]

    static func mission(_ train: MissionTrain) -> Mission {
        var run = MissionRun(model: "test/model", phase: .done)
        run.checkouts = lanes.enumerated().map { index, lane in
            MissionCheckout(spaceID: lane, repo: "/r/\(index)", path: "/w/\(index)", branch: "mission/x", base: "refs/heads/main", head: "abc",
                            prURL: "https://github.com/acme/\(names[index])/pull/\(100 + index)")
        }
        run.train = train
        let plan = MissionPlan(lanes: zip(lanes, names).map { MissionLane(spaceID: $0, name: $1) })
        return Mission(id: MissionID(), revision: 3, draft: MissionDraft(title: "Checkout funnel events", goal: "Ship", plan: plan), run: run)
    }

    /// Merged, soaking, blocked on a conflict and waiting: each car says where it is, and the blocked one why.
    @Test func eachCarSaysWhereItIsAndWhyItStopped() {
        var train = MissionTrain(order: Self.lanes, rules: MissionTrain.Rules(between: .stagingSoak, soakMinutes: 10), startedAt: 0)
        for step in train.cars[0].steps.indices { train.cars[0].steps[step].status = .done }
        for step in 0..<4 { train.cars[1].steps[step].status = .done }
        train.cars[1].steps[4].status = .running
        train.cars[2].steps[0].status = .failed
        train.cars[2].steps[0].note = "code conflict: Sources/Events.swift"
        train.pause("checkout-svc has a code conflict with main. Code conflicts pause and ask.")

        let cars = RemoteMissionTrainCar.cars(Self.mission(train))
        #expect(cars.map(\.name) == Self.names)
        #expect(cars.map(\.position) == [1, 2, 3, 4])
        #expect(cars.map(\.pull) == ["#100", "#101", "#102", "#103"])
        // Pause puts the running soak back to pending; the car is still soaking.
        #expect(cars.map(\.state) == [.merged, .soaking, .blocked, .waiting])
        #expect(cars[1].detail == "Soak 10m")
        #expect(cars[2].detail == "code conflict: Sources/Events.swift")
        #expect(cars[3].detail == nil)
    }

    /// The car the running train is on is in the train before its first step starts; a merged car's deploy is staging.
    @Test func theCurrentCarIsInTheTrainAndADeployIsStaging() {
        var train = MissionTrain(order: Self.lanes, rules: MissionTrain.Rules(between: .stagingSoak), startedAt: 0)
        #expect(RemoteMissionTrainCar.cars(Self.mission(train)).map(\.state) == [.inTrain, .waiting, .waiting, .waiting])
        #expect(RemoteMissionTrainCar.cars(Self.mission(train)).first?.detail == "Update from main")
        for step in 0..<3 { train.cars[0].steps[step].status = .done }
        train.cars[0].steps[3].status = .running
        #expect(RemoteMissionTrainCar.cars(Self.mission(train)).first?.state == .staging)
        // A blocked car with no note of its own takes the train's notice.
        train.cars[0].steps[3].status = .failed
        train.pause("contracts' staging deploy exited 1. Paused for you.")
        #expect(RemoteMissionTrainCar.cars(Self.mission(train)).first?.detail == "contracts' staging deploy exited 1. Paused for you.")
    }

    @Test func noTrainNoCars() {
        var mission = Self.mission(MissionTrain(order: [], rules: .init(), startedAt: 0))
        mission.run?.train = nil
        #expect(RemoteMissionTrainCar.cars(mission).isEmpty)
    }
}
