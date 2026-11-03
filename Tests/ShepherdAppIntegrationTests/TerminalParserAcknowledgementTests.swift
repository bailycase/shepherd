import Foundation
import Testing
@testable import GhosttyTerminal
@testable import TerminalSurfaceKit
import ShepherdTestSupport

@Suite("Terminal parser acknowledgements", .integrationTimeLimit)
struct TerminalParserAcknowledgementTests {
    @Test @MainActor func aMissingInitialSurfaceHoldsOutputUntilRetirement() {
        let completed = Locked(0)
        var model: TerminalSurfaceModel? = TerminalSurfaceModel()
        model?.feed(Data([1, 2, 3])) { completed.withValue { $0 += 1 } }
        #expect(completed.current == 0, "pre-surface buffering must participate in backpressure")
        model = nil
        #expect(completed.current == 1, "teardown retires the pending completion exactly once")
    }

    @Test @MainActor func aReplayManagedAbsentSurfaceRetiresOutputWithoutHoldingOtherSessions() {
        let completed = Locked(0)
        var model: TerminalSurfaceModel? = TerminalSurfaceModel()
        model?.onSurfaceAttachmentChanged = { _ in }
        model?.feed(Data([1, 2, 3])) { completed.withValue { $0 += 1 } }
        #expect(completed.current == 1, "authoritative reattach replay replaces absent-surface bytes")
        model = nil
        #expect(completed.current == 1)
    }

    @Test func completionWaitsForTheActualWriterAndRetiresInvalidatedWrites() async throws {
        let entered = Locked(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let completed = Locked<[Int]>([])
        let written = Locked<[Data]>([])
        let access = InMemoryTerminalSurfaceAccess(write: { _, bytes in
            entered.withValue { $0 = true }
            release.wait()
            written.withValue { $0.append(bytes) }
        }, processExit: { _, _, _ in })
        access.setSurface(UnsafeMutableRawPointer(bitPattern: 1))
        access.enqueueWrite(Data([1])) { completed.withValue { $0.append(1) } }
        try await eventually("the actual parser writer to stall") { entered.current }
        access.enqueueWrite(Data([2])) { completed.withValue { $0.append(2) } }
        #expect(completed.current.isEmpty)
        // Invalidating generation must not strand the second completion, even though its
        // obsolete bytes must not be applied to a replacement surface.
        let clearing = Task.detached { access.setSurface(nil) }
        try await eventually("surface generation invalidation") { access.currentSurface == nil }
        release.signal()
        await clearing.value
        access.waitForPendingOutput()
        #expect(completed.current == [1, 2])
        #expect(written.current == [Data([1])])
        access.enqueueWrite(Data([3])) { completed.withValue { $0.append(3) } }
        #expect(completed.current == [1, 2, 3], "surfaceless retirement acknowledges exactly once")
    }
}
