import Foundation

/// Where a dispatch goes: a pure function of what the sending Mac knows of every Mac, with no I/O.
/// It reuses slice 3a's room (`FleetRoom`: the skips, the score, the 1.5x margin) and adds only
/// what dispatching needs: the repo, readiness and a named Mac. Every decision carries reason
/// codes (`FleetPlacementReason`), never prose.
///
/// A named Mac bypasses scoring and nothing else: a named Mac that lacks the repo or a tool is
/// refused with that reason, never quietly swapped for another.
public enum FleetPlacement {
    /// One Mac as the sender sees it.
    public struct Mac: Sendable, Hashable {
        public var hostID: UUID
        public var name: String
        /// The sending Mac itself.
        public var isLocal: Bool
        /// Its link is up (this Mac always is).
        public var connected: Bool
        /// It holds a checkout of the repo; nil when it hasn't said (no readiness report yet).
        public var hasRepo: Bool?
        /// Programs it lacks (`FleetReadinessReport.missing`), by name.
        public var problems: [String]
        public var sample: FleetPressureSample?
        /// Seconds since the sample arrived, by the sender's clock.
        public var sampleAge: TimeInterval?
        public var weight: FleetSendWeight
        /// Dispatches this sender has sent there that haven't started: counted on top of the
        /// sample's own reservations, so two dispatches in one moment don't pick one Mac.
        public var inFlight: Int

        public init(hostID: UUID, name: String, isLocal: Bool = false, connected: Bool = true, hasRepo: Bool? = nil,
                    problems: [String] = [], sample: FleetPressureSample? = nil, sampleAge: TimeInterval? = nil,
                    weight: FleetSendWeight = .normal, inFlight: Int = 0) {
            self.hostID = hostID
            self.name = name
            self.isLocal = isLocal
            self.connected = connected
            self.hasRepo = hasRepo
            self.problems = problems
            self.sample = sample
            self.sampleAge = sampleAge
            self.weight = weight
            self.inFlight = inFlight
        }
    }

    public enum Outcome: Hashable, Sendable {
        /// Send it to `hostID`.
        case place(hostID: UUID, reasons: [FleetPlacementReason])
        /// No Mac has room now: wait, and decide again when a sample changes.
        case waitForRoom
        /// The named Mac isn't connected: wait for it.
        case waitForWake(hostID: UUID, reasons: [FleetPlacementReason])
        /// Refused: a `FleetDispatchCode` and a detail.
        case refuse(code: String, detail: String?)
    }

    /// Finds the Mac a person or thread named: by name (any case) or by id.
    public static func named(_ host: String, in macs: [Mac]) -> Mac? {
        let wanted = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return macs.first { $0.name.lowercased() == wanted || $0.hostID.uuidString.lowercased() == wanted }
    }

    /// Whether `host` asks for Auto: nothing, or the word.
    public static func isAuto(_ host: String?) -> Bool {
        guard let host else { return true }
        let word = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return word.isEmpty || word == "auto"
    }

    public static func place(host: String?, macs: [Mac], batteryCountsHalf: Bool = true) -> Outcome {
        isAuto(host) ? auto(macs, batteryCountsHalf: batteryCountsHalf) : named(host ?? "", macs)
    }

    // MARK: Named

    private static func named(_ host: String, _ macs: [Mac]) -> Outcome {
        guard let mac = named(host, in: macs) else { return .refuse(code: FleetDispatchCode.noSuchHost, detail: host) }
        let reasons = [FleetPlacementReason(.named)]
        // A Mac that can't be reached is waited for; what it holds is checked when it answers.
        guard mac.connected else { return .waitForWake(hostID: mac.hostID, reasons: reasons) }
        if mac.hasRepo == false { return .refuse(code: FleetDispatchCode.repoMissing, detail: mac.name) }
        if let problem = mac.problems.first { return .refuse(code: FleetDispatchCode.hostNotReady, detail: problem) }
        // Connected but not yet heard from: there is nothing to check the repo against.
        if mac.hasRepo == nil { return .refuse(code: FleetDispatchCode.hostNotReady, detail: "unknown") }
        return .place(hostID: mac.hostID, reasons: reasons)
    }

    // MARK: Auto

    private static func auto(_ macs: [Mac], batteryCountsHalf: Bool) -> Outcome {
        let withRepo = macs.filter { $0.hasRepo == true }
        guard !withRepo.isEmpty else { return .refuse(code: FleetDispatchCode.repoMissing, detail: nil) }
        let usable = withRepo.filter { $0.connected && $0.problems.isEmpty }
        guard !usable.isEmpty else {
            // Every Mac that has the repo is up and missing a tool: waiting won't fix that.
            if withRepo.allSatisfy({ $0.connected && !$0.problems.isEmpty }), let problem = withRepo.first?.problems.first {
                return .refuse(code: FleetDispatchCode.hostNotReady, detail: problem)
            }
            return .waitForRoom
        }

        var counted: [(mac: Mac, score: Double)] = []
        var localSkip: String?
        for mac in usable {
            guard var sample = mac.sample, let age = mac.sampleAge else {
                if mac.isLocal { localSkip = FleetRoom.Skip.stale.rawValue }
                continue
            }
            if let skip = FleetRoom.skip(sample, age: age, weight: mac.weight) {
                if mac.isLocal { localSkip = skip.rawValue }
                continue
            }
            sample.reserved += mac.inFlight
            counted.append((mac, FleetRoom.score(sample, weight: mac.weight, batteryCountsHalf: batteryCountsHalf)))
        }
        // A local Mac that isn't usable at all (a tool missing here) is left out for that.
        if let local = withRepo.first(where: \.isLocal), !usable.contains(where: \.isLocal), !local.problems.isEmpty { localSkip = "notReady" }

        let local = usable.first(where: \.isLocal)
        let candidates = counted.map { FleetRoom.Candidate(id: $0.mac.hostID, score: $0.score) }
        guard let winnerID = FleetRoom.nextGoesTo(candidates, local: local?.hostID) else { return .waitForRoom }

        let scores = Dictionary(uniqueKeysWithValues: counted.map { ($0.mac.hostID, $0.score) })
        var reasons: [FleetPlacementReason] = []
        let localScore = local.flatMap { scores[$0.hostID] }
        if let localSkip, localScore == nil || localScore == 0 { reasons.append(FleetPlacementReason(.localIneligible, skip: localSkip)) }
        let others = counted.filter { $0.score > 0 && $0.mac.hostID != winnerID }
        if winnerID == local?.hostID, let localScore, localScore > 0 {
            // Stayed here: because nothing else counted, or because the best peer didn't clear the margin.
            if let best = others.map(\.score).max(), best > localScore {
                reasons.append(FleetPlacementReason(.keptLocal, ratio: best / localScore))
            } else {
                reasons.append(FleetPlacementReason(others.isEmpty ? .onlyChoice : .mostRoom))
            }
        } else if let localScore, localScore > 0, let winnerScore = scores[winnerID] {
            reasons.append(FleetPlacementReason(.mostRoom, ratio: winnerScore / localScore))
        } else {
            reasons.append(FleetPlacementReason(others.isEmpty ? .onlyChoice : .mostRoom))
        }
        return .place(hostID: winnerID, reasons: reasons)
    }
}
