import Foundation
import ShepherdCore
import ShepherdTestKit
import Testing
@testable import ShepherdApp

/// The Activity sidebar's pins (Sidebar › Pinned): which threads, in what order, kept how.
@Suite("Sidebar pins")
struct SidebarPinsTests {
    private let a = PinnedThread.local(AgentID(rawValue: "a"))
    private let b = PinnedThread.local(AgentID(rawValue: "b"))
    private let c = PinnedThread.local(AgentID(rawValue: "c"))
    private let host = UUID()

    private func remote(_ agent: String, host: UUID? = nil) -> PinnedThread {
        .remote(RemoteAgentRef(hostID: host ?? self.host, agentID: AgentID(rawValue: agent)))
    }

    @Test func threadsAreListedInTheOrderTheyWerePinned() {
        var pins = SidebarPins()
        pins.pin(b)
        pins.pin(a)
        pins.pin(c)
        #expect(pins.threads == [b, a, c])
    }

    @Test func pinningAPinnedThreadAgainChangesNothing() {
        var pins = SidebarPins([a, b])
        let changed = pins.pin(a)
        #expect(!changed)
        #expect(pins.threads == [a, b])
    }

    @Test func unpinningKeepsTheOthersInOrder() {
        var pins = SidebarPins([a, b, c])
        let removed = pins.unpin(b)
        #expect(removed)
        #expect(pins.threads == [a, c])
        let removedAgain = pins.unpin(b)
        #expect(!removedAgain)
        #expect(pins.threads == [a, c])
    }

    @Test func togglingPinsLastThenUnpins() {
        var pins = SidebarPins([a])
        let pinnedB = pins.toggle(b)
        #expect(pinnedB)
        #expect(pins.threads == [a, b])
        let pinnedA = pins.toggle(a)
        #expect(!pinnedA)
        #expect(pins.threads == [b])
        let pinnedAgain = pins.toggle(a)
        #expect(pinnedAgain)
        #expect(pins.threads == [b, a])
    }

    @Test func repeatedThreadsKeepTheirFirstPlace() {
        #expect(SidebarPins([a, b, a, c, b]).threads == [a, b, c])
    }

    @Test func aRemoteThreadIsNotALocalOneOfTheSameId() {
        var pins = SidebarPins([remote("a")])
        #expect(!pins.contains(a))
        let pinnedLocal = pins.pin(a)
        #expect(pinnedLocal)
        #expect(pins.threads == [remote("a"), a])
        #expect(pins.contains(remote("a", host: host)))
        #expect(!pins.contains(remote("a", host: UUID())))
    }

    @Test(arguments: [
        SidebarRowID.local(AgentID(rawValue: "a")),
        .remote(RemoteAgentRef(hostID: UUID(uuidString: "0A2B4C6D-1111-4222-8333-444455556666")!, agentID: AgentID(rawValue: "b"))),
    ])
    func aRowNamesItsThreadAndBack(row: SidebarRowID) throws {
        let thread = try #require(PinnedThread(row))
        #expect(thread.row == row)
        #expect(PinnedThread(key: thread.key) == thread)
    }

    @Test func aDesignIsNeverPinned() {
        #expect(PinnedThread(.design(DesignID(rawValue: "d"))) == nil)
    }

    @Test(arguments: ["", "local", "local:", ":a", "nothost:a", "0A2B4C6D-1111-4222-8333-444455556666:"])
    func aKeyNothingReadsNamesNoThread(key: String) {
        #expect(PinnedThread(key: key) == nil)
    }

    @Test func pinsSurviveARelaunchInOrder() {
        let defaults = ScratchDefaults()
        var pins = SidebarPins()
        pins.pin(remote("r"))
        pins.pin(b)
        pins.pin(a)
        pins.save(to: defaults)
        #expect(SidebarPins(defaults: defaults) == pins)
        #expect(SidebarPins(defaults: defaults).threads == [remote("r"), b, a])
    }

    @Test func nothingStoredMeansNothingPinned() {
        #expect(SidebarPins(defaults: ScratchDefaults()).isEmpty)
    }

    /// A key another version wrote, or a hand edit broke, is dropped rather than refusing the rest.
    @Test func storedKeysNothingReadsAreDropped() {
        let defaults = ScratchDefaults()
        defaults.set(["local:a", "garbage", "local:b", "local:a"], forKey: SidebarPins.defaultsKey)
        #expect(SidebarPins(defaults: defaults).threads == [a, b])
    }

    @Test func thePinsKeyIsBesideTheSidebarsOtherChoices() {
        #expect(SidebarPins.defaultsKey == "shepherd.sidebar.pinned")
    }

    // MARK: Pruning

    @Test func aLocalThreadThatIsGoneIsPruned() {
        var pins = SidebarPins([a, b, c])
        let pruned = pins.prune(localAgents: [AgentID(rawValue: "a"), AgentID(rawValue: "c")], configuredHosts: [], hostAgents: [:])
        #expect(pruned)
        #expect(pins.threads == [a, c])
    }

    @Test func nothingGoneMeansNoChange() {
        var pins = SidebarPins([a, remote("r")])
        let pruned = pins.prune(localAgents: [AgentID(rawValue: "a")], configuredHosts: [host],
                                hostAgents: [host: [AgentID(rawValue: "r")]])
        #expect(!pruned)
        #expect(pins.threads == [a, remote("r")])
    }

    @Test func aRemovedHostTakesItsPinsWithIt() {
        let other = UUID()
        var pins = SidebarPins([remote("r"), remote("s", host: other), a])
        let pruned = pins.prune(localAgents: [AgentID(rawValue: "a")], configuredHosts: [other], hostAgents: [:])
        #expect(pruned)
        #expect(pins.threads == [remote("s", host: other), a])
    }

    @Test func aThreadDeletedOnItsHostIsPruned() {
        var pins = SidebarPins([remote("r"), remote("s")])
        let pruned = pins.prune(localAgents: [], configuredHosts: [host], hostAgents: [host: [AgentID(rawValue: "s")]])
        #expect(pruned)
        #expect(pins.threads == [remote("s")])
    }

    /// Before a host connects this launch, nothing says its threads are gone.
    @Test func aHostThatHasSentNothingKeepsItsPins() {
        var pins = SidebarPins([remote("r")])
        let pruned = pins.prune(localAgents: [], configuredHosts: [host], hostAgents: [:])
        #expect(!pruned)
        #expect(pins.threads == [remote("r")])
    }
}
