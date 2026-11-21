import Foundation

/// Blocking APIs run on their own threads, not Swift's cooperative pool or GCD's global
/// queues. Hundreds of simultaneous socket reads can starve the GCD queues that answer them.
public func blocking<T: Sendable, Failure: Error>(
    _ work: @escaping @Sendable () throws(Failure) -> T
) async throws(Failure) -> T {
    let result = await withCheckedContinuation { continuation in
        let thread = Thread { continuation.resume(returning: Result(catching: work)) }
        thread.stackSize = 256 * 1024
        thread.start()
    }
    return try result.get()
}

extension DispatchQueue {
    /// Read or change queue-owned test state without a synchronous queue hop.
    public func testHop<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            async { continuation.resume(returning: work()) }
        }
    }
}
