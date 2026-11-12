import Foundation
import Testing
import ShepherdCore

/// Where a dispatch goes: the table of skips, weights, battery, margin, named Macs and reason codes.
@Suite("Fleet placement")
struct FleetPlacementTests {
    static let here = UUID(), mini = UUID(), studio = UUID()

    static func mac(_ id: UUID, _ name: String, local: Bool = false, connected: Bool = true, repo: Bool? = true, problems: [String] = [],
                    sample: FleetPressureSample? = FleetRoomTests.sample(), age: TimeInterval? = 1, weight: FleetSendWeight = .normal,
                    inFlight: Int = 0) -> FleetPlacement.Mac {
        FleetPlacement.Mac(hostID: id, name: name, isLocal: local, connected: connected, hasRepo: repo, problems: problems,
                           sample: sample, sampleAge: sample == nil ? nil : age, weight: weight, inFlight: inFlight)
    }

    static func busy(_ cpu: Double = 0.7, agents: Int = 4) -> FleetPressureSample { FleetRoomTests.sample(cpu: cpu, agents: agents) }

    static func placed(_ outcome: FleetPlacement.Outcome) -> (UUID, [FleetPlacementReason])? {
        if case .place(let id, let reasons) = outcome { return (id, reasons) }
        return nil
    }

    // MARK: Auto

    @Test func autoSendsWorkToAMacWithAtLeastTheMarginMoreRoom() throws {
        let macs = [Self.mac(Self.here, "MacBook Pro", local: true, sample: Self.busy()), Self.mac(Self.mini, "Mac mini")]
        let (id, reasons) = try #require(Self.placed(FleetPlacement.place(host: nil, macs: macs)))
        #expect(id == Self.mini)
        #expect(reasons.count == 1 && reasons[0].code == .mostRoom)
        #expect((reasons[0].ratio ?? 0) > FleetRoom.moveMargin, "the drawn \"3.4x the room\" is the winner's score over this Mac's")
    }

    @Test func autoKeepsWorkHereUnlessTheBestPeerClearsTheMargin() throws {
        // 1.2x: a peer is ahead but not by 1.5x.
        let close = FleetRoomTests.sample(cpu: 0.0, agents: 1)
        let slightlyLess = FleetRoomTests.sample(cpu: 0.0, free: 40, agents: 1)
        let macs = [Self.mac(Self.here, "MacBook Pro", local: true, sample: slightlyLess), Self.mac(Self.mini, "Mac mini", sample: close)]
        let (id, reasons) = try #require(Self.placed(FleetPlacement.place(host: "auto", macs: macs)))
        #expect(id == Self.here)
        #expect(reasons.first?.code == .keptLocal && (reasons.first?.ratio ?? 0) > 1)
    }

    @Test func aMacThatIsTheOnlyOneWithRoomIsTheOnlyChoice() throws {
        let macs = [Self.mac(Self.here, "MacBook Pro", local: true, sample: Self.busy(0.97)), Self.mac(Self.mini, "Mac mini")]
        let (id, reasons) = try #require(Self.placed(FleetPlacement.place(host: nil, macs: macs)))
        #expect(id == Self.mini)
        #expect(reasons.map(\.code) == [.localIneligible, .onlyChoice])
        #expect(reasons[0].skip == FleetRoom.Skip.cpu.rawValue, "the margin doesn't apply when this Mac can't take it, and the code says why")
    }

    @Test(arguments: [
        ("stale", 20.0, nil as FleetThermal?, FleetRoom.Skip.stale),
        ("future", -9.0, nil, FleetRoom.Skip.future),
        ("serious", 1.0, FleetThermal.serious, FleetRoom.Skip.thermal),
    ])
    func aSkippedMacIsNeverPicked(_ name: String, _ age: TimeInterval, _ thermal: FleetThermal?, _ skip: FleetRoom.Skip) {
        let sample = FleetRoomTests.sample(thermal: thermal ?? .nominal)
        let macs = [Self.mac(Self.mini, "Mac mini", sample: sample, age: age)]
        #expect(FleetPlacement.place(host: nil, macs: macs) == .waitForRoom)
        #expect(FleetRoom.skip(sample, age: age) == skip)
    }

    @Test func memoryNearlyGoneAndManualOnlyLeaveAMacOut() {
        let lowMemory = FleetRoomTests.sample(free: 1)
        #expect(FleetPlacement.place(host: nil, macs: [Self.mac(Self.mini, "Mac mini", sample: lowMemory)]) == .waitForRoom)
        #expect(FleetPlacement.place(host: nil, macs: [Self.mac(Self.mini, "Mac mini", weight: .manualOnly)]) == .waitForRoom)
    }

    @Test func weightsReorderTheMacs() throws {
        let macs = [Self.mac(Self.mini, "Mac mini", weight: .lessOften), Self.mac(Self.studio, "Mac Studio", weight: .prefer)]
        #expect(try #require(Self.placed(FleetPlacement.place(host: nil, macs: macs))).0 == Self.studio)
    }

    @Test func aMacOnBatteryCountsHalfWhileTheFleetCountsIt() throws {
        let battery = FleetRoomTests.sample(battery: true)
        let macs = [Self.mac(Self.mini, "Mac mini", sample: battery), Self.mac(Self.studio, "Mac Studio", sample: FleetRoomTests.sample(free: 40))]
        #expect(try #require(Self.placed(FleetPlacement.place(host: nil, macs: macs, batteryCountsHalf: true))).0 == Self.studio)
        #expect(try #require(Self.placed(FleetPlacement.place(host: nil, macs: macs, batteryCountsHalf: false))).0 == Self.mini)
    }

    @Test func workInFlightToAMacCountsAsReservedRoom() throws {
        // Two dispatches in one moment must not stampede one Mac.
        let macs = [Self.mac(Self.mini, "Mac mini", inFlight: 3), Self.mac(Self.studio, "Mac Studio")]
        #expect(try #require(Self.placed(FleetPlacement.place(host: nil, macs: macs))).0 == Self.studio)
    }

    @Test func equalScoresKeepThisMacThenTheFirstListed() throws {
        let macs = [Self.mac(Self.mini, "Mac mini"), Self.mac(Self.here, "MacBook Pro", local: true), Self.mac(Self.studio, "Mac Studio")]
        #expect(try #require(Self.placed(FleetPlacement.place(host: nil, macs: macs))).0 == Self.here)
        let peers = [Self.mac(Self.mini, "Mac mini"), Self.mac(Self.studio, "Mac Studio")]
        #expect(try #require(Self.placed(FleetPlacement.place(host: nil, macs: peers))).0 == Self.mini)
    }

    @Test func aMacWithoutTheRepoOrWithAMissingToolIsNeverCandidate() throws {
        let macs = [Self.mac(Self.mini, "Mac mini", repo: false), Self.mac(Self.studio, "Mac Studio", problems: ["muse"]),
                    Self.mac(Self.here, "MacBook Pro", local: true, sample: Self.busy())]
        #expect(try #require(Self.placed(FleetPlacement.place(host: nil, macs: macs))).0 == Self.here)
        #expect(FleetPlacement.place(host: nil, macs: [Self.mac(Self.mini, "Mac mini", repo: false)]) == .refuse(code: FleetDispatchCode.repoMissing, detail: nil))
    }

    @Test func everyMacThatHasTheRepoLackingTheSameToolIsRefusedNotWaited() {
        let macs = [Self.mac(Self.here, "MacBook Pro", local: true, problems: ["muse"]), Self.mac(Self.mini, "Mac mini", problems: ["muse"])]
        #expect(FleetPlacement.place(host: nil, macs: macs) == .refuse(code: FleetDispatchCode.hostNotReady, detail: "muse"))
    }

    @Test func aMacThatIsAsleepIsNotCountedAndNobodyHavingRoomWaits() {
        let macs = [Self.mac(Self.mini, "Mac mini", connected: false)]
        #expect(FleetPlacement.place(host: nil, macs: macs) == .waitForRoom)
        #expect(FleetPlacement.place(host: nil, macs: [Self.mac(Self.mini, "Mac mini", sample: Self.busy(0.99))]) == .waitForRoom)
    }

    // MARK: Named

    @Test func aNamedMacBypassesScoringButNotTheFacts() throws {
        let overloaded = Self.mac(Self.mini, "Mac mini", sample: Self.busy(0.99), weight: .manualOnly)
        let (id, reasons) = try #require(Self.placed(FleetPlacement.place(host: "mac MINI", macs: [overloaded, Self.mac(Self.studio, "Mac Studio")])))
        #expect(id == Self.mini && reasons == [FleetPlacementReason(.named)], "even a busy, Manual only Mac can be named")
        #expect(FleetPlacement.place(host: "Mac mini", macs: [Self.mac(Self.mini, "Mac mini", repo: false), Self.mac(Self.studio, "Mac Studio")])
                == .refuse(code: FleetDispatchCode.repoMissing, detail: "Mac mini"), "never rerouted to the Studio")
        #expect(FleetPlacement.place(host: "Mac mini", macs: [Self.mac(Self.mini, "Mac mini", problems: ["Xcode"])])
                == .refuse(code: FleetDispatchCode.hostNotReady, detail: "Xcode"))
        #expect(FleetPlacement.place(host: "Mac mini", macs: [Self.mac(Self.mini, "Mac mini", repo: nil)])
                == .refuse(code: FleetDispatchCode.hostNotReady, detail: "unknown"))
    }

    @Test func aNamedMacThatIsAsleepIsWaitedForAndAnUnknownNameIsRefused() {
        let asleep = Self.mac(Self.mini, "Mac mini", connected: false, repo: nil, sample: nil)
        #expect(FleetPlacement.place(host: "Mac mini", macs: [asleep]) == .waitForWake(hostID: Self.mini, reasons: [FleetPlacementReason(.named)]))
        #expect(FleetPlacement.place(host: "Mac Pro", macs: [asleep]) == .refuse(code: FleetDispatchCode.noSuchHost, detail: "Mac Pro"))
    }

    @Test func aMacCanBeNamedByIDAndThisMacCanBeNamed() throws {
        let macs = [Self.mac(Self.here, "MacBook Pro", local: true), Self.mac(Self.mini, "Mac mini")]
        #expect(try #require(Self.placed(FleetPlacement.place(host: Self.mini.uuidString.lowercased(), macs: macs))).0 == Self.mini)
        #expect(try #require(Self.placed(FleetPlacement.place(host: "MacBook Pro", macs: macs))).0 == Self.here)
    }

    @Test func autoIsNothingOrTheWord() {
        #expect(FleetPlacement.isAuto(nil) && FleetPlacement.isAuto("") && FleetPlacement.isAuto(" Auto ") && !FleetPlacement.isAuto("Mac mini"))
    }
}
