import Testing
@testable import ShepherdSessions

/// What the host does for Steer now, from where pi is: stop it and send, or fall back. The
/// fallback is a value here, so it is chosen and tested, never a silent breakage.
@Suite("Interrupt plan")
struct InterruptPlanTests {
    typealias State = RPCThreadState.InterruptState
    typealias Plan = RPCThreadState.InterruptPlan

    static func state(running: Bool = false, compacting: Bool = false, promptOnItsWay: Bool = false,
                      interrupting: Bool = false) -> State {
        State(running: running, compacting: compacting, promptOnItsWay: promptOnItsWay, interrupting: interrupting)
    }

    @Test(arguments: [
        // pi works: stop it, then send.
        (InterruptPlanTests.state(running: true), Plan.abortThenSend),
        // pi is idle: a plain send.
        (InterruptPlanTests.state(), .sendNow),
        // Manual compaction with pi idle is a plain send too (pi answers for itself).
        (InterruptPlanTests.state(compacting: true), .sendNow),
        // A compaction under way: an abort would end it, and pi refuses a prompt meanwhile.
        (InterruptPlanTests.state(running: true, compacting: true), .steer(.compacting)),
        // A prompt of ours is on its way: there is no run to stop yet.
        (InterruptPlanTests.state(promptOnItsWay: true), .steer(.promptOnItsWay)),
        (InterruptPlanTests.state(running: true, promptOnItsWay: true), .steer(.promptOnItsWay)),
        // An interrupt already stops pi: these go with it, whatever else is true.
        (InterruptPlanTests.state(running: true, interrupting: true), .joinInterrupt),
        (InterruptPlanTests.state(interrupting: true), .joinInterrupt),
        (InterruptPlanTests.state(running: true, compacting: true, interrupting: true), .joinInterrupt),
    ] as [(State, Plan)])
    func theHostStopsPiOnlyWhereItCanAndOtherwiseFallsBack(state: State, plan: Plan) {
        #expect(RPCThreadState.interruptPlan(state) == plan)
    }

    /// Every fallback has a reason the log names, and only a running pi is ever aborted.
    @Test func onlyARunningPiWithNothingElseInTheWayIsAborted() {
        for running in [false, true] {
            for compacting in [false, true] {
                for onItsWay in [false, true] {
                    let plan = RPCThreadState.interruptPlan(Self.state(running: running, compacting: compacting, promptOnItsWay: onItsWay))
                    let aborts = plan == .abortThenSend
                    #expect(aborts == (running && !compacting && !onItsWay), "running \(running), compacting \(compacting), on its way \(onItsWay)")
                }
            }
        }
        #expect(RPCThreadState.InterruptFallback.compacting.rawValue == "compacting")
    }
}
