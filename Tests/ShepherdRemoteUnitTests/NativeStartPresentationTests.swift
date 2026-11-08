import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// What the Can't start banner says for a pi that stopped, before it served and on its own after.
@Suite("Start problem copy")
struct NativeStartPresentationTests {
    @Test(arguments: [
        (NativeStartProblem(kind: .stopped, signal: 9), "The agent stopped unexpectedly (signal 9)."),
        (NativeStartProblem(kind: .stopped, exitCode: 1), "The agent stopped unexpectedly (code 1)."),
        (NativeStartProblem(kind: .stopped, exitCode: 0), "The agent stopped unexpectedly (code 0)."),
        (NativeStartProblem(kind: .stopped), "The agent stopped unexpectedly."),
    ])
    func aStoppedAgentSaysHowItEnded(_ problem: NativeStartProblem, _ title: String) {
        #expect(problem.title == title)
    }

    @Test func aStoppedAgentPointsAtRetryAndSaysTheConversationIsSaved() {
        let problem = NativeStartProblem(kind: .stopped, signal: 9, lines: ["FATAL ERROR: heap out of memory"])
        #expect(problem.advice() == "Retry to start it again. Its conversation is saved.")
        #expect(problem.advice(host: "horizon") == "Retry on horizon to start it again. Its conversation is saved.")
        #expect(problem.message(host: "horizon")
                == "Retry on horizon to start it again. Its conversation is saved.\n\nFATAL ERROR: heap out of memory")
    }

    @Test(arguments: [
        (NativeStartProblem(kind: .exited, exitCode: 1), "pi exited while starting (code 1)."),
        (NativeStartProblem(kind: .exited, signal: 9), "pi exited while starting (signal 9)."),
        (NativeStartProblem(kind: .exited), "pi exited while starting (signal)."),
    ])
    func aPiThatExitedWhileStartingShowsTheSignalNumberWhenKnown(_ problem: NativeStartProblem, _ title: String) {
        #expect(problem.title == title)
        #expect(problem.advice() == "Retry to start it again.")
    }

    @Test func everyKindHasATitleAndAdvice() {
        for kind in NativeStartProblem.Kind.allCases {
            let problem = NativeStartProblem(kind: kind)
            #expect(!problem.title.isEmpty && !problem.advice().isEmpty && !problem.advice(host: "horizon").isEmpty)
        }
    }
}
