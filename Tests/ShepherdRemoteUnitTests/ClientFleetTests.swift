import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// A Mac a phone reads the fleet from: a snapshot it answers with, and its host settings (the weights).
final class FakeFleetClient: FakeSettingsClient, FleetViewClient, @unchecked Sendable {
    private let state = NSLock()
    private var answer: Result<FleetSnapshot, RemoteHostClientError>
    private var calls: [String] = []

    init(_ snapshot: FleetSnapshot) {
        answer = .success(snapshot)
        super.init()
    }

    var fleetCalls: [String] { state.withLock { calls } }
    func answers(_ result: Result<FleetSnapshot, RemoteHostClientError>) { state.withLock { answer = result } }

    func fleetRead() async throws -> FleetResult {
        try state.withLock {
            calls.append("read")
            return FleetResult(snapshot: try answer.get())
        }
    }

    func fleetWatching(_ on: Bool) async throws { state.withLock { calls.append("watching(\(on))") } }
}

@MainActor
@Suite("Client fleet")
struct ClientFleetTests {
    typealias Page = FleetPagePresentationTests

    static func host(_ name: String, _ client: (any SettingsClient)?, id: UUID = UUID(), view: Bool = true) -> SettingsHost {
        SettingsHost(id: id, name: name, client: client, capabilities: Set([RemoteProtocol.hostSettingsCapability] + (view ? [RemoteProtocol.fleetViewCapability] : [])))
    }

    static func fleet(_ time: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> ClientFleet {
        let fleet = ClientFleet(hostSettings: ClientHostSettings())
        fleet.now = { time }
        return fleet
    }

    @Test func aPageIsReadFromAMacThatServesTheViewAndNamesEveryMac() async {
        let client = FakeFleetClient(Page.snapshot())
        let hosts = [Self.host("Mac mini", FakeSettingsClient(), view: false), Self.host("MacBook Pro", client)]
        let fleet = Self.fleet()
        #expect(ClientFleet.isAvailable(hosts) && ClientFleet.sources(hosts).map(\.name) == ["MacBook Pro"])
        await fleet.refresh(hosts)
        #expect(fleet.phase == .loaded && fleet.sourceName == "MacBook Pro")
        #expect(fleet.page.cards.map(\.name) == ["MacBook Pro", "Mac mini", "Mac Studio"], "no This Mac for a client")
        #expect(fleet.page.nextGoesTo == "Mac mini")
        #expect(client.fleetCalls == ["read"])
    }

    @Test func nothingShowsWhileNoConnectedMacServesTheView() async {
        let offline = Self.host("MacBook Pro", nil)
        let old = Self.host("Mac mini", FakeSettingsClient(), view: false)
        #expect(!ClientFleet.isAvailable([offline, old]) && !ClientFleet.isAvailable([]))
        let fleet = Self.fleet()
        await fleet.refresh([offline, old])
        #expect(fleet.phase == .idle && fleet.page == .empty)
    }

    @Test func theWeightsComeFromTheMacsHostSettingsAndAChoiceIsWrittenThereAndShownAtOnce() async throws {
        let studio = Page.studio
        let client = FakeFleetClient(Page.snapshot())
        let hosts = [Self.host("MacBook Pro", client)]
        let fleet = Self.fleet()
        await fleet.refresh(hosts)
        #expect(fleet.page.cards.map(\.weight) == [.normal, .normal, .normal])

        let write = try #require(fleet.choose(.manualOnly, for: studio, hosts))
        #expect(fleet.page.cards[2].weight == .manualOnly, "shown before the Mac answers")
        await write.value
        #expect(client.requests.contains("settings.change(ShepherdProtocol.HostSettingChange.fleetWeight(hostID: \(studio), weight: ShepherdCore.FleetSendWeight.manualOnly))"))
        #expect(fleet.page.cards[2].weight == .manualOnly && fleet.problem == nil)

        // The weight the fleet holds is read back with the next page, whoever chose it.
        let again = FakeFleetClient(Page.snapshot())
        _ = try await again.hostSettings(.change(.fleetWeight(hostID: Page.mini, weight: .prefer)))
        let other = Self.fleet()
        await other.refresh([Self.host("MacBook Pro", again)])
        #expect(other.page.cards.map(\.weight) == [.normal, .prefer, .normal])
    }

    @Test func aMacThatRefusesAChoiceGetsTheOldWeightBackAndTheReasonIsKept() async throws {
        let client = FakeFleetClient(Page.snapshot())
        let hosts = [Self.host("MacBook Pro", client)]
        let fleet = Self.fleet()
        await fleet.refresh(hosts)
        client.refusesChanges = true
        let write = try #require(fleet.choose(.prefer, for: Page.mini, hosts))
        #expect(fleet.page.cards[1].weight == .prefer)
        await write.value
        #expect(fleet.page.cards[1].weight == .normal && fleet.problem == "The host said no.")
        fleet.dismissProblem()
        #expect(fleet.problem == nil)
    }

    @Test func aMacWithoutTheViewIsNeverSentAWeight() async {
        let hosts = [Self.host("MacBook Pro", FakeSettingsClient(), view: false)]
        let fleet = Self.fleet()
        #expect(fleet.choose(.prefer, for: Page.mini, hosts) == nil)
    }

    @Test func aReadThatFailsKeepsThePageAndMovesOnToTheNextMac() async {
        let first = FakeFleetClient(Page.snapshot()), second = FakeFleetClient(Page.snapshot())
        let hosts = [Self.host("MacBook Pro", first), Self.host("Mac mini", second)]
        let fleet = Self.fleet()
        await fleet.refresh(hosts)
        #expect(fleet.sourceName == "MacBook Pro")
        first.answers(.failure(.timeout))
        await fleet.refresh(hosts)
        guard case .failed = fleet.phase else { Issue.record("a failed read says so: \(fleet.phase)"); return }
        #expect(fleet.page.cards.count == 3, "what was drawn stays")
        await fleet.refresh(hosts)
        #expect(fleet.phase == .loaded && fleet.sourceName == "Mac mini", "the next read asks the other Mac")
        #expect(second.fleetCalls == ["read"])
    }

    @Test func aMacWithFleetOffSaysSoAndDrawsNothing() async {
        let client = FakeFleetClient(Page.snapshot())
        let hosts = [Self.host("MacBook Pro", client)]
        let fleet = Self.fleet()
        await fleet.refresh(hosts)
        client.answers(.failure(.rejected(code: FleetProtocol.Code.off, message: "Enable Fleet in Settings ▸ Experiments.")))
        await fleet.refresh(hosts)
        #expect(fleet.phase == .off && fleet.page == .empty)
    }

    @Test func aSampleTheMacStoppedRefreshingGoesStaleOnScreen() async {
        var time = Date(timeIntervalSince1970: 1_790_000_000)
        let fleet = ClientFleet(hostSettings: ClientHostSettings())
        fleet.now = { time }
        let hosts = [Self.host("MacBook Pro", FakeFleetClient(Page.snapshot()))]
        await fleet.refresh(hosts)
        #expect(fleet.page.cards[1].room.text == "Most room")
        time.addTimeInterval(20)
        fleet.recompute(hosts)
        #expect(fleet.page.cards[1].room.text == "Not counted" && fleet.page.cards[1].cpu == nil)
    }

    @Test func watchingIsSentToTheMacTheFleetIsReadFrom() async {
        let client = FakeFleetClient(Page.snapshot())
        let hosts = [Self.host("MacBook Pro", client)]
        let fleet = Self.fleet()
        await fleet.refresh(hosts)
        await fleet.watching(true, hosts)
        await fleet.watching(false, hosts)
        #expect(client.fleetCalls == ["read", "watching(true)", "watching(false)"])
    }

    @Test func theWeightsAreReadAgainOnlyEverySixthRead() async {
        let client = FakeFleetClient(Page.snapshot())
        let hosts = [Self.host("MacBook Pro", client)]
        let fleet = Self.fleet()
        for _ in 0..<7 { await fleet.refresh(hosts) }
        #expect(client.requests.filter { $0 == "settings.fetch" }.count == 2, "the first read and the seventh")
    }
}
