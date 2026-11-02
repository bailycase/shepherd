import Foundation
import Testing
import ShepherdCore
@testable import ShepherdSessions

/// The real GitHub path, opt-in: `SHEPHERD_LIVE_GITHUB=owner/name` runs the user's own `gh`
/// through a login shell against that repository, parses the answer, and reads a remote URL.
/// CI never sets it, so no test reaches the network by default.
@Suite("Live GitHub trigger source", .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_LIVE_GITHUB"] != nil))
struct LiveGitHubTriggerTests {
    @Test func readsARealRepository() async throws {
        let repo = try #require(ProcessInfo.processInfo.environment["SHEPHERD_LIVE_GITHUB"])
        let ghPath = ProcessInfo.processInfo.environment["SHEPHERD_LIVE_GH"]
        let items = try await AutomationTriggers.Source.gh(ghPath: ghPath).activity(repo)
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.repo == repo && $0.number > 0 })
        #expect(items.contains { $0.isPullRequest && $0.headOID != nil })
        print("LIVE items", items.count, "events", items.reduce(0) { $0 + $1.events.count })
        // A repository gh can't see pauses rather than retries.
        do {
            _ = try await AutomationTriggers.Source.gh(ghPath: ghPath).activity("bailycase/definitely-not-a-repo-\(UUID().uuidString.prefix(6))")
            Issue.record("a missing repository should fail")
        } catch let error as AutomationTriggers.SourceError {
            #expect(error.permanent, "\(error)")
        }
    }
}
