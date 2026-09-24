import Foundation
import Testing
import ShepherdCore
@testable import ShepherdApp

/// The order restored agents' pi start in at launch: the ones on screen first, then the rest a
/// few at a time, and every agent once.
@Suite("Agent start queue")
struct AgentStartQueueTests {
    private let a = AgentID(), b = AgentID(), c = AgentID(), d = AgentID()

    @Test func anAgentOnScreenStartsAheadAndTheRestWaitForItThenGoAFewAtATime() {
        var queue = AgentStartQueue(limit: 2)
        let aheadBeforeQueued = queue.startAhead(a)
        #expect(!aheadBeforeQueued, "not queued yet: wanted once it is")
        let startsAtOnce = queue.enqueue(a)
        #expect(startsAtOnce, "queued while wanted: it starts now, ahead")
        for id in [b, c, d] { _ = queue.enqueue(id) }
        #expect(queue.waiting == [b, c, d])
        #expect(queue.next().isEmpty, "the queue waits while an agent ahead boots")

        queue.finished(a)
        #expect(queue.next() == [b, c])
        #expect(queue.next().isEmpty, "two slots, both held")
        queue.finished(b)
        #expect(queue.next() == [d])
        queue.finished(c)
        queue.finished(d)
        #expect(queue.waiting.isEmpty && queue.running.isEmpty && queue.started == [a, b, c, d])
    }

    @Test func selectingAnAgentStillWaitingStartsItAheadOfTheOthers() {
        var queue = AgentStartQueue(limit: 1)
        for id in [a, b, c] { _ = queue.enqueue(id) }
        #expect(queue.next() == [a])
        let waitingStartsNow = queue.startAhead(c)
        let startedStaysPut = queue.startAhead(a)
        #expect(waitingStartsNow && !startedStaysPut)
        queue.finished(a)
        #expect(queue.next().isEmpty, "c boots ahead: b waits for it")
        queue.finished(c)
        #expect(queue.next() == [b])
    }

    @Test func anAgentStartsOnceHoweverOftenItIsQueued() {
        var queue = AgentStartQueue(limit: 2)
        _ = queue.enqueue(a)
        _ = queue.enqueue(a)
        #expect(queue.waiting == [a])
        #expect(queue.next() == [a])
        _ = queue.enqueue(a)
        #expect(queue.waiting.isEmpty)
        queue.finished(a)
        queue.finished(a)
        #expect(queue.next().isEmpty && queue.running.isEmpty)
    }
}
