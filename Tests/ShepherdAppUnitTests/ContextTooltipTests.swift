import Foundation
import ShepherdProtocol
import Testing
@testable import ShepherdApp

/// The header's context tooltip from pi's stats, including the numbers a models.json
/// "unlimited" window gives.
@Suite("Context tooltip")
struct ContextTooltipTests {
    @Test(arguments: [
        (NativeThreadStats(contextTokens: 812, contextWindow: 200_000, contextPercent: 21), "812 context tokens of 200k (21%)"),
        (NativeThreadStats(contextTokens: 812, contextWindow: 0, contextPercent: 8.123e23), "812 context tokens of 0 (100%)"),
        (NativeThreadStats(contextTokens: 812, contextWindow: .max, contextPercent: 0), "812 context tokens of 9223372036854.8M (0%)"),
        (NativeThreadStats(contextTokens: 812, contextPercent: -4), "812 context tokens (0%)"),
    ])
    func theTooltipSaysAPercentWithinAHundred(_ stats: NativeThreadStats, text: String) {
        #expect(nativeContextTooltip(stats) == text)
    }
}
