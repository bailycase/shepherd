import ShepherdProtocol
import Testing
import ShepherdSessions

/// A thread's checkout is read again when its subagents write files or finish, as it is after the
/// parent's own tool calls. The children extension republishes every row each time (and every
/// 45 s unchanged), so only a row that moved can ask.
@Suite("Checkout trigger")
struct CheckoutTriggerTests {
    private func child(_ id: String = "run-1", state: String = "running", files: [ChildFileChange]? = nil,
                       activity: ChildActivity? = nil) -> ChildRun {
        var run = ChildRun(runID: id, label: "worker", state: state)
        run.files = files
        run.lastActivity = activity
        return run
    }

    @Test func anIdenticalRepublishDoesNotRead() {
        let rows = [child(files: [ChildFileChange(path: "a.swift", added: 1, removed: 0)],
                          activity: ChildActivity(tool: "edit", at: 10)),
                    child("run-2", state: "complete")]
        #expect(!CheckoutMonitor.childrenTouchedFiles(from: rows, to: rows))
    }

    @Test func aNewFileReads() {
        let old = [child(files: [ChildFileChange(path: "a.swift", added: 1, removed: 0)])]
        let new = [child(files: [ChildFileChange(path: "a.swift", added: 1, removed: 0),
                                 ChildFileChange(path: "b.swift", added: 4, removed: 0)])]
        #expect(CheckoutMonitor.childrenTouchedFiles(from: old, to: new))
    }

    @Test func aMoreEditedFileReads() {
        let old = [child(files: [ChildFileChange(path: "a.swift", added: 1, removed: 0)])]
        let new = [child(files: [ChildFileChange(path: "a.swift", added: 3, removed: 1)])]
        #expect(CheckoutMonitor.childrenTouchedFiles(from: old, to: new))
    }

    @Test func aNewReadOnlyActivityDoesNotReadAndANewEditDoes() {
        let old = [child(activity: ChildActivity(tool: "edit", at: 10))]
        for tool in ["read", "grep", "find", "ls"] {
            let new = [child(activity: ChildActivity(tool: tool, at: 20))]
            #expect(!CheckoutMonitor.childrenTouchedFiles(from: old, to: new), "\(tool)")
        }
        for tool in ["edit", "write", "bash"] {
            let new = [child(activity: ChildActivity(tool: tool, at: 20))]
            #expect(CheckoutMonitor.childrenTouchedFiles(from: old, to: new), "\(tool)")
        }
    }

    @Test func aToolStillRunningDoesNotReadUntilItFinishes() {
        let old = [child()]
        let running = [child(activity: ChildActivity(kind: ChildActivity.runningKind, tool: "bash", at: 10))]
        #expect(!CheckoutMonitor.childrenTouchedFiles(from: old, to: running))
        let finished = [child(activity: ChildActivity(tool: "bash", at: 10))]
        #expect(CheckoutMonitor.childrenTouchedFiles(from: running, to: finished))
    }

    @Test func aChildFinishingReads() {
        for end in ["complete", "failed", "stopped"] {
            #expect(CheckoutMonitor.childrenTouchedFiles(from: [child()], to: [child(state: end)]), "\(end)")
        }
        let done = [child(state: "complete")]
        #expect(!CheckoutMonitor.childrenTouchedFiles(from: done, to: done), "a finished child asks once")
    }

    @Test func aNewChildReadsOnlyWhenItWroteOrFinished() {
        let old = [child("run-1", state: "complete")]
        #expect(CheckoutMonitor.childrenTouchedFiles(
            from: old, to: old + [child("run-2", files: [ChildFileChange(path: "a.swift", added: 1, removed: 0)])]))
        #expect(!CheckoutMonitor.childrenTouchedFiles(from: old, to: old + [child("run-2")]))
        #expect(CheckoutMonitor.childrenTouchedFiles(from: [], to: [child("run-2", state: "failed")]))
    }

    @Test func aDroppedChildDoesNotRead() {
        let old = [child("run-1", files: [ChildFileChange(path: "a.swift", added: 1, removed: 0)]), child("run-2")]
        #expect(!CheckoutMonitor.childrenTouchedFiles(from: old, to: [old[1]]))
        #expect(!CheckoutMonitor.childrenTouchedFiles(from: old, to: []))
    }

    @Test func aLaneIsOneChildOfItsRun() {
        var lane0 = child("run-1"), lane1 = child("run-1")
        lane0.childIndex = 0
        lane1.childIndex = 1
        var finished = lane1
        finished.state = "complete"
        #expect(CheckoutMonitor.childrenTouchedFiles(from: [lane0, lane1], to: [lane0, finished]))
        #expect(!CheckoutMonitor.childrenTouchedFiles(from: [lane0, finished], to: [lane0, finished]))
    }
}
