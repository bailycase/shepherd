import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// A client of a Mac that opened a connection to this host (`fleet.link.v1`): its requests leave as calls, an answer by id resumes
/// them, and a connection that closes fails what waits. Nothing here opens a socket.
@Suite("Remote host client over a peer's connection")
struct RemotePeerChannelTests {
    /// The connection the calls go out on: it remembers them in order and what it was told to close.
    final class Channel: RemoteHostClientPeerChannel, @unchecked Sendable {
        let calls: AsyncStream<(Int, RemoteRequest)>
        private let continuation: AsyncStream<(Int, RemoteRequest)>.Continuation
        private let lock = NSLock()
        private var closing: [String] = []
        var accepts = true

        init() { (calls, continuation) = AsyncStream.makeStream() }

        func send(callID: Int, request: RemoteRequest) -> Bool {
            guard accepts else { return false }
            continuation.yield((callID, request))
            return true
        }

        func close(reason: String) { lock.lock(); closing.append(reason); lock.unlock() }
        var closed: [String] { lock.lock(); defer { lock.unlock() }; return closing }
    }

    static let mini = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let capabilities: Set<String> = [RemoteProtocol.fleetLinkCapability, RemoteProtocol.fleetPressureCapability]

    static func sample() -> FleetPressureSample {
        FleetPressureSample(cpuUtilization: 0.2, cpuCount: 8, totalMemoryBytes: 1 << 34, availableMemoryBytes: 1 << 33, activeAgents: 1)
    }

    @Test func aClientKnowsWhatTheMacItIsForOffers() {
        let client = RemoteHostClient(peerChannel: Channel(), hostID: Self.mini, capabilities: Self.capabilities)
        #expect(client.hostID == Self.mini && client.capabilities == Self.capabilities)
    }

    @Test func aRequestLeavesAsACallAndTheAnswerWithItsIdResumesIt() async throws {
        let channel = Channel()
        let client = RemoteHostClient(peerChannel: channel, hostID: Self.mini, capabilities: Self.capabilities)
        let asked = Task { try await client.fleetPressureNow() }
        var calls = channel.calls.makeAsyncIterator()
        let (id, request) = try #require(await calls.next())
        guard case .fleetPressureNow(let inner) = request else { Issue.record("sent \(request)"); return }
        #expect(inner == id, "the call and the request inside it carry one id")

        client.receivePeerAnswer(id: id, reply: .fleetPressureSample(id: id, sample: Self.sample(), readiness: nil))
        let answer = try await asked.value
        #expect(answer.sample == Self.sample())
        // Nothing is in flight now.
        await client.waitUntilIdle()
    }

    @Test func eachCallHasItsOwnIdAndAnAnswerForAnotherIsNotTaken() async throws {
        let channel = Channel()
        let client = RemoteHostClient(peerChannel: channel, hostID: Self.mini, capabilities: Self.capabilities)
        let first = Task { try await client.fleetPressureNow() }
        let second = Task { try await client.fleetPressureNow() }
        var calls = channel.calls.makeAsyncIterator()
        let one = try #require(await calls.next()).0, two = try #require(await calls.next()).0
        #expect(one != two)
        // Answered out of order, each goes to the request it names.
        var other = Self.sample()
        other.activeAgents = 5
        client.receivePeerAnswer(id: two, reply: .fleetPressureSample(id: two, sample: other, readiness: nil))
        client.receivePeerAnswer(id: one, reply: .fleetPressureSample(id: one, sample: Self.sample(), readiness: nil))
        let (a, b) = (try await first.value, try await second.value)
        let (firstAnswer, secondAnswer) = one < two ? (a, b) : (b, a)
        #expect(firstAnswer.sample.activeAgents == 1 && secondAnswer.sample.activeAgents == 5)
    }

    @Test func aConnectionThatClosesFailsEveryRequestWaitingAndRefusesTheNext() async throws {
        let channel = Channel()
        let client = RemoteHostClient(peerChannel: channel, hostID: Self.mini, capabilities: Self.capabilities)
        let waiting = Task { try await client.fleetPressureNow() }
        var calls = channel.calls.makeAsyncIterator()
        _ = await calls.next()
        client.peerChannelClosed(reason: "the connection closed")
        do { _ = try await waiting.value; Issue.record("answered after the connection closed") }
        catch RemoteHostClientError.disconnected {}
        await client.waitUntilIdle()
        do { _ = try await client.fleetPressureNow(); Issue.record("sent on a closed connection") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == "not_sent") }
    }

    @Test func aCallTheConnectionCannotTakeIsNotSentAndTheClientSaysSo() async throws {
        let channel = Channel()
        channel.accepts = false
        let client = RemoteHostClient(peerChannel: channel, hostID: Self.mini, capabilities: Self.capabilities)
        do { _ = try await client.fleetPressureNow(); Issue.record("sent") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == "not_sent") }
        #expect(channel.closed.isEmpty, "a call that wasn't sent doesn't end the connection")
    }

    @Test func closingTheClientClosesTheConnectionItSendsOverOnce() async throws {
        let channel = Channel()
        let client = RemoteHostClient(peerChannel: channel, hostID: Self.mini, capabilities: Self.capabilities)
        client.disconnect()
        client.disconnect()
        await client.waitUntilIdle()
        #expect(channel.closed == ["closed"])
    }
}
