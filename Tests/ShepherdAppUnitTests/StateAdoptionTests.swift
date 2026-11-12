import ShepherdCore
import Testing
@testable import ShepherdApp

/// Which of the host's snapshots the view model adopts: every one unless a newer one is already queued behind it.
@Suite("State adoption")
struct StateAdoptionTests {
    /// A workspace told apart from the others by its name.
    private func snapshot(_ name: String) -> ShepherdState {
        ShepherdState(spaces: [Space(name: name, path: "/tmp/\(name)")])
    }

    private func name(_ state: ShepherdState?) -> String? { state?.spaces.first?.name }

    @Test func aSnapshotWithNothingNewerIsAdopted() {
        var adoption = StateAdoption()
        #expect(name(adoption.received(snapshot("one"), newerQueued: false)) == "one")
        #expect(adoption.unadopted == nil)
        #expect(adoption.skipped == 0)
    }

    @Test func aBurstAdoptsOnlyItsLast() {
        var adoption = StateAdoption()
        var adopted: [String] = []
        for index in 0..<10 {
            if let next = adoption.received(snapshot("s\(index)"), newerQueued: index < 9) { adopted.append(name(next) ?? "") }
        }
        #expect(adopted == ["s9"])
        #expect(adoption.unadopted == nil)
        #expect(adoption.skipped == 0)
    }

    @Test func aDirectAdoptionDiscardsTheWaitingSnapshot() {
        var adoption = StateAdoption()
        #expect(adoption.received(snapshot("waiting"), newerQueued: true) == nil)
        #expect(adoption.skipped == 1)
        adoption.adoptedDirectly()
        #expect(adoption.unadopted == nil)
        #expect(adoption.skipped == 0)
        #expect(name(adoption.latest(snapshot("direct"))) == "direct")
    }

    @Test func latestIsTheNewestReceived() {
        var adoption = StateAdoption()
        let adopted = snapshot("adopted")
        #expect(name(adoption.latest(adopted)) == "adopted")
        #expect(adoption.received(snapshot("one"), newerQueued: true) == nil)
        #expect(name(adoption.latest(adopted)) == "one")
        #expect(adoption.received(snapshot("two"), newerQueued: true) == nil)
        #expect(name(adoption.latest(adopted)) == "two")
        #expect(name(adoption.received(snapshot("three"), newerQueued: false)) == "three")
        #expect(name(adoption.latest(snapshot("three"))) == "three")
    }

    @Test func aSteadyStreamIsAdoptedEveryMaxSkips() {
        var adoption = StateAdoption()
        var adoptedAt: [Int] = []
        for index in 1...(StateAdoption.maxSkips + 1) where adoption.received(snapshot("s\(index)"), newerQueued: true) != nil {
            adoptedAt.append(index)
        }
        #expect(adoptedAt == [StateAdoption.maxSkips + 1], "32 are skipped, the 33rd is adopted")
        #expect(adoption.skipped == 0)
        #expect(adoption.unadopted == nil)
    }
}
