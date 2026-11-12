import Foundation
import ShepherdCore
import Testing
@testable import ShepherdApp

/// How often an agent's sparkline is published while tools finish: the first sample at once, then at most every
/// quarter second, the last one always.
@Suite("Activity pacing")
struct ActivityPacingTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private let agent = AgentID()

    private func at(_ milliseconds: Double) -> Date { start.addingTimeInterval(milliseconds / 1_000) }

    @Test func theFirstSamplePublishesAtOnce() {
        var pacing = ActivityPacing()
        #expect(pacing.record(agent, samples: [4], at: at(0)) == [4])
        #expect(pacing.nextDue == nil)
    }

    @Test func samplesFiftyMillisecondsApartPublishAtTheStartAndAQuarterSecondLater() {
        var pacing = ActivityPacing()
        let published = (0..<10).filter { pacing.record(agent, samples: [Double($0)], at: at(Double($0) * 50)) != nil }
        #expect(published == [0, 5])
    }

    @Test func theTrailingPublishCarriesTheNewestSamples() {
        var pacing = ActivityPacing()
        #expect(pacing.record(agent, samples: [1], at: at(0)) != nil)
        #expect(pacing.record(agent, samples: [1, 2], at: at(50)) == nil)
        #expect(pacing.record(agent, samples: [1, 2, 3], at: at(100)) == nil)
        #expect(pacing.nextDue == at(250))

        let early = pacing.due(at: at(200))
        #expect(early.publish.isEmpty && early.next == at(250))

        let late = pacing.due(at: at(250))
        #expect(late.publish == [agent: [1, 2, 3]] && late.next == nil)
        #expect(pacing.due(at: at(500)).publish.isEmpty, "nothing publishes twice")
    }

    @Test func aTrailingPublishStartsTheNextInterval() {
        var pacing = ActivityPacing()
        _ = pacing.record(agent, samples: [1], at: at(0))
        _ = pacing.record(agent, samples: [1, 2], at: at(50))
        #expect(pacing.due(at: at(400)).publish == [agent: [1, 2]], "a late wake still publishes")
        #expect(pacing.record(agent, samples: [1, 2, 3], at: at(500)) == nil, "100 ms after it")
        #expect(pacing.record(agent, samples: [1, 2, 3, 4], at: at(650)) == [1, 2, 3, 4])
    }

    @Test func aSampleAfterTheIntervalPublishesTheNewestAndLeavesNothingToFlush() {
        var pacing = ActivityPacing()
        _ = pacing.record(agent, samples: [1], at: at(0))
        _ = pacing.record(agent, samples: [1, 2], at: at(50))
        #expect(pacing.record(agent, samples: [1, 2, 3], at: at(300)) == [1, 2, 3])
        #expect(pacing.nextDue == nil)
        #expect(pacing.due(at: at(1_000)).publish.isEmpty)
    }

    @Test func samplesTwoSecondsApartEachPublishAtOnce() {
        var pacing = ActivityPacing()
        for index in 0..<20 {
            #expect(pacing.record(agent, samples: [Double(index)], at: at(Double(index) * 2_000)) == [Double(index)])
        }
        #expect(pacing.nextDue == nil)
    }

    @Test func eachAgentIsPacedOnItsOwn() {
        var pacing = ActivityPacing()
        let other = AgentID()
        #expect(pacing.record(agent, samples: [1], at: at(0)) != nil)
        #expect(pacing.record(other, samples: [9], at: at(100)) != nil, "its first sample")
        #expect(pacing.record(agent, samples: [1, 2], at: at(150)) == nil)
        #expect(pacing.record(other, samples: [9, 8], at: at(200)) == nil)

        let first = pacing.due(at: at(250))
        #expect(first.publish == [agent: [1, 2]] && first.next == at(350))
        let second = pacing.due(at: at(350))
        #expect(second.publish == [other: [9, 8]] && second.next == nil)
    }

    @Test func forgettingAnAgentStartsItOver() {
        var pacing = ActivityPacing()
        _ = pacing.record(agent, samples: [1], at: at(0))
        _ = pacing.record(agent, samples: [1, 2], at: at(50))
        pacing.forget(agent)
        #expect(pacing.nextDue == nil)
        #expect(pacing.due(at: at(1_000)).publish.isEmpty, "what was held is gone")
        #expect(pacing.record(agent, samples: [7], at: at(60)) == [7], "the next sample is a first one")
    }
}
