import Foundation
import Testing
@testable import ShepherdSessions

@Suite("Legacy agent recovery decoding")
struct LegacyAgentRecoveryTests {
    @Test func legacyCheckpointKeepsLegacyQueueItems() throws {
        let json = """
        {"sessionID":"acme-session","active":true,"pending":[],"paused":true,"mode":"all",
         "items":[{"entry":{"id":"F94561E6-7623-4BB2-8FB2-217B427A948C","text":"Keep queued"},
                   "images":[]}]}
        """
        let checkpoint = try JSONDecoder().decode(AgentRecoveryStore.Checkpoint.self, from: Data(json.utf8))
        #expect(checkpoint.sessionID == "acme-session")
        #expect(checkpoint.active && checkpoint.paused)
        #expect(checkpoint.mode == .all)
        let item = try #require(checkpoint.items.first)
        #expect(item.entry.text == "Keep queued")
        #expect(!item.goesAlone && item.designPayloads.isEmpty && !item.direct)
        #expect(checkpoint.attempts == 0)
    }

    @Test func legacyQueueItemKeepsItsPromptWithoutNewDeliveryFields() throws {
        let json = """
        {"entry":{"id":"F94561E6-7623-4BB2-8FB2-217B427A948C","text":"Keep queued","sentAt":1200},
         "images":[{"mimeType":"image/png","data":"AA=="}],"piText":"Expanded prompt","holdUntil":500}
        """
        let item = try JSONDecoder().decode(RPCThreadState.QueueItem.self, from: Data(json.utf8))
        #expect(item.entry.text == "Keep queued")
        #expect(item.entry.sentAt == 1200)
        #expect(item.images.map(\.data) == [Data([0])])
        #expect(item.piText == "Expanded prompt")
        #expect(item.holdUntil == Date(timeIntervalSinceReferenceDate: 500))
        #expect(!item.goesAlone && item.designPayloads.isEmpty && !item.direct)
    }
}
