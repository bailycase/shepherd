import ShepherdRemote
import Testing

struct SupervisionQueuesTests {
    @Test func blockedThreadsLeadUnseenDoneOldestFirstAndRepeatedJumpsReachAll() {
        let queues = SupervisionQueues(blocked: [
            .init("new question", since: 30), .init("old question", since: 10),
            .init("same age", since: 10), .init("unknown age", since: nil),
            .init("old question", since: 11),
        ], unseenDone: [.init("new done", since: 40), .init("old done", since: 5)])

        #expect(queues.needingYou == ["old question", "same age", "new question", "unknown age", "old done", "new done"])
        #expect(queues.nextNeedingYou(after: nil) == "old question")
        #expect(queues.nextNeedingYou(after: "elsewhere") == "old question")
        #expect(queues.nextNeedingYou(after: "unknown age") == "old done")
        #expect(queues.nextNeedingYou(after: "new done") == "old question")
    }

    @Test func reviewOnlyQueuesUnseenDoneWithChangedFilesOldestFirst() {
        let queues = SupervisionQueues(blocked: [.init("blocked", since: 1, changedFiles: 6)], unseenDone: [
            .init("new changes", since: 40, changedFiles: 1), .init("clean", since: 2),
            .init("unknown age", since: nil, changedFiles: 8), .init("old changes", since: 10, changedFiles: 2),
        ])
        #expect(queues.review == ["old changes", "new changes", "unknown age"])
        #expect(queues.nextReview() == "old changes")
        #expect(queues.nextReview(excluding: "old changes") == "new changes")
        #expect(queues.needingYou.contains("clean"))
    }

    @Test func noNextWhenOnlyCurrentThreadRemains() {
        #expect(SupervisionQueues<String>(blocked: [], unseenDone: []).nextNeedingYou(after: nil) == nil)
        let queues = SupervisionQueues(blocked: [], unseenDone: [.init("done", since: nil)])
        #expect(queues.nextNeedingYou(after: "done") == nil)
        #expect(queues.nextNeedingYou(after: nil) == "done")
        #expect(queues.needingYouCount(excluding: "done") == 0)
        #expect(queues.needingYouCount(excluding: nil) == 1)
        #expect(queues.nextReview() == nil)
        let changes = SupervisionQueues(blocked: [], unseenDone: [.init("changed", since: nil, changedFiles: 1)])
        #expect(changes.nextReview(excluding: "changed") == nil)
    }
}
