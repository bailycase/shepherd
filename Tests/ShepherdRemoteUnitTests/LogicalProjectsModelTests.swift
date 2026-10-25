import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import Testing

@Suite("Cross-platform Projects model") @MainActor
struct RemoteLogicalProjectsModelTests {
    @Test func ownerQualifiedBusyStateAndRejectedDoubleSendsKeepUnknownOperationIdentity() async {
        let project = Project(name: "Sample")
        let first = LogicalProjectRef(home: .host(UUID()), id: project.id)
        let second = LogicalProjectRef(home: .host(UUID()), id: project.id)
        var requests: [(LogicalProjectRef, UUID)] = []
        var model: LogicalProjectsModel!
        model = LogicalProjectsModel(send: { _, _ in .projects([project]) }, pushed: { _ in [project] }, runtime: { ref, _, request in
            guard case .message(let operation, _, _) = request else { throw LogicalProjectsError("test", "Unexpected request") }
            requests.append((ref, operation))
            if requests.count == 1 {
                #expect(model.busy == [first])
                #expect(await model.sendMessage(first, text: "Different") == false)
                #expect(await model.sendMessage(second, text: "Other owner"))
                throw RemoteHostClientError.outcomeUnknown(message: "Reply lost")
            }
            return project
        })
        #expect(await model.sendMessage(first, text: "Original") == false)
        #expect(await model.sendMessage(first, text: "Original"))
        #expect(requests.map(\.0) == [first, second, first])
        #expect(requests[0].1 == requests[2].1, "An overlapping refused send must not replace the ambiguous operation")
        #expect(model.busy.isEmpty)
    }

    @Test func retargetAndForgetDoNotReuseAnotherOwnersRevisionOrUnknownOperation() async {
        let ref = LogicalProjectRef(home: .host(UUID()), id: ProjectID())
        var pushed = Project(id: ref.id, name: "Old owner", revision: 9)
        var answered = pushed
        answered.revision = 12
        var operations: [UUID] = []
        let model = LogicalProjectsModel(send: { _, _ in .projects([answered]) }, pushed: { _ in [pushed] }, runtime: { _, _, request in
            guard case .message(let operation, _, _) = request else { throw LogicalProjectsError("test", "Unexpected request") }
            operations.append(operation)
            throw RemoteHostClientError.outcomeUnknown(message: "Reply lost")
        })
        await model.refresh(ref.home)
        #expect(model.project(ref)?.revision == 12)
        #expect(await model.sendMessage(ref, text: "Hello") == false)
        pushed = Project(id: ref.id, name: "Replacement", revision: 1)
        #expect(model.project(ref)?.ownerID == pushed.ownerID)
        #expect(model.project(ref)?.revision == 1)
        #expect(await model.sendMessage(ref, text: "Hello") == false)
        #expect(operations[0] != operations[1])
        model.forget(ref.home)
        #expect(await model.sendMessage(ref, text: "Hello") == false)
        #expect(operations[1] != operations[2])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func forgottenInFlightRequestCannotFinishOrUnlockItsReplacement(refused: Bool) async {
        let ref = LogicalProjectRef(home: .host(UUID()), id: ProjectID())
        let old = Project(id: ref.id, name: "Old owner", revision: 40)
        var pushed = old
        let arrivals = AsyncStream<Void>.makeStream()
        let firstReplies = AsyncStream<Result<Project, LogicalProjectsError>>.makeStream()
        let secondReplies = AsyncStream<Result<Project, LogicalProjectsError>>.makeStream()
        defer { arrivals.continuation.finish(); firstReplies.continuation.finish(); secondReplies.continuation.finish() }
        var calls = 0
        let model = LogicalProjectsModel(send: { _, _ in .projects([pushed]) }, pushed: { _ in [pushed] }, runtime: { _, _, _ in
            calls += 1
            var replies = (calls == 1 ? firstReplies.stream : secondReplies.stream).makeAsyncIterator()
            arrivals.continuation.yield(())
            guard let result = await replies.next() else { throw CancellationError() }
            return try result.get()
        })
        var arrived = arrivals.stream.makeAsyncIterator()
        let first = Task { await model.sendMessage(ref, text: "Old draft") }
        _ = await arrived.next()
        model.forget(ref.home)
        pushed = Project(id: ref.id, name: "Replacement", revision: 1)
        let second = Task { await model.sendMessage(ref, text: "New draft") }
        _ = await arrived.next()
        firstReplies.continuation.yield(refused ? .failure(.init("stale_project", "Old reply")) : .success(old))
        #expect(await first.value == false)
        #expect(model.busy.contains(ref), "An obsolete completion must not unlock the replacement mutation")
        #expect(model.failure == nil)
        var accepted = pushed; accepted.revision = 2
        secondReplies.continuation.yield(.success(accepted))
        #expect(await second.value)
        #expect(model.busy.isEmpty)
        #expect(model.project(ref) == accepted)
    }
}
