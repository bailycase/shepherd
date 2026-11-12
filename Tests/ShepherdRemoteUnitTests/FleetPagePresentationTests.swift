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

    // MARK: A phone or an iPad reads the page (`FleetViewer.client`)

    static func clientPage(_ snapshot: FleetSnapshot = snapshot(), weights: [UUID: FleetSendWeight] = [:]) -> FleetPage {
        FleetPagePresentation.make(snapshot: snapshot, weight: { weights[$0] ?? .normal }, viewer: .client, locale: en, calendar: utc)
    }

    @Test func aClientNamesTheMacItAskedAndHasNoThisMac() {
        let page = Self.clientPage()
        #expect(page.cards.map(\.name) == ["MacBook Pro", "Mac mini", "Mac Studio"])
        #expect(page.cards.map(\.statusText) == ["Connected", "Connected", "Asleep"])
        #expect(page.cards.allSatisfy { !$0.isThisMac })
        // The same derivations: nothing about room, readings or the next Mac changes for a client.
        let mac = Self.page()
        #expect(page.nextGoesTo == mac.nextGoesTo && page.summary == mac.summary)
        #expect(zip(page.cards, mac.cards).allSatisfy { $0.0.room == $0.1.room && $0.0.cpu == $0.1.cpu && $0.0.power == $0.1.power })
        #expect(page.cards[0].weightLabel == "Send work to MacBook Pro")
    }

    @Test func aClientsFooterNeverSaysThisMac() {
        #expect(Self.clientPage().footer.detail == "1 asleep" && Self.clientPage().footer.label == "Fleet: 3 Macs, Mac Studio asleep")
        var alone = Self.snapshot()
        alone.peers = []
        #expect(Self.clientPage(alone).footer.detail == "One Mac")
        #expect(Self.clientPage(Self.snapshot(studioLink: .connected)).footer.detail == "All awake")
    }

    @Test func aMacWithNoNameIsStillNamedForAClient() {
        var snapshot = Self.snapshot()
        snapshot.name = ""
        #expect(Self.clientPage(snapshot).cards[0].name == "Mac")
    }

    @Test func aClientTakesTheWeightsItIsGiven() {
        let page = Self.clientPage(weights: [Self.mini: .prefer, Self.studio: .manualOnly])
        #expect(page.cards.map(\.weight) == [.normal, .prefer, .manualOnly])
    }

    // MARK: Compact rows (FleetA-phone, DuoOpenFleet, DuoClosedFleet)

    @Test func theFactsLineOfARowIsWhatEachBoardDraws() {
        let page = Self.clientPage()
        let here = page.cards[0], mini = page.cards[1], studio = page.cards[2]
        #expect(here.facts(.phone) == "CPU 72% · 9.4 GB free · battery 41% · warm")
        #expect(mini.facts(.phone) == "CPU 18% · 41 GB free · plugged in")
        #expect(here.facts(.duo) == "CPU 72% · 9.4 GB free · battery 41% · warm · 3 working")
        #expect(mini.facts(.duo) == "CPU 18% · 41 GB free · plugged in · 3 working")
        #expect(here.facts(.compact) == "CPU 72% · battery 41% · warm")
        #expect(mini.facts(.compact) == "CPU 18% · 41 GB free")
        for style in [FleetFactsStyle.phone, .duo, .compact] { #expect(studio.facts(style) == "since 22:42") }
    }

    @Test func aRowSaysWhatItKnowsOfAMacThatHasNoReadingOrWasNeverReached() {
        var snapshot = Self.snapshot(miniLink: .connecting)
        snapshot.macs.removeAll { $0.hostID == Self.mini }
        snapshot.peers[1].lastSeen = nil
        let page = Self.clientPage(snapshot)
        #expect(page.cards[1].facts(.phone) == "Waiting for a reading")
        #expect(page.cards[2].facts(.phone) == "not reached yet")
    }

    @Test func aRowDropsTheThreadsWorkingWhenNoneWorks() {
        var snapshot = Self.snapshot()
        snapshot.macs[1].sample?.activeAgents = 0
        #expect(Self.clientPage(snapshot).cards[1].facts(.duo) == "CPU 18% · 41 GB free · plugged in")
    }

    @Test func aRowsRoomWordAndLabelFollowTheMacsState() {
        let page = Self.clientPage()
        #expect(page.cards.map(\.rowRoom) == ["Little room", "Most room", "Asleep"])
        #expect(page.cards.map(\.rowLabel) == ["MacBook Pro, little room", "Mac mini, most room", "Mac Studio, asleep"])
    }

    @Test func aBatteryMacWithNoPercentSaysOnBattery() {
        var snapshot = Self.snapshot()
        snapshot.macs[0].sample?.batteryPercent = nil
        snapshot.macs[0].sample?.thermal = .nominal
        let here = Self.clientPage(snapshot).cards[0]
        #expect(here.powerFact == "on battery" && here.facts(.compact) == "CPU 72% · on battery")
    }
}
