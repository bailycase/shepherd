import Foundation
import Testing
import ShepherdCore
@testable import ShepherdRemote

/// What a thread that has not started on its Mac says on its sidebar row, in a normal thread's words (FleetSubthreads): every state a dispatch record can
/// be in, the Mac as the row's tag, and a Mac named by id never shown as one.
@Suite("Fleet sent stage")
struct FleetSentStageTests {
    static let here = UUID(), mini = UUID(), studio = UUID()

    static func record(_ state: FleetDispatchState, target: UUID? = mini, host: String? = "Mac mini", failure: String? = nil, detail: String? = nil,
                       clone: FleetCloneProgress? = nil, limit: String? = nil) -> FleetDispatchRecord {
        FleetDispatchRecord(parentHostID: here, parentHostName: "MacBook Pro", targetHostID: target, targetHostName: host, state: state,
                            failure: failure, failureDetail: detail, title: "Fix flaky payment test", task: "", repoKey: "github.com/acme/payments-web",
                            clone: clone, limitProvider: limit, createdAt: 1)
    }

    static func stage(_ record: FleetDispatchRecord, macs: [UUID: String] = [:]) -> FleetSentStage {
        .of(record, viewer: here, macs: macs)
    }

    /// The row's second line and its tag, as the sidebar draws them.
    static func row(_ record: FleetDispatchRecord, macs: [UUID: String] = [:]) -> String {
        let stage = Self.stage(record, macs: macs)
        return [stage.tag, stage.words].compactMap { $0 }.joined(separator: " | ")
    }

    @Test func everyStateReadsAsAThreadStartingOrFailing() {
        let cases: [(FleetDispatchRecord, String, FleetSentStage.Mark, FleetSentStage.Mark?)] = [
            (Self.record(.placing, target: nil, host: nil), "starting", .hollow, nil),
            (Self.record(.waitingRoom, target: nil, host: nil), "waiting for a Mac with room", .hollow, nil),
            (Self.record(.waitingRoom, target: nil, host: nil, limit: "anthropic"), "waiting for Anthropic's limit", .hollow, nil),
            (Self.record(.waitingWake, target: Self.studio, host: "Mac Studio"), "studio | waiting for studio to wake", .hollow, nil),
            (Self.record(.heldLimit, target: nil, host: nil), "waiting for another thread to finish", .hollow, nil),
            (Self.record(.heldRestart, target: nil, host: nil), "paused by the restart", .hollow, nil),
            (Self.record(.preparing), "mini | starting on mini", .running, .running),
            (Self.record(.preparing, clone: FleetCloneProgress(name: "payments-web", source: "github.com/acme/payments-web")),
             "mini | cloning payments-web on mini", .running, .running),
            (Self.record(.preparing, target: Self.here, host: "MacBook Pro"), "starting", .running, .running),
            (Self.record(.running), "mini | working", .running, .running),
            (Self.record(.delivering), "mini | working", .running, .running),
            (Self.record(.failed, target: Self.studio, host: "Mac Studio", failure: FleetDispatchCode.hostNotReady, detail: "Xcode"),
             "studio | Xcode isn't installed", .failed, .failed),
        ]
        for (record, line, dot, tone) in cases {
            let stage = Self.stage(record)
            #expect(Self.row(record) == line, "\(record.state)")
            #expect(stage.dot == dot && stage.tone == tone, "\(record.state)")
        }
    }

    @Test func noRowSpeaksOfSendingOrDispatching() {
        for state in [FleetDispatchState.placing, .waitingRoom, .waitingWake, .heldLimit, .heldRestart, .preparing, .running, .delivering, .done, .failed] {
            let words = Self.stage(Self.record(state)).words.lowercased()
            #expect(!["sent", "dispatch", "placing", "delivering", "held", "back"].contains { words.contains($0) }, "\(state): \(words)")
        }
    }

    @Test func aFinishedThreadIsDone() {
        for state in [FleetDispatchState.done, .cancelled] {
            let stage = Self.stage(Self.record(state))
            #expect(stage.phase == .back && stage.dot == .done)
        }
    }

    @Test func thisMacIsNoTagAndAMacThatLeftIsNoTagEither() {
        #expect(Self.stage(Self.record(.preparing)).tag == "mini")
        #expect(Self.stage(Self.record(.preparing, target: Self.here, host: "MacBook Pro")).tag == nil)
        #expect(Self.stage(Self.record(.placing, target: nil, host: nil)).tag == nil)
    }

    @Test func aFailureWithoutADetailReadsItsCode() {
        #expect(Self.row(Self.record(.failed, failure: FleetDispatchCode.cloneFailed)) == "mini | couldn't clone")
        #expect(Self.row(Self.record(.failed, failure: FleetDispatchCode.peerGone)) == "mini | stopped answering")
        #expect(Self.row(Self.record(.failed, failure: nil)) == "mini | didn't start")
        // A detail that runs on is the Fleet page's to show.
        let long = String(repeating: "x", count: 80)
        #expect(Self.row(Self.record(.failed, failure: FleetDispatchCode.refused, detail: long)) == "mini | refused it")
        // The Mac's own short detail, for a failure that isn't about what it lacks.
        #expect(Self.row(Self.record(.failed, failure: FleetDispatchCode.snapshotFailed, detail: "xcodebuild exited 65")) == "mini | xcodebuild exited 65")
    }

    @Test func aMacThatIsNotReadySaysWhatItLacks() {
        func words(_ detail: String?) -> String {
            Self.row(Self.record(.failed, failure: FleetDispatchCode.hostNotReady, detail: detail))
        }
        #expect(words("bearcli") == "mini | bearcli isn't installed")
        #expect(words("Xcode") == "mini | Xcode isn't installed")
        #expect(words("anthropic models") == "mini | can't run anthropic models")
        #expect(words("unknown") == "mini | hasn't reported yet")
        #expect(words("unreachable") == "mini | isn't answering")
        #expect(words(nil) == "mini | not ready for it")
        #expect(words(String(repeating: "x", count: 80)) == "mini | not ready for it")
    }

    // A thread sent from New thread names its Mac by id until one is placed: `requestedHost` is never a name then.
    @Test func aRequestedMacReadsAsItsNameNotItsId() {
        func row(_ requested: String?, macs: [UUID: String]) -> String {
            var record = Self.record(.failed, target: nil, host: nil, failure: FleetDispatchCode.hostNotReady, detail: "bearcli")
            record.requestedHost = requested
            return Self.row(record, macs: macs)
        }
        let macs = [Self.here: "MacBook Pro", Self.mini: "Mac mini"]
        #expect(row(Self.mini.uuidString, macs: macs) == "mini | bearcli isn't installed")
        #expect(row(Self.here.uuidString, macs: macs) == "bearcli isn't installed", "This Mac has no tag")
        #expect(row(Self.studio.uuidString, macs: macs) == "a Mac that left · bearcli isn't installed")
        #expect(!row(Self.studio.uuidString, macs: macs).contains(Self.studio.uuidString))
        // A name an agent typed stands as it is; Auto names no Mac.
        #expect(row("Mac Studio", macs: macs) == "studio | bearcli isn't installed")
        #expect(row("auto", macs: macs) == "bearcli isn't installed")
        #expect(row(nil, macs: macs) == "bearcli isn't installed")
        // Waiting for a Mac by id reads the same.
        var waiting = Self.record(.waitingWake, target: nil, host: nil)
        waiting.requestedHost = Self.studio.uuidString
        #expect(Self.row(waiting, macs: [Self.studio: "Mac Studio"]) == "studio | waiting for studio to wake")
    }
}
