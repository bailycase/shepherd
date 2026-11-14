import Foundation
import Testing
import ShepherdCore
@testable import ShepherdRemote

/// Where a sent thread is, in the words of its sidebar line (FleetSubthreads): every stage a dispatch record can be in, and a thread whose
/// record this Mac can't see.
@Suite("Fleet sent stage")
struct FleetSentStageTests {
    static let here = UUID(), mini = UUID(), studio = UUID()

    static func record(_ state: FleetDispatchState, target: UUID? = mini, host: String? = "Mac mini", failure: String? = nil, detail: String? = nil,
                       clone: FleetCloneProgress? = nil, limit: String? = nil, updated: Double = 1_000) -> FleetDispatchRecord {
        var record = FleetDispatchRecord(parentHostID: here, parentHostName: "MacBook Pro", targetHostID: target, targetHostName: host, state: state,
                                         failure: failure, failureDetail: detail, title: "Fix flaky payment test", task: "", repoKey: "github.com/acme/payments-web",
                                         clone: clone, limitProvider: limit, createdAt: 1)
        record.updatedAt = updated
        return record
    }

    static func stage(_ record: FleetDispatchRecord, thread: AgentStatus? = nil, next: String? = nil, live: Int = 4, cap: Int = 4) -> FleetSentStage {
        .of(record, thread: thread, viewer: here, next: next, live: live, cap: cap)
    }

    @Test func everyStageReadsAsItsLine() {
        let cases: [(FleetDispatchRecord, String, FleetSentStage.Mark, FleetSentStage.Mark?)] = [
            (Self.record(.placing, target: nil, host: nil), "placing · choosing a Mac", .hollow, nil),
            (Self.record(.waitingRoom, target: nil, host: nil), "no Mac has room", .hollow, nil),
            (Self.record(.waitingWake, target: Self.studio, host: "Mac Studio"), "studio · goes when it wakes", .hollow, nil),
            (Self.record(.heldLimit, target: nil, host: nil), "held · 4 of 4 sends live", .hollow, nil),
            (Self.record(.preparing, clone: FleetCloneProgress(name: "payments-web", source: "github.com/acme/payments-web")), "mini · cloning payments-web", .running, .running),
            (Self.record(.preparing, target: Self.here, host: "MacBook Pro"), "This Mac · preparing worktree", .running, .running),
            (Self.record(.running), "mini · running", .running, .running),
            (Self.record(.delivering), "mini · delivering", .done, .running),
            (Self.record(.failed, target: Self.studio, host: "Mac Studio", failure: FleetDispatchCode.hostNotReady, detail: "xcodebuild exited 65"),
             "studio · xcodebuild exited 65", .failed, .failed),
        ]
        for (record, line, dot, tone) in cases {
            let stage = Self.stage(record)
            #expect(stage.line() == line, "\\(record.state)")
            #expect(stage.dot == dot && stage.tone == tone, "\\(record.state)")
        }
    }

    @Test func aRunningThreadThatAsksReadsAskingYou() {
        let stage = Self.stage(Self.record(.running), thread: .blocked)
        #expect(stage.line() == "mini · asking you" && stage.dot == .attention && stage.tone == .attention && stage.phase == .asking)
    }

    @Test func aRunningThreadSaysHowLongItHasRun() {
        let stage = Self.stage(Self.record(.running, updated: 5_000_000))
        #expect(stage.runningSince == 5_000_000)
        #expect(stage.line(elapsed: "4m") == "mini · running 4m")
        #expect(Self.stage(Self.record(.delivering)).line(elapsed: "4m") == "mini · delivering", "only a running thread carries the time")
    }

    @Test func waitingForRoomNamesTheMacAutoPicksNext() {
        #expect(Self.stage(Self.record(.waitingRoom, target: nil, host: nil), next: "Mac mini").line() == "no Mac has room · next: mini")
        #expect(Self.stage(Self.record(.waitingRoom, target: nil, host: nil, limit: "anthropic")).line() == "waiting for Anthropic's limit")
    }

    @Test func aFinishedThreadIsBack() {
        for state in [FleetDispatchState.done, .cancelled] {
            let stage = Self.stage(Self.record(state))
            #expect(stage.phase == .back && stage.dot == .done)
        }
    }

    @Test func aFailureWithoutADetailReadsItsCode() {
        #expect(Self.stage(Self.record(.failed, failure: FleetDispatchCode.cloneFailed)).line() == "mini · couldn't clone")
        #expect(Self.stage(Self.record(.failed, failure: FleetDispatchCode.peerGone)).line() == "mini · stopped answering")
        #expect(Self.stage(Self.record(.failed, failure: nil)).line() == "mini · not sent")
        // A detail that runs on is the Fleet page's to show.
        let long = String(repeating: "x", count: 80)
        #expect(Self.stage(Self.record(.failed, failure: FleetDispatchCode.refused, detail: long)).line() == "mini · refused it")
    }

    @Test func aThreadWhoseRecordIsAnotherMacsReadsItsOwnState() {
        #expect(FleetSentStage.of(thread: .working, host: "mini").line() == "mini · running")
        #expect(FleetSentStage.of(thread: .blocked, host: "This Mac").line() == "This Mac · asking you")
        #expect(FleetSentStage.of(thread: .done, host: "mini").phase == .back)
        #expect(FleetSentStage.of(thread: .idle, host: "mini").phase == .back)
    }

    @Test func aSenderSaysWhatItSent() {
        #expect(FleetSentSummary.line(sent: 3, back: 1, asking: false) == "3 sent · 1 back")
        #expect(FleetSentSummary.line(sent: 1, back: 0, asking: true) == "1 sent · asking you")
        #expect(FleetSentSummary.line(sent: 4, back: 2, asking: true) == "4 sent · 2 back")
        #expect(FleetSentSummary.line(sent: 1, back: 0, asking: false) == "1 sent")
        #expect(FleetSentSummary.line(sent: 0, back: 0, asking: false) == nil)
    }
}
