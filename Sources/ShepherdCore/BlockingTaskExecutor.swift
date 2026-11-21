import Dispatch

/// Runs tasks that call blocking APIs away from Swift's cooperative pool, without losing
/// their task cancellation state as a plain dispatch closure would.
package final class BlockingTaskExecutor: TaskExecutor {
    package static let shared = BlockingTaskExecutor()
    private let queue = DispatchQueue(label: "shepherd.blocking-tasks", qos: .userInitiated, attributes: .concurrent)

    package func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
