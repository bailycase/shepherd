import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// The Fleet page's cards, summary, winner and footer from a snapshot and the weights.
@Suite("Fleet page presentation")
struct FleetPagePresentationTests {
    static let gib: UInt64 = 1 << 30
    static let here = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let mini = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let studio = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
    static let en = Locale(identifier: "en_GB")
    static var utc: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; return calendar }

    /// FleetA's three Macs: a MacBook Pro on battery at 72% CPU, a Mac mini with room that lacks
    /// the muse CLI, and a Mac Studio that is asleep.
    static func snapshot(minis age: Double = 2, miniLink: FleetPeerStatus.Link = .connected, studioLink: FleetPeerStatus.Link = .offline) -> FleetSnapshot {
        FleetSnapshot(
            enabled: true, hostID: here, name: "MacBook Pro", port: 7434,
            peers: [FleetPeerStatus(hostID: mini, name: "Mac mini", pairedAt: 1, link: miniLink),
                    FleetPeerStatus(hostID: studio, name: "Mac Studio", pairedAt: 2, link: studioLink, lastSeen: 1_790_030_520_000)],
            macs: [
                FleetMacState(hostID: here, sample: FleetPressureSample(cpuUtilization: 0.72, cpuCount: 12, totalMemoryBytes: 36 * gib,
                                                                         availableMemoryBytes: UInt64(9.4 * Double(gib)), thermal: .fair, onBattery: true,
                                                                         batteryPercent: 41, activeAgents: 3), sampleAge: 1,
                              readiness: FleetReadinessReport(model: "MacBook Pro", chip: "M4 Pro", repos: ["shepherd", "payments-api", "web"])),
                FleetMacState(hostID: mini, sample: FleetPressureSample(cpuUtilization: 0.18, cpuCount: 14, totalMemoryBytes: 64 * gib,
                                                                         availableMemoryBytes: 41 * gib, activeAgents: 3), sampleAge: age,
                              readiness: FleetReadinessReport(model: "Mac mini", chip: "M4 Pro", missing: [FleetMissingTool(kind: .binary, name: "muse")],
                                                              repos: ["shepherd", "payments-api", "orders-svc"])),
                FleetMacState(hostID: studio, readiness: FleetReadinessReport(model: "Mac Studio", chip: "M3 Ultra", repos: ["shepherd", "ml-eval"])),
            ])
    }

    static func page(_ snapshot: FleetSnapshot = snapshot(), weights: [UUID: FleetSendWeight] = [:], snapshotAge: TimeInterval = 0) -> FleetPage {
        FleetPagePresentation.make(snapshot: snapshot, weight: { weights[$0] ?? .normal }, snapshotAge: snapshotAge, locale: en, calendar: utc)
    }

    static func card(_ id: UUID, _ page: FleetPage) -> FleetMacCard { page.cards.first { $0.id == id }! }

    // MARK: Cards

    @Test func theCardsAreThisMacThenEachPairedMacInOrder() {
        let page = Self.page()
        #expect(page.cards.map(\.name) == ["This Mac", "Mac mini", "Mac Studio"])
        #expect(page.cards.map(\.statusText) == ["This Mac", "Connected", "Asleep"])
        #expect(page.cards.map(\.isThisMac) == [true, false, false])
    }

    @Test func theMacWithTheMostRoomIsSaidToHaveIt() {
        let page = Self.page()
        let here = Self.card(Self.here, page), mini = Self.card(Self.mini, page)
        #expect(mini.room.text == "Most room" && mini.room.tone == .good && mini.room.fraction == 1)
        #expect(here.room.text == "Little room" && here.room.tone == .warn)
        #expect(here.room.fraction > 0 && here.room.fraction < 0.3, "its share of the best: \(here.room.fraction)")
    }

    @Test func aMacCountedAloneIsJudgedOnItsOwnNotAgainstNobody() {
        var snapshot = Self.snapshot()
        snapshot.peers = []
        snapshot.macs = [snapshot.macs[0]]
        // 28% of the CPU and 26% of the memory free: 7% of the Mac.
        #expect(Self.card(Self.here, Self.page(snapshot)).room.text == "Little room")
        snapshot.macs[0].sample?.cpuUtilization = 0.1
        snapshot.macs[0].sample?.availableMemoryBytes = 30 * Self.gib
        let roomy = Self.card(Self.here, Self.page(snapshot))
        #expect(roomy.room.text == "Room to spare" && roomy.room.tone == .good)
        #expect(Self.page(snapshot).nextGoesTo == "This Mac")
    }

    @Test func readingsAreWordedAsTheBoardDrawsThem() {
        let page = Self.page()
        let here = Self.card(Self.here, page), mini = Self.card(Self.mini, page)
        #expect(here.cpu?.text == "72%" && here.cpu?.tone == .warn)
        #expect(mini.cpu?.text == "18%" && mini.cpu?.tone == .good)
        #expect(here.memory?.text == "9.4 GB free" && mini.memory?.text == "41 GB free")
        #expect(abs((here.memory?.fraction ?? 0) - (1 - 9.4 / 36)) < 0.001, "memory's gauge is what is used")
        #expect(here.power.text == "Battery 41% · warm · counts half" && here.power.tone == .warn)
        #expect(mini.power.text == "Plugged in · cool" && mini.power.tone == .primary)
        #expect(here.agents == "3 working" && mini.agents == "3 working")
        #expect(here.hardware == "MacBook Pro · M4 Pro · 36 GB" && mini.hardware == "Mac mini · M4 Pro · 64 GB")
    }

    @Test func aMacsRepoTagsAreWhatItsReadinessListed() {
        let page = Self.page()
        #expect(Self.card(Self.mini, page).repos == ["shepherd", "payments-api", "orders-svc"])
        #expect(Self.card(Self.studio, page).repos == ["shepherd", "ml-eval"], "an asleep Mac keeps what it last said")
    }

    @Test func batteryOnlyHalvesWhenTheFleetCountsIt() {
        let counted = FleetPagePresentation.make(snapshot: Self.snapshot(), weight: { _ in .normal }, batteryCountsHalf: true)
        let notCounted = FleetPagePresentation.make(snapshot: Self.snapshot(), weight: { _ in .normal }, batteryCountsHalf: false)
        #expect(Self.card(Self.here, counted).power.text.hasSuffix("counts half"))
        #expect(!Self.card(Self.here, notCounted).power.text.contains("counts half"))
        #expect(Self.card(Self.here, notCounted).room.fraction > Self.card(Self.here, counted).room.fraction)
    }

    // MARK: Ready

    @Test func readyShowsFactsAndNoActionAndSaysEveryModelAndToolWhenNothingIsMissing() {
        let page = Self.page()
        #expect(Self.card(Self.here, page).ready == FleetLine(text: "Every model and tool", tone: .good))
        #expect(Self.card(Self.mini, page).ready == FleetLine(text: "muse CLI isn’t installed", tone: .warn))
    }

    @Test(arguments: [
        ([FleetMissingTool(kind: .xcode)], "Xcode isn’t installed"),
        ([FleetMissingTool(kind: .git)], "git isn’t installed"),
        ([FleetMissingTool(kind: .binary, name: "muse"), FleetMissingTool(kind: .xcode)], "muse CLI and Xcode aren’t installed"),
        ([FleetMissingTool(kind: .binary, name: "a"), FleetMissingTool(kind: .binary, name: "b"), FleetMissingTool(kind: .git)], "a CLI, b CLI and git aren’t installed"),
        ([FleetMissingTool(kind: .binary, name: "a"), FleetMissingTool(kind: .binary, name: "b"), FleetMissingTool(kind: .binary, name: "c"),
          FleetMissingTool(kind: .binary, name: "d"), FleetMissingTool(kind: .xcode)], "a CLI, b CLI and 3 more aren’t installed"),
    ] as [([FleetMissingTool], String)])
    func aMissingToolIsNamedAndNothingMore(missing: [FleetMissingTool], words: String) {
        #expect(FleetPagePresentation.missingText(missing) == words)
    }

    @Test func aMacThatHasntReportedYetSaysItIsChecking() {
        var snapshot = Self.snapshot()
        snapshot.macs.removeAll { $0.hostID == Self.mini }
        let mini = Self.card(Self.mini, Self.page(snapshot))
        #expect(mini.ready == FleetLine(text: "Checking…", tone: .tertiary))
        #expect(mini.cpu == nil && mini.agents == "—" && mini.room.text == "Not counted")
    }

    // MARK: Asleep, stale and skipped

    @Test func anAsleepMacIsNotCountedAndSaysWhenItWasSeen() {
        let studio = Self.card(Self.studio, Self.page())
        #expect(studio.status == .asleep && studio.canRetry)
        #expect(studio.room == FleetMetric(fraction: 0, text: "Not counted", tone: .tertiary))
        #expect(studio.cpu == nil && studio.memory == nil && studio.agents == "—")
        #expect(studio.power == FleetLine(text: "Last seen 22:42", tone: .tertiary))
        #expect(studio.ready == FleetLine(text: "Catches up when it wakes", tone: .tertiary))
        #expect(studio.note == "Asleep since 22:42. Nothing moves to another Mac; it catches up when it wakes.")
    }

    @Test func aMacNeverReachedIsOfflineNotAsleep() {
        var snapshot = Self.snapshot()
        snapshot.peers[1].lastSeen = nil
        let studio = Self.card(Self.studio, Self.page(snapshot))
        #expect(studio.statusText == "Offline" && studio.power.text == "Not seen yet")
        #expect(studio.note == "Not reachable yet. Nothing moves to another Mac.")
    }

    @Test func aSampleOlderThanFifteenSecondsIsNotShownOrCounted() {
        let stale = Self.card(Self.mini, Self.page(Self.snapshot(minis: 16)))
        #expect(stale.room.text == "Not counted" && stale.cpu == nil && stale.power.text == "Waiting for a reading")
        #expect(stale.statusText == "Connected", "the link is up; only the reading is old")
        let fresh = Self.card(Self.mini, Self.page(Self.snapshot(minis: 15)))
        #expect(fresh.cpu?.text == "18%")
    }

    @Test func aSnapshotHeldLongEnoughMakesItsSamplesStaleOnScreen() {
        // No new snapshot came: the device's own clock ages what it holds.
        let page = Self.page(Self.snapshot(minis: 10), snapshotAge: 15)
        #expect(Self.card(Self.mini, page).room.text == "Not counted")
        #expect(Self.card(Self.here, page).room.text == "Not counted", "This Mac's own sample ages the same way")
    }

    @Test func aMacAtItsCpuCeilingHasNoRoomButShowsItsNumbers() {
        var snapshot = Self.snapshot()
        snapshot.macs[1].sample?.cpuUtilization = 0.97
        let mini = Self.card(Self.mini, Self.page(snapshot))
        #expect(mini.room == FleetMetric(fraction: 0, text: "No room", tone: .bad))
        #expect(mini.cpu?.text == "97%" && mini.cpu?.tone == .bad)
    }

    @Test func aHotMacShowsItAndHasNoRoom() {
        var snapshot = Self.snapshot()
        snapshot.macs[1].sample?.thermal = .serious
        let mini = Self.card(Self.mini, Self.page(snapshot))
        #expect(mini.room.text == "No room" && mini.power == FleetLine(text: "Plugged in · hot", tone: .bad))
    }

    @Test func aConnectingMacIsShownAsConnectingAndNotCountedWithoutAReading() {
        var snapshot = Self.snapshot(miniLink: .connecting)
        snapshot.macs.removeAll { $0.hostID == Self.mini }
        let mini = Self.card(Self.mini, Self.page(snapshot))
        #expect(mini.statusText == "Connecting" && mini.status == .connecting && !mini.canRetry)
    }

    // MARK: Weights and the next Mac

    @Test func nextGoesToTheMacWithTheMostRoomAndNothingIsImpliedWhenNoneCounts() {
        #expect(Self.page().nextGoesTo == "Mac mini")
        var snapshot = Self.snapshot()
        snapshot.macs = []
        #expect(Self.page(snapshot).nextGoesTo == nil)
    }

    @Test func manualOnlyTakesAMacOutOfAutoButNotOffThePage() {
        let page = Self.page(weights: [Self.mini: .manualOnly])
        #expect(page.nextGoesTo == "This Mac")
        let mini = Self.card(Self.mini, page)
        #expect(mini.weight == .manualOnly && mini.room.text == "Not counted" && mini.cpu?.text == "18%")
        #expect(mini.weightLabel == "Send work to Mac mini")
    }

    @Test func preferCanTipAMacOverThisOneButLessOftenCanLoseIt() {
        let prefer = Self.page(weights: [Self.here: .prefer])
        let lessOften = Self.page(weights: [Self.mini: .lessOften])
        // Mini's score 14 * 0.82 * 0.64 / 4 = 1.84; this Mac's 12 * 0.28 * 0.26 / 4 / 2 = 0.109.
        #expect(prefer.nextGoesTo == "Mac mini", "1.5 on this Mac is nowhere near enough")
        #expect(lessOften.nextGoesTo == "Mac mini", "0.92 still clears the 1.5 margin over this Mac")
    }

    @Test func aBusyThisMacKeepsWorkUnlessThePeerClearsTheMargin() {
        // Two near equal Macs: no flapping.
        var snapshot = Self.snapshot()
        snapshot.macs[0].sample = FleetPressureSample(cpuUtilization: 0.2, cpuCount: 14, totalMemoryBytes: 64 * Self.gib, availableMemoryBytes: 40 * Self.gib, activeAgents: 3)
        snapshot.macs[1].sample?.availableMemoryBytes = 42 * Self.gib
        snapshot.macs[0].sampleAge = 1
        #expect(Self.page(snapshot).nextGoesTo == "This Mac")
    }

    // MARK: Header and footer

    @Test func theSummaryCountsMacsAsleepAndThreadsWorking() {
        #expect(Self.page().summary == "3 Macs · 1 asleep · 6 threads working")
        var alone = Self.snapshot()
        alone.peers = []
        alone.macs = [alone.macs[0]]
        alone.macs[0].sample?.activeAgents = 1
        #expect(Self.page(alone).summary == "1 Mac · 1 thread working")
        alone.macs[0].sample?.activeAgents = 0
        #expect(Self.page(alone).summary == "1 Mac · no threads working")
    }

    @Test func theFooterDrawsADotPerMacAndCountsTheAsleep() {
        let footer = Self.page().footer
        #expect(footer.dots == [.thisMac, .connected, .asleep])
        #expect(footer.detail == "1 asleep" && footer.paletteDetail == "1 asleep")
        #expect(footer.label == "Fleet: 3 Macs, Mac Studio asleep")
    }

    @Test func theFooterSaysAllAwakeOrJustThisMacWhenNoneSleeps() {
        let awake = Self.page(Self.snapshot(studioLink: .connected)).footer
        #expect(awake.detail == "All awake" && awake.paletteDetail == nil && awake.label == "Fleet: 3 Macs")
        var alone = Self.snapshot()
        alone.peers = []
        #expect(Self.page(alone).footer.detail == "Just this Mac")
    }

    @Test func aFleetThatIsOffDrawsNothing() {
        #expect(FleetPagePresentation.make(snapshot: FleetSnapshot(), weight: { _ in .normal }) == .empty)
        #expect(FleetPage.empty.cards.isEmpty)
    }

    @Test(arguments: [(UInt64(9.4 * 1_073_741_824), "9.4 GB"), (UInt64(10 * 1_073_741_824), "10 GB"), (UInt64(41 * 1_073_741_824), "41 GB"), (0, "0.0 GB")] as [(UInt64, String)])
    func memoryIsInBinaryGigabytesWithADecimalUnderTen(bytes: UInt64, text: String) {
        #expect(FleetPagePresentation.memory(bytes) == text)
    }

    // MARK: Dispatches log

    @Test func theDispatchesLogReadsNewestFirstWithWhereAndWhy() {
        let now = Date(timeIntervalSince1970: 1_790_040_000)
        func record(_ title: String, _ state: FleetDispatchState, ago: TimeInterval, kind: FleetDispatchRecord.Kind = .agentDispatch, host: String? = "Mac mini",
                    reasons: [FleetPlacementReason] = [], failure: String? = nil) -> FleetDispatchRecord {
            FleetDispatchRecord(kind: kind, parentHostID: Self.here, parentHostName: "MacBook Pro", parentTitle: kind == .userThread ? "" : "Speed up checkout CI",
                                targetHostName: host, state: state, failure: failure, title: title, task: "", repoKey: "github.com/acme/web",
                                reasonCodes: reasons, createdAt: (now.timeIntervalSince1970 - ago) * 1000)
        }
        var snapshot = Self.snapshot()
        snapshot.dispatches = [
            record("Old", .done, ago: 3_600, reasons: [FleetPlacementReason(.mostRoom)]),
            record("Fix flaky payment test", .running, ago: 240, reasons: [FleetPlacementReason(.localIneligible, skip: "cpu"), FleetPlacementReason(.mostRoom)]),
            record("Migrate orders", .running, ago: 1_320, kind: .userThread, reasons: [FleetPlacementReason(.named)]),
            record("Profile cold launch", .waitingWake, ago: 7_200, kind: .userThread, host: "Mac Studio"),
            record("Bump tools", .failed, ago: 60, host: nil, failure: FleetDispatchCode.repoMissing),
        ]
        let rows = FleetPagePresentation.make(snapshot: snapshot, weight: { _ in .normal }, locale: Self.en, calendar: Self.utc, now: now).dispatches
        #expect(rows.map(\.title) == ["Bump tools", "Fix flaky payment test", "Migrate orders", "Old", "Profile cold launch"])
        let byTitle = Dictionary(uniqueKeysWithValues: rows.map { ($0.title, $0) })
        let fix = byTitle["Fix flaky payment test"]!
        #expect(fix.sentBy == "Sent by Speed up checkout CI" && fix.host == "Mac mini" && fix.state == "Working" && fix.tone == .active && fix.age == "4m ago")
        #expect(fix.reason == "Auto: This Mac is busy")
        #expect(byTitle["Migrate orders"]?.sentBy == "Sent by you" && byTitle["Migrate orders"]?.reason == "You picked Mac mini")
        #expect(byTitle["Old"]?.reason == "Auto: most room" && byTitle["Old"]?.state == "Done" && byTitle["Old"]?.tone == .good)
        #expect(byTitle["Profile cold launch"]?.state == "Waiting" && byTitle["Profile cold launch"]?.reason == "Waiting for Mac Studio to wake")
        let failed = byTitle["Bump tools"]!
        #expect(failed.state == "Failed" && failed.tone == .bad && failed.host == "No Mac yet" && failed.reason == "That Mac doesn't have this repository")
    }

    @Test func noDispatchesLeavesTheLogEmpty() {
        #expect(Self.page().dispatches.isEmpty)
    }
}
