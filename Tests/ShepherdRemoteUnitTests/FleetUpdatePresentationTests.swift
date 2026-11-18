import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Update Shepherd on a Mac as Fleet ▸ Check and the Mac card draw it: the offer on the Shepherd row of a Mac that is behind, its words in each stage
/// of the job the host keeps, and what stays out (a Mac that is current, set aside, or runs a Shepherd that can't be asked).
@Suite("Fleet update presentation")
struct FleetUpdatePresentationTests {
    typealias C = FleetCheckPresentationTests
    static let studio = C.studio, mini = C.mini

    static func job(_ stage: FleetUpdateStatus.Stage, when: FleetUpdateWhen = .idle, threads: Int? = nil, message: String? = nil) -> FleetUpdateStatus {
        FleetUpdateStatus(hostID: studio, stage: stage, when: when, fromBuild: "671", threads: threads, message: message, startedAt: 1, updatedAt: 2)
    }

    /// The board's snapshot with `job` carried out on Mac Studio (the Mac that runs build 671), and whether the Macs say they can be asked.
    /// `onlyBehind`: the build is all Mac Studio needs (its sleep setting is fine).
    static func page(_ job: FleetUpdateStatus? = nil, takes: Bool? = true, working: Int? = nil, ignored: Bool = false, onlyBehind: Bool = false) -> FleetPage {
        var snapshot = C.snapshot()
        // Mac Studio is awake here, so its card says what it needs.
        let index = snapshot.macs.firstIndex { $0.hostID == studio }!
        snapshot.peers[1].link = .connected
        snapshot.macs[index].sample = snapshot.macs.first { $0.hostID == mini }?.sample
        snapshot.macs[index].sampleAge = 2
        if onlyBehind { snapshot.macs[index].check?.items.removeAll { $0.id == "sleep" } }
        snapshot.updates = job.map { [$0] } ?? []
        for index in snapshot.peers.indices { snapshot.peers[index].takesUpdates = takes }
        snapshot.macs[index].sample?.activeAgents = working ?? 0
        return C.page(snapshot, ignored: ignored ? [studio: ["build"]] : [:])
    }

    @Test func aMacBehindTheFleetOffersToUpdateAndNamesTheBuild() {
        let page = Self.page(onlyBehind: true)
        let offer = page.check.detail(row: "build", mac: Self.studio).update
        #expect(offer?.headline == "Shepherd 675 is ready for Mac Studio")
        #expect(offer?.buttonTitle == "Update Shepherd on Mac Studio")
        #expect(offer?.canStart == true && offer?.running == nil && offer?.nowTitle == nil)
        #expect(page.check.behindBuild(of: Self.studio) == "671")
        #expect(page.cards.first { $0.id == Self.studio }?.ready.text == "Behind · build 671")
        #expect(page.cards.first { $0.id == Self.studio }?.behindBuild == "671")
        // The Macs on the newest build offer nothing.
        #expect(page.check.detail(row: "build", mac: Self.mini).update == nil && page.check.behindBuild(of: Self.mini) == nil)
        #expect(page.check.updateOffers.map(\.mac) == [Self.studio])
    }

    @Test func aMacBehindAndNeedingMoreKeepsTheOrdinaryReadyLine() {
        let card = Self.page().cards.first { $0.id == Self.studio }
        #expect(card?.ready.text == "Needs 2 · build 671, sleep")
        #expect(card?.behindBuild == "671", "Update… is still offered")
    }

    @Test func aMacSetAsideOffersNothing() {
        let page = Self.page(ignored: true)
        #expect(page.check.behindBuild(of: Self.studio) == nil && page.check.updatable.isEmpty && page.check.updateOffers.isEmpty)
    }

    @Test func threadsWorkingThereAreNamedOnUpdateNow() {
        #expect(Self.page(working: 2).check.updateOffers.first?.nowTitle == "Update now, stopping 2 threads")
        #expect(Self.page(working: 1).check.updateOffers.first?.nowTitle == "Update now, stopping 1 thread")
    }

    @Test func aMacOnAShepherdThatCantBeAskedSaysToUpdateItThere() {
        let page = Self.page(takes: false)
        let offer = page.check.updateOffers.first
        #expect(offer?.canStart == false && offer?.note.hasPrefix("Update Shepherd on Mac Studio yourself.") == true)
        #expect(page.check.updatable.isEmpty, "Update every Mac skips a Mac that can't be asked")
    }

    @Test(arguments: [
        (FleetUpdateStatus.Stage.waitingToWake, "Waiting for Mac Studio to wake"),
        (.checking, "Asking Mac Studio’s update feed"),
        (.downloading, "Downloading 675"),
        (.waitingForThreads, "Waiting for its threads to go idle"),
        (.installing, "Installing"),
        (.relaunching, "Relaunching"),
    ])
    func eachStageOfTheJobHasItsStateAndCancel(stage: FleetUpdateStatus.Stage, state: String) {
        let running = Self.page(Self.job(stage)).check.updateOffers.first?.running
        #expect(running?.state == state && running?.cancellable == true)
    }

    @Test func waitingNamesTheThreadsItWaitsFor() {
        #expect(Self.page(Self.job(.waitingForThreads, threads: 2)).check.updateOffers.first?.running?.state == "Waiting for 2 threads to go idle")
        #expect(Self.page(Self.job(.waitingForThreads, threads: 1)).check.updateOffers.first?.running?.state == "Waiting for 1 thread to go idle")
    }

    @Test func aRunningUpdateIsNotOfferedAgainByUpdateEveryMac() {
        #expect(Self.page().check.updatable == [Self.studio])
        #expect(Self.page(Self.job(.downloading)).check.updatable.isEmpty)
    }

    @Test func anUpdateThatEndedBadlyShowsWhyAndOffersTheButtonAgain() {
        let offer = Self.page(Self.job(.failed, message: "The signature didn’t match.")).check.updateOffers.first
        #expect(offer?.running == nil && offer?.problem == "The signature didn’t match." && offer?.failed == true && offer?.canStart == true)
        let none = Self.page(Self.job(.upToDate, message: "Its feed offers nothing newer.")).check.updateOffers.first
        #expect(none?.problem == "Its feed offers nothing newer." && none?.failed == false)
    }
}
