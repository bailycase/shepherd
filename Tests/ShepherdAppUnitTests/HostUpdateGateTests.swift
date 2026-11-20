import Testing
import ShepherdRemote
@testable import ShepherdApp

/// What an update asks of the background host (`HostUpdateGate.host`): a host that can't be asked refuses.
@Suite("Host update gate")
struct HostUpdateGateTests {
    /// A client with no connection: every request fails, as one to a host that went away does.
    @MainActor private static func unreachable() -> HostUpdateGate { HostUpdateGate.host { RemoteHostClient() } }

    @Test @MainActor func anUnreachableHostRefusesToReserveAndToRestart() async {
        let gate = Self.unreachable()
        #expect(await gate.reserve() == false)
        #expect(await gate.canRestart() == false)
        #expect(await gate.blockReason() != nil, "and says why")
    }

    @Test @MainActor func anUnreachableHostRefusesTheTermination() async {
        let safe = await withCheckedContinuation { continuation in Self.unreachable().canTerminate { continuation.resume(returning: $0) } }
        #expect(safe == false)
    }

    @Test @MainActor func noClientAtAllRefuses() async {
        let gate = HostUpdateGate.host { nil }
        #expect(await gate.reserve() == false)
        #expect(await gate.canRestart() == false)
    }
}
