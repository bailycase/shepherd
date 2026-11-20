import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// Stop all working threads: which threads it stops, what each one is asked, and how the result reads.
@Suite("Stop all working threads")
@MainActor
struct StopAllWorkingTests {
    static let host = UUID()

    static func agent(_ id: String, _ status: AgentStatus) -> Agent {
        var agent = Agent(id: AgentID(rawValue: id), name: "thread \(id)", spaceID: SpaceID(rawValue: "acme-web"),
                          tabID: TabID(rawValue: "tab-" + id), nameIsFinal: true)
        agent.status = status
        return agent
    }

    static func target(_ id: String) -> StopAllWorking.Target {
        .init(host: host, agent: AgentID(rawValue: id), name: "thread \(id)")
    }

    // MARK: Selection

    @Test func onlyWorkingThreadsAreStopped() {
        let state = ShepherdState(agents: [
            Self.agent("a", .working), Self.agent("b", .idle), Self.agent("c", .blocked),
            Self.agent("d", .done), Self.agent("e", .working),
        ])
        #expect(StopAllWorking.targets(host: Self.host, in: state) == [Self.target("a"), Self.target("e")])
    }

    @Test func workThatRunsUnderSomethingElseIsLeftAlone() {
        var coordinator = Self.agent("coordinator", .working)
        coordinator.coordinatorFor = ProjectID(rawValue: "acme-project")
        let run = Self.agent("run", .working)
        let automation = Automation(id: AutomationID(rawValue: "nightly"), name: "Nightly", prompt: "p", cwd: "/src", agentID: run.id)
        let state = ShepherdState(agents: [coordinator, run, Self.agent("plain", .working)], automations: [automation])
        #expect(StopAllWorking.targets(host: Self.host, in: state) == [Self.target("plain")])
    }

    @Test func nothingWorkingSelectsNothing() {
        #expect(StopAllWorking.targets(host: Self.host, in: ShepherdState(agents: [Self.agent("a", .idle)])).isEmpty)
    }

    // MARK: Running

    /// A host that answers a snapshot per thread and records each abort it is sent.
    final class FakeHost {
        var running: [String: Bool]
        var refused: [String: String] = [:]
        var actions: [String: [String]] = [:]
        var aborted: [(agent: String, session: String, generation: String)] = []

        init(running: [String: Bool]) { self.running = running }

        func answer(_ target: StopAllWorking.Target, _ request: NativeThreadRequest) throws -> NativeThreadResult {
            let id = target.agent.rawValue
            switch request {
            case .snapshot:
                guard let running = running[id] else { throw RemoteHostClientError.disconnected }
                return .snapshot(value: NativeThreadSnapshot(
                    piSessionID: "session-\(id)", generation: "g-\(id)", revision: 1, running: running,
                    supportedActions: actions[id] ?? ["send", "abort"], dialogsSupported: true, dialogs: [],
                    messages: [], provisional: [], clipped: false))
            case .abort(let session, let generation, let operationID):
                if let message = refused[id] { return .failure(code: "refused", message: message) }
                aborted.append((id, session, generation))
                return .accepted(operationID: operationID)
            default:
                return .failure(code: "unexpected", message: "not part of Stop all")
            }
        }
    }

    @Test func eachRunningThreadIsAbortedAgainstItsOwnSession() async {
        let host = FakeHost(running: ["a": true, "b": true])
        let outcome = await StopAllWorking.run([Self.target("a"), Self.target("b")]) { try host.answer($0, $1) }
        #expect(outcome == StopAllWorking.Outcome(stopped: 2))
        #expect(host.aborted.map(\.agent) == ["a", "b"])
        #expect(host.aborted.map(\.session) == ["session-a", "session-b"])
        #expect(host.aborted.map(\.generation) == ["g-a", "g-b"])
        #expect(outcome.title == "Stopped 2 threads")
    }

    @Test func aThreadThatFinishedFirstIsNotAbortedOrCounted() async {
        let host = FakeHost(running: ["a": false, "b": true])
        let outcome = await StopAllWorking.run([Self.target("a"), Self.target("b")]) { try host.answer($0, $1) }
        #expect(host.aborted.map(\.agent) == ["b"])
        #expect(outcome.stopped == 1 && outcome.alreadyStopped == 1 && outcome.failures.isEmpty)
        #expect(outcome.title == "Stopped 1 thread")
        #expect(outcome.message == "1 thread had already finished.")
    }

    @Test func failuresNameTheThreadAndTheReasonAndDoNotStopTheRest() async {
        let host = FakeHost(running: ["a": true, "b": true, "c": true, "d": true])
        host.refused["a"] = "The session changed."
        host.actions["b"] = ["send"]
        host.running["c"] = nil
        let outcome = await StopAllWorking.run(["a", "b", "c", "d"].map(Self.target)) { try host.answer($0, $1) }
        #expect(host.aborted.map(\.agent) == ["d"])
        #expect(outcome.stopped == 1)
        #expect(outcome.failures.map(\.name) == ["thread a", "thread b", "thread c"])
        #expect(outcome.failures.first?.message == "The session changed.")
        #expect(outcome.title == "Stopped 1 thread, 3 couldn’t be stopped")
        #expect(outcome.message.hasPrefix("thread a: The session changed.\nthread b: It can’t be stopped right now.\nthread c: "))
    }

    @Test func titlesCountAndConfirmNamesTheCount() {
        #expect(StopAllWorking.Outcome().title == "Nothing was working")
        #expect(StopAllWorking.Outcome(failures: [.init(name: "a", message: "m")]).title == "Couldn’t stop 1 thread")
        #expect(StopAllWorking.confirmTitle(count: 1) == "Stop the working thread?")
        #expect(StopAllWorking.confirmTitle(count: 3) == "Stop 3 working threads?")
        #expect(StopAllWorking.menuTitle(count: 0) == "Stop All Working Threads…")
        #expect(StopAllWorking.menuTitle(count: 3) == "Stop All Working Threads (3)…")
    }
}
