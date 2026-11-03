import Foundation
import Testing
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Changes review cancellation", .integrationTimeLimit)
struct ChangesCancellationTests {
    @Test func cancelledReviewJobsDoNotBeginWorkAndMandatoryWorkIsIndependent() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ChangesService(directory: root)
        service.reviewWork.isSuspended = true
        defer { service.reviewWork.isSuspended = false }
        let started = Locked(0)
        let tasks = (0..<64).map { _ in
            Task { try await service.performReview { started.withValue { $0 += 1 } } }
        }
        try await eventually("review admission bound reached") { service.reviewJobs.withValue { $0 == 64 } }
        await #expect(throws: ChangesError.self) { try await service.performReview { Issue.record("overflow ran") } }
        // The non-review queue remains available to mandatory work.
        #expect(try await service.perform { 42 } == 42)
        tasks.forEach { $0.cancel() }
        service.reviewWork.isSuspended = false
        for task in tasks { await #expect(throws: CancellationError.self) { try await task.value } }
        #expect(started.current == 0)
        #expect(service.reviewJobs.withValue { $0 } == 0)
    }

    @Test func cancellationStopsTheNextGitAndParsePhase() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ChangesService(directory: root)
        let entered = Locked(false), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let request = Task {
            try await service.performReview {
                entered.withValue { $0 = true }
                release.wait()
                // Invalid cwd would produce a Git error if cancellation did not gate spawning.
                _ = try ChangesGit.run(["status"], in: "/missing-review-test-directory")
                Issue.record("obsolete Git phase completed")
            }
        }
        try await eventually("review reached gate") { entered.current }
        request.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await request.value }
    }
}
