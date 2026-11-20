import Foundation
import ShepherdCore
import ShepherdProtocol

/// Stop all: stops every thread that is working, each through the thread's own Stop (a snapshot for
/// its session, then `NativeThreadRequest.abort`), so no host needs anything new. The Mac and the
/// iPhone and iPad client share the selection, the words and the loop; each supplies how a request
/// reaches a thread's host.
public enum StopAllWorking {
    /// One working thread: where it runs and what to call it.
    public struct Target: Equatable, Hashable, Sendable {
        public var host: UUID
        public var agent: AgentID
        public var name: String

        public init(host: UUID, agent: AgentID, name: String) {
            self.host = host
            self.agent = agent
            self.name = name
        }
    }

    /// The threads on `state` that Stop all stops: the sidebar's own threads whose turn is working. A
    /// thread waiting on you, idle or done is left alone, and so is what runs under something else: a
    /// design's agent, a Project's coordinator or worker (Pause is the Project's stop), an
    /// automation's own thread or a run a trigger made (their Stop is on Automations) and a thread in
    /// a space Fleet hides from the iPhone and iPad client.
    public static func targets(host: UUID, in state: ShepherdState) -> [Target] {
        let workers = state.projectWorkerIDs
        let automationThreads = Set(state.automations.compactMap(\.agentID))
        let hiddenSpaces = Set(state.spaces.filter { !$0.showsThreads }.map(\.id))
        return state.agents.compactMap { agent in
            guard agent.status == .working, state.isSidebarThread(agent, workers: workers),
                  !automationThreads.contains(agent.id), agent.automationOrigin == nil,
                  !hiddenSpaces.contains(agent.spaceID) else { return nil }
            return Target(host: host, agent: agent.id, name: agent.name)
        }
    }

    // MARK: Words

    /// The confirm's title, naming how many threads it stops.
    public static func confirmTitle(count: Int) -> String {
        count == 1 ? "Stop the working thread?" : "Stop \(count) working threads?"
    }

    public static let confirmMessage = "Each one stops its current turn. Idle threads, finished ones and ones waiting on you are left alone."

    public static let confirmButton = "Stop All"

    /// The menu item's title: the count when threads are working.
    public static func menuTitle(count: Int) -> String {
        count > 0 ? "Stop All Working Threads (\(count))…" : "Stop All Working Threads…"
    }

    // MARK: Running

    /// What a run did, as the result dialog says it.
    public struct Outcome: Equatable, Sendable {
        public struct Failure: Equatable, Sendable {
            public var name: String
            public var message: String

            public init(name: String, message: String) {
                self.name = name
                self.message = message
            }
        }

        public var stopped = 0
        /// Threads that finished on their own before Stop reached them: nothing to stop.
        public var alreadyStopped = 0
        /// Names of threads that started waiting on you after the confirm: left running, so the question stays.
        public var waiting: [String] = []
        public var failures: [Failure] = []

        public init(stopped: Int = 0, alreadyStopped: Int = 0, waiting: [String] = [], failures: [Failure] = []) {
            self.stopped = stopped
            self.alreadyStopped = alreadyStopped
            self.waiting = waiting
            self.failures = failures
        }

        public var title: String {
            let threads = { (count: Int) in count == 1 ? "1 thread" : "\(count) threads" }
            if failures.isEmpty {
                if stopped > 0 { return "Stopped \(threads(stopped))" }
                return waiting.isEmpty ? "Nothing was working" : "Nothing was stopped"
            }
            if stopped == 0 { return "Couldn’t stop \(threads(failures.count))" }
            return "Stopped \(threads(stopped)), \(failures.count) couldn’t be stopped"
        }

        public var message: String {
            var lines = failures.map { "\($0.name): \($0.message)" }
            lines += waiting.map { "\($0): waiting for you, not stopped" }
            if alreadyStopped > 0 {
                lines.append(alreadyStopped == 1 ? "1 thread had already finished." : "\(alreadyStopped) threads had already finished.")
            }
            if lines.isEmpty { return "Every thread that was working has stopped." }
            return lines.joined(separator: "\n")
        }
    }

    /// Stops each target, one after another, and says what happened. A thread that is no longer
    /// running when its snapshot arrives is not stopped (it finished first), one that has since
    /// started waiting on a question is not stopped either (an abort would cancel the dialog), and
    /// one the host refuses is listed with the host's reason. The snapshot is taken right before
    /// each abort, so it is the thread's live state, not the one the confirm counted.
    @MainActor
    public static func run(
        _ targets: [Target],
        request: @MainActor (Target, NativeThreadRequest) async throws -> NativeThreadResult
    ) async -> Outcome {
        var outcome = Outcome()
        for target in targets {
            do {
                switch try await stop(target, request: request) {
                case .stopped: outcome.stopped += 1
                case .alreadyStopped: outcome.alreadyStopped += 1
                case .waiting: outcome.waiting.append(target.name)
                case .failed(let message): outcome.failures.append(.init(name: target.name, message: message))
                }
            } catch RemoteHostClientError.rejected(_, let message) {
                outcome.failures.append(.init(name: target.name, message: message))
            } catch {
                outcome.failures.append(.init(name: target.name, message: "The host didn’t answer (\(error)). Check the thread before trying again."))
            }
        }
        return outcome
    }

    private enum Step { case stopped, alreadyStopped, waiting, failed(String) }

    @MainActor
    private static func stop(_ target: Target, request: @MainActor (Target, NativeThreadRequest) async throws -> NativeThreadResult) async throws -> Step {
        let result = try await request(target, .snapshot())
        if case .failure(_, let message) = result { return .failed(message) }
        guard case .snapshot(let snapshot) = result else { return .failed("The thread didn’t answer. Refresh it and try again.") }
        guard snapshot.running else { return .alreadyStopped }
        // A host that clips for size may drop the dialogs and only count them in `clips.questions`.
        guard snapshot.dialogs.isEmpty, (snapshot.clips?.questions ?? 0) == 0 else { return .waiting }
        guard snapshot.supportedActions.contains("abort") else { return .failed("It can’t be stopped right now.") }
        let operation = UUID()
        switch try await request(target, .abort(expectedSessionID: snapshot.piSessionID, generation: snapshot.generation, operationID: operation)) {
        case .accepted(let accepted) where accepted == operation: return .stopped
        case .failure(_, let message): return .failed(message)
        default: return .failed("The outcome is unknown. Check the thread before trying again.")
        }
    }
}
