import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestKit
@testable import ShepherdApp

/// The Fleet page's model: the snapshot and the weights it derives its cards from, the weights'
/// own setting, and Open Fleet's row.
@MainActor
@Suite("Fleet page model")
struct FleetPageModelTests {
    static let here = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let mini = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let gib: UInt64 = 1 << 30

    static func snapshot(miniCPU: Double = 0.18) -> FleetSnapshot {
        FleetSnapshot(
            enabled: true, hostID: here, name: "MacBook Pro", port: 7434,
            peers: [FleetPeerStatus(hostID: mini, name: "Mac mini", pairedAt: 1, link: .connected)],
            macs: [FleetMacState(hostID: here, sample: FleetPressureSample(cpuUtilization: 0.7, cpuCount: 12, totalMemoryBytes: 36 * gib, availableMemoryBytes: 9 * gib,
                                                                           activeAgents: 3), sampleAge: 0),
                   FleetMacState(hostID: mini, sample: FleetPressureSample(cpuUtilization: miniCPU, cpuCount: 14, totalMemoryBytes: 64 * gib,
                                                                           availableMemoryBytes: 41 * gib), sampleAge: 0)])
    }

    @Test func theModelDrawsNothingUntilTheHostAnswersAndWhileFleetIsOff() {
        let model = FleetPageModel()
        #expect(model.page == .empty)
        model.update(FleetSnapshot())
        #expect(model.page.cards.isEmpty)
        model.update(Self.snapshot())
        #expect(model.page.cards.map(\.name) == ["This Mac", "Mac mini"])
        model.update(FleetSnapshot())
        #expect(model.page.cards.isEmpty, "turning Fleet off clears the page")
    }

    @Test func choosingAWeightWritesTheSettingAndRederivesTheCards() {
        let model = FleetPageModel()
        var written: [(FleetSendWeight, UUID)] = []
        var weights: [UUID: FleetSendWeight] = [:]
        model.weight = { weights[$0] ?? .normal }
        model.setWeight = { weight, id in written.append((weight, id)); weights[id] = weight }
        model.update(Self.snapshot())
        #expect(model.page.cards[1].weight == .normal && model.page.nextGoesTo == "Mac mini")

        model.choose(.manualOnly, for: Self.mini)
        #expect(written.count == 1 && written[0].0 == .manualOnly && written[0].1 == Self.mini)
        #expect(model.page.cards[1].weight == .manualOnly)
        #expect(model.page.nextGoesTo == "This Mac", "Auto no longer picks it")
    }

    @Test func aSnapshotHeldWithoutNewsAgesItsSamplesByTheDevicesClock() {
        let model = FleetPageModel()
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        model.now = { clock }
        model.update(Self.snapshot())
        #expect(model.page.cards[1].room.text == "Most room")
        clock.addTimeInterval(16)
        model.recompute()
        #expect(model.page.cards[1].room.text == "Not counted", "no new snapshot came: its samples are stale on screen")
    }

    // MARK: The weight setting

    @Test func aWeightIsTheSettingKeyedByTheMacAndNormalWhenUnset() {
        let defaults = ScratchDefaults()
        let settings = AppSettings(store: defaults)
        #expect(settings.fleetWeight(of: Self.mini) == .normal)
        var told = 0
        settings.onFleetWeightsChange = { told += 1 }
        settings.setFleetWeight(.prefer, of: Self.mini)
        #expect(settings.fleetWeights == ["fleet.weight.\(Self.mini.uuidString)": .prefer] && told == 1)
        settings.setFleetWeight(.prefer, of: Self.mini)
        #expect(told == 1, "the same choice is no change")
        #expect(AppSettings(store: defaults).fleetWeight(of: Self.mini) == .prefer, "it is kept")
    }

    @Test func aHostSettingChangeFromAClientSetsTheWeightLikeTheMacsOwnPage() {
        let defaults = ScratchDefaults()
        let settings = AppSettings(store: defaults)
        HostSettingsMapping.apply(.fleetWeight(hostID: Self.mini, weight: .lessOften), to: settings)
        #expect(settings.fleetWeight(of: Self.mini) == .lessOften)
        let shown = HostSettingsMapping.settings(from: settings, shepherdVersion: nil, piVersion: nil)
        #expect(shown.fleetWeights == settings.fleetWeights)
    }

    @Test func resettingSettingsForgetsTheWeights() {
        let defaults = ScratchDefaults()
        let settings = AppSettings(store: defaults)
        settings.setFleetWeight(.prefer, of: Self.mini)
        settings.resetToDefaults()
        #expect(settings.fleetWeights.isEmpty && defaults.dictionary(forKey: "shepherd.fleet.weights")?.isEmpty != false)
    }
}
