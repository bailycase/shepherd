import ShepherdTestSupport
import Testing

/// `bounded` on a gate that never opens throws `GateTimeout` within its timeout instead of
/// hanging. Lives in the integration tier because the timeout is a real clock, which the unit
/// tier does not use; it covers the shared `ShepherdTestSupport` helper, not MCP behavior.
@Suite("Bounded waits", .integrationTimeLimit)
struct GateTimeoutTests {
    @Test func boundedOnANeverOpenedGateThrowsWithinItsTimeout() async throws {
        let gate = Gate()
        await #expect(throws: GateTimeout.self) {
            try await bounded("a gate that never opens", timeout: .milliseconds(50)) { await gate.wait() }
        }
    }
}
