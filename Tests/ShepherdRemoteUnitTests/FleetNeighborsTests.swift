import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Add a Mac on a network that passes Apple's Bonjour types but not `_shepherd._tcp`: how the
/// two kinds of result merge, and which addresses get probed.
@Suite("Fleet: finding Macs on other subnets")
struct FleetNeighborsTests {
    static let mini = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    static let studio = UUID(uuidString: "00000000-0000-4000-8000-0000000000A2")!

    static func identity(_ id: UUID, _ name: String, build: String? = "1.9") -> RemoteHostClient.FleetPeerIdentity {
        .init(hostID: id, name: name, build: build, fleetEnabled: true)
    }

    static func probed(_ id: UUID, _ name: String, _ address: String, port: UInt16 = 7434) -> FoundMac {
        FleetNeighbors.found(identity(id, name), address: address, port: port)
    }

    static func bonjour(_ id: UUID?, _ name: String, _ address: String?, port: UInt16 = 7434) -> FoundMac {
        FoundMac(id: "\(name)._shepherd._tcp", name: name, version: "1.9", idHash: id.map(FleetProtocol.advertisedIDHash),
                 address: address, port: address == nil ? nil : port)
    }

    // MARK: Merging

    @Test func aMacSeenBothWaysShowsOnceAsItsBonjourRecord() {
        let both = FleetNeighbors.merged(bonjour: [Self.bonjour(Self.mini, "Mac mini", "10.77.20.5")],
                                         probed: [Self.probed(Self.mini, "Mac mini", "10.77.20.5")])
        #expect(both.map(\.id) == ["Mac mini._shepherd._tcp"])
        // The same Mac on another address (a second interface) is the same Mac.
        let other = FleetNeighbors.merged(bonjour: [Self.bonjour(Self.mini, "Mac mini", "10.77.20.5")],
                                          probed: [Self.probed(Self.mini, "Mac mini", "169.254.3.4")])
        #expect(other.count == 1)
        // A Bonjour entry with no id in its record still hides a probe of its address and port.
        let anonymous = FleetNeighbors.merged(bonjour: [Self.bonjour(nil, "Mac mini", "10.77.20.5")],
                                              probed: [Self.probed(Self.mini, "Mac mini", "10.77.20.5")])
        #expect(anonymous.map(\.id) == ["Mac mini._shepherd._tcp"])
    }

    @Test func aMacOnlyAProbeFoundIsListedBesideBonjoursSortedByName() {
        let list = FleetNeighbors.merged(bonjour: [Self.bonjour(Self.studio, "Mac Studio", "10.77.10.9")],
                                         probed: [Self.probed(Self.mini, "Mac mini", "10.77.20.5")])
        #expect(list.map(\.name) == ["Mac Studio", "Mac mini"])
        let mini = list.last
        #expect(mini?.address == "10.77.20.5" && mini?.port == 7434 && mini?.version == "1.9")
        #expect(mini?.idHash == FleetProtocol.advertisedIDHash(Self.mini))
    }

    @Test func aBonjourMacThatHasNotResolvedIsNotListedButStillHidesItsProbe() {
        let list = FleetNeighbors.merged(bonjour: [Self.bonjour(Self.mini, "Mac mini", nil)],
                                         probed: [Self.probed(Self.mini, "Mac mini", "10.77.20.5")])
        #expect(list.isEmpty, "it appears once Bonjour resolves it: never twice")
    }

    @Test func theTypesBrowsedAreAllInBothAppsBonjourServices() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for plist in ["App/Info.plist", "App/iOS/Info.plist"] {
            let info = try #require(PropertyListSerialization.propertyList(
                from: Data(contentsOf: root.appendingPathComponent(plist)), format: nil) as? [String: Any])
            let declared = Set(try #require(info["NSBonjourServices"] as? [String]))
            #expect(declared.isSuperset(of: FleetNeighbors.types + [FleetProtocol.bonjourType]), "\(plist) lists every browsed type")
        }
    }

    // MARK: Probing

    /// Answers for the devices it is given, records every call, and can hold calls until released.
    final class Probes: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: RemoteHostClient.FleetPeerIdentity]
        private(set) var calls: [String] = []
        private var running = 0
        private(set) var peak = 0
        private var gate: [CheckedContinuation<Void, Never>] = []
        private var held = false
        /// Each call's address, as it starts.
        let started: AsyncStream<String>
        private let startedSink: AsyncStream<String>.Continuation

        init(_ answers: [String: RemoteHostClient.FleetPeerIdentity], hold: Bool = false) {
            self.answers = answers
            held = hold
            (started, startedSink) = AsyncStream.makeStream()
        }

        var probe: FleetNeighborProber.Probe {
            { [self] address, port in
                let hold = begin("\(address):\(port)")
                if hold { await withCheckedContinuation { park($0) } }
                return finish("\(address):\(port)")
            }
        }

        var callCount: Int { lock.withLock { calls.count } }

        private func begin(_ call: String) -> Bool {
            let hold = lock.withLock { () -> Bool in
                calls.append(call); running += 1; peak = max(peak, running)
                return held
            }
            startedSink.yield(call)
            return hold
        }

        private func park(_ continuation: CheckedContinuation<Void, Never>) {
            lock.withLock { gate.append(continuation) }
        }

        private func finish(_ call: String) -> RemoteHostClient.FleetPeerIdentity? {
            lock.withLock { running -= 1; return answers[call] }
        }

        func release() {
            let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in held = false; defer { gate = [] }; return gate }
            all.forEach { $0.resume() }
        }
    }

    @MainActor
    @Test func onlyDevicesThatAnswerAreListedAndEachAddressIsProbedOnce() async throws {
        let probes = Probes(["10.77.20.5:7434": Self.identity(Self.mini, "Mac mini")])
        var changes = 0
        let prober = FleetNeighborProber(ports: [7434], probe: probes.probe, changed: { changes += 1 })
        prober.see(address: "10.77.20.5")
        prober.see(address: "10.77.20.5")
        prober.see(address: "10.77.20.8")   // a printer, a TV: nothing answers
        await prober.settle()
        #expect(prober.answered["10.77.20.5"]?.name == "Mac mini")
        #expect(prober.answered["10.77.20.8"] == nil && changes == 1, "a device that does not answer never shows")
        prober.see(address: "10.77.20.5")
        #expect(probes.callCount == 2, "an address seen again is not probed again")
        prober.stop()
    }

    @MainActor
    @Test func theOtherEditionsPortIsTriedOnlyWhenTheFirstDoesNotAnswer() async throws {
        let probes = Probes(["10.77.20.5:7433": Self.identity(Self.mini, "Mac mini"),
                             "10.77.20.6:7434": Self.identity(Self.studio, "Mac Studio")])
        let prober = FleetNeighborProber(ports: [7434, 7433], probe: probes.probe, changed: {})
        prober.see(address: "10.77.20.5")
        prober.see(address: "10.77.20.6")
        await prober.settle()
        #expect(prober.answered["10.77.20.5"]?.port == 7433 && prober.answered["10.77.20.6"]?.port == 7434)
        #expect(probes.calls.filter { $0.hasPrefix("10.77.20.6") } == ["10.77.20.6:7434"])
        prober.stop()
    }

    @MainActor
    @Test func addressesBonjourAlreadyListedAreNotProbed() async throws {
        let probes = Probes([:])
        let prober = FleetNeighborProber(ports: [7434], probe: probes.probe, skip: { $0 == "10.77.10.9" }, changed: {})
        prober.see(address: "10.77.10.9")
        prober.see(address: "10.77.20.5")
        await prober.settle()
        #expect(probes.calls == ["10.77.20.5:7434"])
        prober.stop()
    }

    @MainActor
    @Test func atMostTheLimitAreProbedAtOnceAndTheRestWait() async throws {
        let probes = Probes([:], hold: true)
        let prober = FleetNeighborProber(ports: [7434], limit: 2, probe: probes.probe, changed: {})
        for index in 1...5 { prober.see(address: "10.77.20.\(index)") }
        var started = probes.started.makeAsyncIterator()
        _ = await started.next()
        _ = await started.next()
        #expect(probes.callCount == 2, "three addresses wait for a slot")
        probes.release()
        await prober.settle()
        #expect(probes.callCount == 5 && probes.peak == 2)
        prober.stop()
    }

    @MainActor
    @Test func stoppingDropsWhatWasFoundAndIgnoresLaterAddresses() async throws {
        let probes = Probes(["10.77.20.5:7434": Self.identity(Self.mini, "Mac mini")])
        let prober = FleetNeighborProber(ports: [7434], probe: probes.probe, changed: {})
        prober.see(address: "10.77.20.5")
        await prober.settle()
        prober.stop()
        prober.see(address: "10.77.20.6")
        #expect(prober.answered.isEmpty && probes.callCount == 1)
    }
}
